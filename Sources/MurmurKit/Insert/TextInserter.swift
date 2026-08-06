import Foundation

/// Where the transcript should land. Captured at recording START (SPEC §8.4) and re-checked
/// before inserting — in toggle mode the user can easily refocus something else mid-flight.
public struct FocusTarget: Sendable, Codable, Equatable {
    public var bundleId: String?
    public var pid: Int32
    public var appName: String?
    public var capturedAt: Date

    public init(bundleId: String?, pid: Int32, appName: String?, capturedAt: Date = Date()) {
        self.bundleId = bundleId
        self.pid = pid
        self.appName = appName
        self.capturedAt = capturedAt
    }
}

public enum InsertionError: Error, CustomStringConvertible {
    case focusChanged(String)
    case notPermitted(String)
    case secureInputActive
    case postFailed(String)
    case injectedFault

    public var description: String {
        switch self {
        case .focusChanged(let s): return "focus changed before insert: \(s)"
        case .notPermitted(let s): return "insertion not permitted: \(s)"
        case .secureInputActive: return "secure input is active (unsupported, SPEC §8.4)"
        case .postFailed(let s): return "event post failed: \(s)"
        case .injectedFault: return "injected insert fault"
        }
    }
}

public protocol TextInserter: Sendable {
    /// Snapshot the frontmost app at recording start.
    func captureFocus() async -> FocusTarget?
    /// Deliver text at the cursor. Throws InsertionError; never silently drops text.
    func insert(_ text: String, target: FocusTarget?) async throws
}

/// Headless placeholder inserter (used until the real paste inserter exists, and by tests).
public struct LoggingInserter: TextInserter {
    public init() {}
    public func captureFocus() async -> FocusTarget? { nil }
    public func insert(_ text: String, target: FocusTarget?) async throws {
        Log.info("insert.logged", msg: "chars=\(text.count) (LoggingInserter: no real insertion)")
    }
}
