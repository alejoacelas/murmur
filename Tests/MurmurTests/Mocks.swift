import AVFoundation
import Foundation

@testable import MurmurKit

/// Fast fake backend for layer-2 persistence/retry tests — no model, no permissions.
actor MockBackend: TranscriptionBackend {
    var result = "mock transcript"
    private(set) var transcribeCalls = 0
    /// Next N transcribe calls throw a transient-classified error.
    var transientFailuresRemaining = 0
    /// Next transcribe call throws a permanent-classified error.
    var failPermanentlyOnce = false

    var modelReady: Bool { true }

    func ensureModelReady() async throws {}

    func transcribe(_ samples: [Float]) async throws -> String {
        transcribeCalls += 1
        if failPermanentlyOnce {
            failPermanentlyOnce = false
            throw TranscriptionError.audioUnreadable("mock permanent failure")
        }
        if transientFailuresRemaining > 0 {
            transientFailuresRemaining -= 1
            throw NSError(domain: "mock.transient", code: 1)
        }
        return result
    }

    func transcribe(fileURL: URL) async throws -> String {
        try await transcribe([Float]())
    }

    func makeStreamingSession() async -> StreamingSession? { nil }

    func setTransientFailures(_ n: Int) { transientFailuresRemaining = n }
    func setPermanentOnce() { failPermanentlyOnce = true }
}

/// Records insertions; optionally fails.
actor MockInserter: TextInserter {
    private(set) var inserted: [String] = []
    var failNext = false

    func captureFocus() async -> FocusTarget? {
        FocusTarget(bundleId: "test.mock", pid: 1, appName: "Mock")
    }

    func insert(_ text: String, target: FocusTarget?) async throws {
        if failNext {
            failNext = false
            throw InsertionError.postFailed("mock insert failure")
        }
        inserted.append(text)
    }

    func setFailNext() { failNext = true }
}

enum TestAudio {
    /// Write canonical samples as a CAF — used to fabricate crash-leftover sessions.
    static func writeCAF(_ samples: [Float], to url: URL) throws {
        let f = try AVAudioFile(
            forWriting: url, settings: CanonicalAudio.format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: CanonicalAudio.buffer(from: samples)!)
    }

    static func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let n = Int(seconds * CanonicalAudio.sampleRate)
        var phase: Float = 0
        return (0..<n).map { _ in
            phase += 0.12
            return sinf(phase) * amplitude
        }
    }
}
