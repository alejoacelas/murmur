import Foundation

/// Single-root state layout (SPEC §2). Everything lives under `$MURMUR_HOME`, defaulting to
/// `~/Library/Application Support/Murmur/`. Tests point `MURMUR_HOME` at a fresh temp dir per run
/// so runs never pollute each other. Resolved once at first access — env is fixed at launch.
public enum Paths {
    public static let home: URL = {
        let env = ProcessInfo.processInfo.environment
        if let h = env["MURMUR_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: (h as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur", isDirectory: true)
    }()

    public static var recordings: URL { home.appendingPathComponent("recordings", isDirectory: true) }
    public static var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public static var configFile: URL { home.appendingPathComponent("config.json") }

    /// Control socket path; independently overridable so several app instances can coexist.
    public static let controlSocket: URL = {
        let env = ProcessInfo.processInfo.environment
        if let s = env["MURMUR_SOCK"], !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("control.sock")
    }()

    /// Model-cache override (`$MURMUR_MODEL_CACHE`). nil = FluidAudio's default cache
    /// (~/Library/Application Support/FluidAudio/Models/…). When set, FluidAudio expects the
    /// VERSION-SPECIFIC directory — `<override>/<repo folder>` — because its repoPath() strips
    /// the last path component (verified in spike S4).
    public static func modelCacheDir(repoFolder: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let c = env["MURMUR_MODEL_CACHE"], !c.isEmpty else { return nil }
        return URL(fileURLWithPath: (c as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
    }

    /// Create the state tree. Idempotent; call at app/CLI startup.
    public static func ensureTree() throws {
        let fm = FileManager.default
        for dir in [home, recordings, logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
