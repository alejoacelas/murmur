import Foundation

/// `$MURMUR_HOME/config.json` (SPEC §8.5) — every field optional, unknown values fall back to
/// defaults rather than failing the launch. `$MURMUR_TRIGGER` overrides `trigger` (tests launch
/// the bundle exec directly, so env is inherited — verified S8).
public struct Config: Sendable, Equatable {
    public enum Trigger: String, Sendable {
        case ctrlSpace = "ctrl-space"
        case fnSpace = "fn-space"
    }
    public enum Insertion: String, Sendable {
        case paste, type
    }
    public enum Retention: String, Sendable {
        case keep
        case deleteOnSuccess
    }

    public var trigger: Trigger = .ctrlSpace
    public var model: String = "parakeet-v2"
    public var insertion: Insertion = .paste
    public var preserveClipboard: Bool = true
    /// Delay before best-effort clipboard restore (SPEC §8.4) — configurable, lossy by design.
    public var clipboardRestoreDelayMs: Int = 300
    public var retention: Retention = .keep
    /// RMS below this ⇒ treat the recording as silence and insert nothing (SPEC §5.4).
    public var silenceRMSThreshold: Float = 0.002

    public init() {}

    /// Load config.json (if present), then apply env overrides. Never throws: a broken config
    /// file logs a warning and yields defaults — the app must still come up.
    public static func load(from file: URL = Paths.configFile) -> Config {
        var cfg = Config()
        if let data = try? Data(contentsOf: file),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            if let s = json["trigger"] as? String, let t = Trigger(rawValue: s) { cfg.trigger = t }
            if let s = json["model"] as? String { cfg.model = s }
            if let s = json["insertion"] as? String, let i = Insertion(rawValue: s) { cfg.insertion = i }
            if let b = json["preserveClipboard"] as? Bool { cfg.preserveClipboard = b }
            if let n = json["clipboardRestoreDelayMs"] as? Int { cfg.clipboardRestoreDelayMs = n }
            if let s = json["retention"] as? String, let r = Retention(rawValue: s) { cfg.retention = r }
            if let n = json["silenceRMSThreshold"] as? Double { cfg.silenceRMSThreshold = Float(n) }
        } else if FileManager.default.fileExists(atPath: file.path) {
            Log.warn("config.parse_failed", msg: "using defaults; file=\(file.path)")
        }
        if let t = ProcessInfo.processInfo.environment["MURMUR_TRIGGER"],
            let trig = Trigger(rawValue: t)
        {
            cfg.trigger = trig
        }
        return cfg
    }
}
