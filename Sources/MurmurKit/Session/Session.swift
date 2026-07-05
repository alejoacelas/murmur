import Foundation

/// Split-state machine (SPEC §7.2). Transcription failure ≠ insertion failure: retrying an
/// `insertFailed` session re-inserts the existing transcript and never re-transcribes.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case recording
    case recorded
    case transcribing
    case transcribed
    case inserting
    case inserted
    case transcribeFailed
    case insertFailed

    public var isTerminalSuccess: Bool { self == .inserted }
}

public enum FailureClass: String, Codable, Sendable {
    /// Worth retrying automatically (model warm-up, transient I/O).
    case transient
    /// Retrying can't help without human action (corrupt/empty audio, missing model).
    case permanent
}

/// `meta.json` — written atomically on every state change (SPEC §7.1).
public struct SessionMeta: Codable, Sendable, Equatable {
    public var id: String
    public var state: SessionState
    public var attempts: Int
    public var failureClass: FailureClass?
    public var lastError: String?
    public var model: String
    public var durationSec: Double?
    public var transcript: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, model: String, state: SessionState = .recording, now: Date = Date()) {
        self.id = id
        self.state = state
        self.attempts = 0
        self.model = model
        self.createdAt = now
        self.updatedAt = now
    }
}
