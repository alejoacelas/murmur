import Foundation

/// Pipeline coordinator: record → finalize → transcribe (batch, authoritative) → insert, with
/// the retry/recovery rules of SPEC §7. Owns no UI; the app observes it. Everything here is
/// drivable headlessly through the control server — that's the automation seam (§10.2).
public actor Engine {
    public struct InjectResult: Sendable {
        public let sessionId: String
        public let transcript: String
    }

    /// Debug fault injection (SPEC §10.2) — makes race/failure tests deterministic.
    public struct Faults: Sendable {
        public var transcribeDelayMs: Int = 0
        /// "off" | "transient" | "permanent"
        public var failTranscribe: String = "off"
        public var failInsert: Bool = false
    }

    private struct ActiveRecording {
        let id: String
        let source: AudioSource
        let worker: CaptureWorker
        let feedTask: Task<Void, Never>
        let continuation: AsyncStream<[Float]>.Continuation
        let partialsTask: Task<Void, Never>?
        let focus: FocusTarget?
    }

    private let store: SessionStore
    private let backend: TranscriptionBackend
    private let inserter: TextInserter
    private let processor: TranscriptProcessor
    private let config: Config

    private var active: ActiveRecording?
    private var lastSessionId: String?
    private var faults = Faults()

    // HUD observability (SPEC §6): state is here so `murmurctl hud` can report it headlessly
    // and the UI layer just mirrors it.
    public enum HUDPhase: String, Sendable {
        case hidden, recording, transcribing
    }
    private var hudPhase: HUDPhase = .hidden
    private var lastPartial = ""
    private var hudObservers: [@Sendable (HUDPhase, String) -> Void] = []
    /// Debounces hotkey toggles while a stop→transcribe transition is in flight.
    private var toggleInFlight = false

    public init(
        store: SessionStore, backend: TranscriptionBackend, inserter: TextInserter,
        processor: TranscriptProcessor = IdentityProcessor(), config: Config
    ) {
        self.store = store
        self.backend = backend
        self.inserter = inserter
        self.processor = processor
        self.config = config
    }

    // MARK: - Recording

    public var isRecording: Bool { active != nil }

    public enum EngineError: Error, CustomStringConvertible {
        case alreadyRecording
        case notRecording
        case unknownSession(String)
        case injectedTranscribeFault(FailureClass)

        public var description: String {
            switch self {
            case .alreadyRecording: return "already recording"
            case .notRecording: return "not recording"
            case .unknownSession(let id): return "unknown session: \(id)"
            case .injectedTranscribeFault(let c): return "injected transcribe fault (\(c.rawValue))"
            }
        }
    }

    /// Start recording from `source` (default: live microphone). Returns the new session id.
    @discardableResult
    public func startRecording(source: AudioSource? = nil) async throws -> String {
        guard active == nil else { throw EngineError.alreadyRecording }
        let meta = try await store.create(model: config.model)
        lastSessionId = meta.id

        let focus = await inserter.captureFocus()  // capture at START (SPEC §8.4)
        let worker = CaptureWorker(cafURL: store.cafURL(meta.id))
        let streaming = await backend.modelReady ? await backend.makeStreamingSession() : nil
        try await worker.open(streaming: streaming)

        // Ordered hand-off from the source thread into the serial worker (SPEC §3).
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self, bufferingPolicy: .unbounded)
        let feedTask = Task {
            for await chunk in stream {
                await worker.append(chunk)
            }
        }

        var partialsTask: Task<Void, Never>?
        if let streaming {
            partialsTask = Task { [weak self] in
                for await update in await streaming.updates {
                    await self?.setPartial(update.text)
                }
            }
        }

        let src = source ?? MicAudioSource()
        do {
            try src.start { samples in continuation.yield(samples) }
        } catch {
            continuation.finish()
            feedTask.cancel()
            partialsTask?.cancel()
            _ = await worker.finish()
            var failed = meta
            failed.state = .transcribeFailed
            failed.failureClass = .permanent
            failed.lastError = "audio source failed to start: \(error)"
            try? await store.save(failed)
            throw error
        }

        active = ActiveRecording(
            id: meta.id, source: src, worker: worker, feedTask: feedTask,
            continuation: continuation, partialsTask: partialsTask, focus: focus)
        setHUD(phase: .recording, partial: "")
        Log.info("record.start", msg: "id=\(meta.id)")
        return meta.id
    }

    /// Hotkey entry point: tap-to-start / tap-to-stop (SPEC §4.1 toggle mode). Errors are
    /// logged, never thrown — a hotkey press has no caller to catch.
    public func toggle() async {
        guard !toggleInFlight else {
            Log.debug("hotkey.toggle_ignored", msg: "transition in flight")
            return
        }
        if isRecording {
            toggleInFlight = true
            defer { toggleInFlight = false }
            do {
                let meta = try await stopAndFinalize()
                let id = meta.id
                Task { await self.runToCompletion(id) }
            } catch {
                Log.error("hotkey.stop_failed", msg: "\(error)")
            }
        } else {
            do {
                _ = try await startRecording()
            } catch {
                Log.error("hotkey.start_failed", msg: "\(error)")
                setHUD(phase: .hidden, partial: "")
            }
        }
    }

    /// Stop recording, drain the pipeline, close the capture file (SPEC §3 async boundary).
    /// Returns the finalized (`recorded`) meta; transcription/insertion run via `runToCompletion`.
    public func stopAndFinalize() async throws -> SessionMeta {
        guard let cur = active else { throw EngineError.notRecording }
        active = nil

        await cur.source.stop()
        cur.continuation.finish()
        await cur.feedTask.value  // every enqueued chunk has hit the CAF
        cur.partialsTask?.cancel()
        if let streaming = await cur.worker.streamingSession {
            Task { await streaming.cancel() }  // partials are HUD-only; discard
        }
        let (duration, rms) = await cur.worker.finish()

        guard var meta = await store.load(cur.id) else { throw EngineError.unknownSession(cur.id) }
        meta.state = .recorded
        meta.durationSec = duration
        try await store.save(meta)
        AudioFiles.transcodeToWAV(caf: store.cafURL(cur.id), wav: store.wavURL(cur.id))
        setHUD(phase: .transcribing, partial: lastPartial)  // stays up through transcribing (§6)
        Log.info("record.stop", msg: "id=\(cur.id) durationSec=\(duration) rms=\(rms)")
        pendingFocus[cur.id] = cur.focus
        return meta
    }

    /// Focus captured at recording start, kept until the insert step consumes it.
    private var pendingFocus: [String: FocusTarget?] = [:]

    // MARK: - Transcribe + insert (the state machine driver)

    /// Drive a session from wherever it is to a terminal state, honoring SPEC §7.3:
    /// transient transcribe failures auto-retry (≤3 attempts, backoff); permanent ones stop;
    /// insert failure never re-transcribes.
    public func runToCompletion(_ id: String) async {
        guard var meta = await store.load(id) else { return }

        transcribe: while true {
            switch meta.state {
            case .recorded, .transcribing:
                break
            case .transcribeFailed where meta.failureClass == .transient && meta.attempts < 3:
                break
            default:
                break transcribe
            }
            meta.state = .transcribing
            meta.attempts += 1
            try? await store.save(meta)
            do {
                let raw = try await transcribeAudio(id)
                meta.transcript = processor.process(raw)
                meta.state = .transcribed
                meta.failureClass = nil
                meta.lastError = nil
                try? await store.save(meta)
                Log.info("transcribe.session_done", msg: "id=\(id) chars=\(raw.count)")
            } catch {
                meta.failureClass = classify(error)
                meta.lastError = "\(error)"
                meta.state = .transcribeFailed
                try? await store.save(meta)
                Log.warn(
                    "transcribe.failed",
                    msg: "id=\(id) attempt=\(meta.attempts) class=\(meta.failureClass!.rawValue) err=\(error)")
                if meta.failureClass == .permanent || meta.attempts >= 3 {
                    setHUD(phase: .hidden, partial: "")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(200 * meta.attempts) * 1_000_000)
                continue
            }
        }

        if meta.state == .transcribed || meta.state == .inserting || meta.state == .insertFailed {
            await insertStep(&meta)
        }
        setHUD(phase: .hidden, partial: "")
    }

    /// VAD gate + faults + authoritative batch pass over the saved audio (identical to a retry).
    private func transcribeAudio(_ id: String) async throws -> String {
        if faults.transcribeDelayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(faults.transcribeDelayMs) * 1_000_000)
        }
        switch faults.failTranscribe {
        case "transient": throw EngineError.injectedTranscribeFault(.transient)
        case "permanent": throw EngineError.injectedTranscribeFault(.permanent)
        default: break
        }

        let audio = authoritativeAudioURL(id)
        let samples = try AudioFiles.loadCanonicalSamples(audio)
        if samples.isEmpty {
            throw TranscriptionError.audioUnreadable("no samples in \(audio.lastPathComponent)")
        }
        if VAD.isSilence(samples, threshold: config.silenceRMSThreshold) {
            Log.info("transcribe.silence_gated", msg: "id=\(id) rms=\(VAD.rms(samples))")
            return ""  // SPEC §5.4: no transcript, nothing inserted
        }
        return try await backend.transcribe(samples)
    }

    /// Prefer the authoritative CAF; fall back to the derived WAV (SPEC §5.3).
    private nonisolated func authoritativeAudioURL(_ id: String) -> URL {
        let caf = store.cafURL(id)
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        return store.wavURL(id)
    }

    private func insertStep(_ meta: inout SessionMeta) async {
        let text = meta.transcript ?? ""
        if text.isEmpty {
            meta.state = .inserted  // nothing to insert (silence) — terminal success
            try? await store.save(meta)
            Log.info("insert.skipped_empty", msg: "id=\(meta.id)")
            return
        }
        meta.state = .inserting
        try? await store.save(meta)
        if faults.failInsert {
            meta.state = .insertFailed
            meta.lastError = InsertionError.injectedFault.description
            try? await store.save(meta)
            Log.warn("insert.failed", msg: "id=\(meta.id) err=injected fault")
            return
        }
        do {
            let focus = pendingFocus.removeValue(forKey: meta.id) ?? nil
            try await inserter.insert(text, target: focus)
            meta.state = .inserted
            meta.lastError = nil
            try? await store.save(meta)
            Log.info("insert.done", msg: "id=\(meta.id) chars=\(text.count)")
        } catch {
            meta.state = .insertFailed
            meta.lastError = "\(error)"
            try? await store.save(meta)
            Log.warn("insert.failed", msg: "id=\(meta.id) err=\(error)")
        }
    }

    private func classify(_ error: Error) -> FailureClass {
        switch error {
        case EngineError.injectedTranscribeFault(let c): return c
        case is TranscriptionError: return .permanent  // unreadable/empty audio can't self-heal
        case AudioSourceError.fileUnreadable: return .permanent
        default: return .transient  // model warm-up, transient I/O, unknown
        }
    }

    // MARK: - Entry points (control commands)

    /// One-shot record→transcribe→insert with a WAV as the source (SPEC §10.2 `inject` — the
    /// e2e workhorse). `realtime` paces playback at wall-clock speed for crash tests.
    public func inject(wav: URL, realtime: Bool = false) async throws -> InjectResult {
        let src = FileAudioSource(url: wav, realtime: realtime)
        let id = try await startRecording(source: src)
        await src.awaitEOF()
        _ = try await stopAndFinalize()
        await runToCompletion(id)
        let meta = await store.load(id)
        return InjectResult(sessionId: id, transcript: meta?.transcript ?? "")
    }

    /// Headless transcribe: no session, no HUD, no insertion (SPEC §10.2 `transcribe`).
    public func transcribeFile(_ wav: URL) async throws -> String {
        let samples = try AudioFiles.loadCanonicalSamples(wav)
        if VAD.isSilence(samples, threshold: config.silenceRMSThreshold) { return "" }
        return try await backend.transcribe(samples)
    }

    /// Manual retry (SPEC §7.3): re-run a session per its state. `transcribed`/`insertFailed`
    /// re-insert the EXISTING transcript — never re-transcribe (duplicate-output hazard).
    public func retry(_ id: String) async throws -> SessionMeta {
        guard var meta = await store.load(id) else { throw EngineError.unknownSession(id) }
        switch meta.state {
        case .transcribeFailed, .recorded, .transcribing:
            meta.state = .recorded
            meta.failureClass = nil  // manual retry resets the auto-retry budget
            meta.attempts = 0
            try await store.save(meta)
            await runToCompletion(id)
        case .transcribed, .inserting, .insertFailed:
            await insertStep(&meta)
        case .recording, .inserted:
            break  // nothing sensible to retry
        }
        guard let final = await store.load(id) else { throw EngineError.unknownSession(id) }
        return final
    }

    /// Launch recovery (SPEC §7.3): adopt orphans, finalize crash-mid-recording sessions, and
    /// re-run every recoverable state. Permanent failures wait for manual retry.
    public func recoverAtLaunch() async {
        _ = await store.adoptOrphans(model: config.model)
        for meta in await store.all() {
            var m = meta
            switch m.state {
            case .recording:
                // Crash mid-recording: the CAF on disk is valid up to the crash (S12).
                guard FileManager.default.fileExists(atPath: store.cafURL(m.id).path) else {
                    m.state = .transcribeFailed
                    m.failureClass = .permanent
                    m.lastError = "crashed mid-recording with no audio.caf"
                    try? await store.save(m)
                    continue
                }
                let samples = (try? AudioFiles.loadCanonicalSamples(store.cafURL(m.id))) ?? []
                m.durationSec = Double(samples.count) / CanonicalAudio.sampleRate
                m.state = .recorded
                try? await store.save(m)
                Log.info("recover.finalized_recording", msg: "id=\(m.id) durationSec=\(m.durationSec ?? 0)")
                await runToCompletion(m.id)
            case .recorded, .transcribing:
                await runToCompletion(m.id)
            case .transcribed, .inserting:
                await runToCompletion(m.id)  // insert step only
            case .transcribeFailed where m.failureClass != .permanent && m.attempts < 3:
                await runToCompletion(m.id)
            case .insertFailed:
                // Re-inserting unprompted after relaunch would paste into whatever is focused
                // now; leave for manual retry.
                continue
            default:
                continue
            }
        }
    }

    // MARK: - Introspection (control server)

    public func session(_ id: String) async -> SessionMeta? { await store.load(id) }
    public func lastSession() async -> SessionMeta? {
        if let id = lastSessionId { return await store.load(id) }
        return await store.all().last
    }
    public func sessions() async -> [SessionMeta] { await store.all() }

    /// Deterministic wait (SPEC §10.2 `await-state`): true once the session reaches `state`.
    public func awaitState(id: String?, state: SessionState, timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let meta: SessionMeta?
            if let id { meta = await store.load(id) } else { meta = await lastSession() }
            if meta?.state == state { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    public func setFault(kind: String, value: String) -> Bool {
        switch kind {
        case "transcribe-delay-ms":
            faults.transcribeDelayMs = Int(value) ?? 0
        case "fail-transcribe":
            guard ["off", "transient", "permanent"].contains(value) else { return false }
            faults.failTranscribe = value
        case "fail-insert":
            faults.failInsert = (value == "on" || value == "true" || value == "1")
        default:
            return false
        }
        Log.info("fault.set", msg: "\(kind)=\(value)")
        return true
    }

    // MARK: - HUD state (SPEC §6 testability)

    public var hudState: (phase: HUDPhase, lastPartial: String) { (hudPhase, lastPartial) }

    /// UI layers register to mirror HUD state; called on the engine's executor.
    public func onHUDChange(_ observer: @escaping @Sendable (HUDPhase, String) -> Void) {
        hudObservers.append(observer)
    }

    private func setHUD(phase: HUDPhase, partial: String) {
        hudPhase = phase
        lastPartial = partial
        for o in hudObservers { o(phase, partial) }
    }

    private func setPartial(_ text: String) {
        guard hudPhase == .recording else { return }
        lastPartial = text
        for o in hudObservers { o(hudPhase, text) }
    }
}
