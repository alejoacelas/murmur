import Foundation

/// The seam that hides FluidAudio (SPEC §8.1). An upstream API change — or an engine swap —
/// touches `FluidAudioBackend` only. Batch (`transcribe`) is the AUTHORITATIVE pass: its output
/// is the only text ever inserted. Streaming exists solely to feed the HUD (SPEC §8.2).
public protocol TranscriptionBackend: Sendable {
    /// Download + load the model. Idempotent and cached; safe to call eagerly at launch.
    func ensureModelReady() async throws
    /// True once the model is warm (non-blocking status probe for `murmurctl health`).
    var modelReady: Bool { get async }
    /// Batch pass over canonical 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Batch pass over an audio file (WAV/CAF); the backend resamples as needed.
    func transcribe(fileURL: URL) async throws -> String
    /// Best-effort streaming session for HUD partials; nil when unavailable.
    func makeStreamingSession() async -> StreamingSession?
}

public struct StreamingUpdate: Sendable {
    public let text: String
    public let isConfirmed: Bool
    public init(text: String, isConfirmed: Bool) {
        self.text = text
        self.isConfirmed = isConfirmed
    }
}

/// Live-partials session (HUD only — never the source of inserted text).
public protocol StreamingSession: Sendable {
    /// Feed canonical 16 kHz mono Float32 samples as they arrive.
    func feed(_ samples: [Float]) async
    /// Partial-transcript updates, in order. Ends after `finish()`/`cancel()`.
    var updates: AsyncStream<StreamingUpdate> { get async }
    /// Flush and end the stream. The returned text is NOT inserted (batch is authoritative).
    func finish() async throws -> String
    func cancel() async
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case backendUnavailable(String)
    case audioUnreadable(String)

    public var description: String {
        switch self {
        case .backendUnavailable(let s): return "transcription backend unavailable: \(s)"
        case .audioUnreadable(let s): return "audio unreadable: \(s)"
        }
    }
}
