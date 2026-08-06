import Foundation

/// Unix-domain control server (SPEC §10.2) — the automation seam. Drives the whole app with no
/// synthetic keys and no live mic. POSIX socket + one lightweight task per connection reading
/// line-delimited JSON.
public actor ControlServer {
    private let engine: Engine
    private let backend: TranscriptionBackend
    private let socketURL: URL
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Extra command hook so higher layers (app/UI) can extend the protocol (e.g. probe readback).
    private var extraHandler: (@Sendable (ControlProtocol.Request) async -> [String: Any]?)?

    public init(engine: Engine, backend: TranscriptionBackend, socketURL: URL = Paths.controlSocket) {
        self.engine = engine
        self.backend = backend
        self.socketURL = socketURL
    }

    public func setExtraHandler(
        _ handler: @escaping @Sendable (ControlProtocol.Request) async -> [String: Any]?
    ) {
        extraHandler = handler
    }

    public func start() throws {
        let path = socketURL.path
        unlink(path)  // stale socket from a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.socketFailed("socket(): errno \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            close(fd)
            throw ControlError.socketFailed("socket path too long (\(path.utf8.count) > \(maxLen)): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
                path.withCString { src in _ = strcpy(dst, src) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, size)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ControlError.socketFailed("bind(): errno \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ControlError.socketFailed("listen(): errno \(errno)")
        }
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0, let self else { return }
            Task { await self.handleConnection(client) }
        }
        source.resume()
        acceptSource = source
        Log.info("control.listening", msg: socketURL.path)
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketURL.path)
    }

    private func handleConnection(_ fd: Int32) async {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            for try await line in handle.bytes.lines {
                guard let req = ControlProtocol.Request(jsonLine: Data(line.utf8)) else {
                    try? handle.write(contentsOf: ControlProtocol.encodeResponse(
                        ControlProtocol.fail("unparseable request")))
                    continue
                }
                let response = await dispatch(req)
                try? handle.write(contentsOf: ControlProtocol.encodeResponse(response))
                if req.cmd == "quit" {
                    try? handle.synchronize()
                    Log.info("control.quit", msg: "clean shutdown requested")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exit(0) }
                }
            }
        } catch {
            // connection dropped; nothing to do
        }
    }

    private func dispatch(_ req: ControlProtocol.Request) async -> [String: Any] {
        if let extraHandler, let handled = await extraHandler(req) {
            return handled
        }
        switch req.cmd {
        case "health":
            let perms = Permissions.current()
            return ControlProtocol.ok([
                "ready": await backend.modelReady,
                "guiSession": Permissions.hasGUISession(),
                "secureInput": Permissions.secureInputActive(),
                "recording": await engine.isRecording,
                "permissions": [
                    "microphone": perms.microphone,
                    "inputMonitoring": perms.inputMonitoring,
                    "accessibility": perms.accessibility,
                ],
                "model": ["state": await backend.modelReady ? "ready" : "loading"],
                "pid": Int(getpid()),
            ])

        case "permissions":
            let p = Permissions.current()
            return ControlProtocol.ok([
                "microphone": p.microphone,
                "inputMonitoring": p.inputMonitoring,
                "accessibility": p.accessibility,
            ])

        case "model":
            switch req.value ?? "status" {
            case "ensure":
                do {
                    try await backend.ensureModelReady()
                    return ControlProtocol.ok(["state": "ready"])
                } catch {
                    return ControlProtocol.fail("model load failed: \(error)")
                }
            default:
                return ControlProtocol.ok(["state": await backend.modelReady ? "ready" : "cold"])
            }

        case "await-state":
            guard let stateName = req.state, let state = SessionState(rawValue: stateName) else {
                return ControlProtocol.fail("await-state needs a valid state")
            }
            let reached = await engine.awaitState(
                id: req.id, state: state, timeoutMs: req.timeoutMs ?? 30_000)
            return reached
                ? ControlProtocol.ok(["state": stateName])
                : ControlProtocol.fail("timeout waiting for \(stateName)")

        case "start":
            do {
                let id = try await engine.startRecording()
                return ControlProtocol.ok(["sessionId": id])
            } catch {
                return ControlProtocol.fail("\(error)")
            }

        case "stop":
            do {
                let meta = try await engine.stopAndFinalize()
                let id = meta.id
                Task { await engine.runToCompletion(id) }
                return ControlProtocol.ok(ControlProtocol.metaDict(meta))
            } catch {
                return ControlProtocol.fail("\(error)")
            }

        case "inject":
            guard let wav = req.wav else { return ControlProtocol.fail("inject needs wav") }
            do {
                let result = try await engine.inject(
                    wav: URL(fileURLWithPath: wav), realtime: req.realtime ?? false)
                return ControlProtocol.ok([
                    "sessionId": result.sessionId, "transcript": result.transcript,
                ])
            } catch {
                return ControlProtocol.fail("\(error)")
            }

        case "transcribe":
            guard let wav = req.wav else { return ControlProtocol.fail("transcribe needs wav") }
            do {
                let text = try await engine.transcribeFile(URL(fileURLWithPath: wav))
                return ControlProtocol.ok(["transcript": text])
            } catch {
                return ControlProtocol.fail("\(error)")
            }

        case "retry":
            guard let id = req.id else { return ControlProtocol.fail("retry needs id") }
            do {
                let meta = try await engine.retry(id)
                return ControlProtocol.ok(ControlProtocol.metaDict(meta))
            } catch {
                return ControlProtocol.fail("\(error)")
            }

        case "last":
            if let meta = await engine.lastSession() {
                return ControlProtocol.ok(ControlProtocol.metaDict(meta))
            }
            return ControlProtocol.fail("no sessions")

        case "sessions":
            let all = await engine.sessions().map(ControlProtocol.metaDict)
            return ControlProtocol.ok(["sessions": all])

        case "hud":
            let (phase, partial) = await engine.hudState
            return ControlProtocol.ok([
                "visible": phase != .hidden, "phase": phase.rawValue, "lastPartial": partial,
            ])

        case "fault":
            guard let kind = req.kind, let value = req.value else {
                return ControlProtocol.fail("fault needs kind and value")
            }
            return await engine.setFault(kind: kind, value: value)
                ? ControlProtocol.ok(["kind": kind, "value": value])
                : ControlProtocol.fail("unknown fault kind/value: \(kind)=\(value)")

        case "quit":
            return ControlProtocol.ok(["bye": true])

        default:
            return ControlProtocol.fail("unknown command: \(req.cmd)")
        }
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case socketFailed(String)

    public var description: String {
        switch self {
        case .socketFailed(let s): return "control socket: \(s)"
        }
    }
}
