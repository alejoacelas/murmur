// murmurctl — thin control-socket client (SPEC §10.2). Sends one line-delimited JSON request,
// prints the JSON response, exits 0 iff ok:true. `wait-ready` retries the connection client-side
// so it also covers "app still starting / socket not created yet".
import Darwin
import Foundation
import MurmurKit

func usage() -> Never {
    let text = """
        usage: murmurctl <command> [args]
          health                          one-shot readiness/permissions snapshot
          wait-ready [--timeout <s>]      block until app is up + model ready
          await-state <state> [--id <id>] [--timeout <s>]
          model [status|ensure]
          permissions
          start | stop
          inject <wav> [--realtime]
          transcribe <wav>
          retry <id>
          last | sessions
          hud
          fault <kind> <value>            transcribe-delay-ms N | fail-transcribe off|transient|permanent | fail-insert on|off
          quit
        """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func connect(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
    guard path.utf8.count <= maxLen else {
        close(fd)
        return nil
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dst in
            path.withCString { src in _ = strcpy(dst, src) }
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.connect(fd, sa, size) == 0
        }
    }
    guard ok else {
        close(fd)
        return nil
    }
    return fd
}

/// Send one request, return the raw response line (nil on connect/read failure).
func roundTrip(_ request: ControlProtocol.Request, socketPath: String) -> String? {
    guard let fd = connect(socketPath) else { return nil }
    defer { close(fd) }
    var payload = request.encoded()
    payload.append(0x0A)
    let sent = payload.withUnsafeBytes { raw in
        send(fd, raw.baseAddress, raw.count, 0)
    }
    guard sent == payload.count else { return nil }
    var line = Data()
    var byte: UInt8 = 0
    while true {
        let n = recv(fd, &byte, 1, 0)
        if n <= 0 { return nil }
        if byte == 0x0A { break }
        line.append(byte)
    }
    return String(data: line, encoding: .utf8)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }
let cmd = args.removeFirst()
let socketPath = Paths.controlSocket.path

@MainActor
func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
@MainActor
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

var request = ControlProtocol.Request(cmd: cmd)

switch cmd {
case "health", "permissions", "last", "sessions", "hud", "quit", "start", "stop":
    break

case "wait-ready":
    let timeout = Double(flagValue("--timeout") ?? "120") ?? 120
    let deadline = Date().addingTimeInterval(timeout)
    var lastResponse = "(no response)"
    while Date() < deadline {
        if let resp = roundTrip(ControlProtocol.Request(cmd: "health"), socketPath: socketPath) {
            lastResponse = resp
            if let data = resp.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                obj["ready"] as? Bool == true
            {
                print(resp)
                exit(0)
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    FileHandle.standardError.write(Data("murmurctl: wait-ready timed out; last=\(lastResponse)\n".utf8))
    exit(1)

case "await-state":
    guard !args.isEmpty else { usage() }
    request.state = args.removeFirst()
    request.id = flagValue("--id")
    if let t = flagValue("--timeout") { request.timeoutMs = Int((Double(t) ?? 30) * 1000) }

case "model":
    request.value = args.first ?? "status"

case "inject":
    guard !args.isEmpty else { usage() }
    request.realtime = flag("--realtime")
    request.wav = (args.removeFirst() as NSString).expandingTildeInPath

case "transcribe":
    guard !args.isEmpty else { usage() }
    request.wav = (args.removeFirst() as NSString).expandingTildeInPath

case "retry":
    guard !args.isEmpty else { usage() }
    request.id = args.removeFirst()

case "fault":
    guard args.count >= 2 else { usage() }
    request.kind = args.removeFirst()
    request.value = args.removeFirst()

default:
    usage()
}

guard let response = roundTrip(request, socketPath: socketPath) else {
    FileHandle.standardError.write(
        Data("murmurctl: cannot reach control socket at \(socketPath) (is Murmur running?)\n".utf8))
    exit(1)
}
print(response)
if let data = response.data(using: .utf8),
    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    obj["ok"] as? Bool == true
{
    exit(0)
}
exit(1)
