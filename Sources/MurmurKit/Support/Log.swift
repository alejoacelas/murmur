import Foundation

/// JSON-lines logger: one `{"ts":…,"level":…,"event":…,"msg":…}` object per line, appended to
/// `$MURMUR_HOME/logs/murmur.log` and mirrored to stderr. The acceptance harness greps this file
/// for `"level":"error"` (SPEC §10.6), so keep `error` for genuine faults only.
public enum Log {
    public enum Level: String, Sendable {
        case debug, info, warn, error
    }

    private static let queue = DispatchQueue(label: "murmur.log")
    private static nonisolated(unsafe) var handle: FileHandle?
    // Only ever touched on `queue`.
    private static nonisolated(unsafe) let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func debug(_ event: String, msg: String = "") { write(.debug, event, msg) }
    public static func info(_ event: String, msg: String = "") { write(.info, event, msg) }
    public static func warn(_ event: String, msg: String = "") { write(.warn, event, msg) }
    public static func error(_ event: String, msg: String = "") { write(.error, event, msg) }

    /// Drain pending writes — call before exiting on a fatal path or async logs are lost.
    public static func flush() {
        queue.sync {}
    }

    private static func write(_ level: Level, _ event: String, _ msg: String) {
        let now = Date()
        queue.async {
            let ts = iso.string(from: now)
            var obj: [String: String] = ["ts": ts, "level": level.rawValue, "event": event]
            if !msg.isEmpty { obj["msg"] = msg }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                let line = String(data: data, encoding: .utf8)
            else { return }
            FileHandle.standardError.write(Data((line + "\n").utf8))
            if handle == nil {
                try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
                let url = Paths.logs.appendingPathComponent("murmur.log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            handle?.write(Data((line + "\n").utf8))
        }
    }
}
