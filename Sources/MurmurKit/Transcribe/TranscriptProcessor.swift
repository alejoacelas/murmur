import Foundation

/// Post-transcription hook (SPEC §8.3). Ships as a no-op: the raw Parakeet transcript is what
/// gets inserted — no LLM, no "cleanup". The seam exists so a future processor touches one file.
public protocol TranscriptProcessor: Sendable {
    func process(_ transcript: String) -> String
}

public struct IdentityProcessor: TranscriptProcessor {
    public init() {}
    public func process(_ transcript: String) -> String { transcript }
}
