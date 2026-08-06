import Foundation
import XCTest

@testable import MurmurKit

/// Layer-1 backend tests (SPEC §10.4): real model, real fixtures, no permissions needed.
/// Assertion policy per SPEC §10.3 — exact normalized match on short clips, WER on the long one.
final class BackendTests: XCTestCase {
    /// One warm backend for the whole suite; model load is ~0.5 s from a warm cache.
    static let backend = FluidAudioBackend()

    private func transcribed(_ fixture: String) async throws -> String {
        try await Self.backend.transcribe(fileURL: Fixtures.url(fixture))
    }

    func testHelloWorldExactNormalized() async throws {
        let text = try await transcribed("hello_world.wav")
        XCTAssertEqual(TextMatch.normalize(text), Fixtures.expected["hello_world.wav"]!)
    }

    func testQuickBrownFoxExactNormalized() async throws {
        let text = try await transcribed("the_quick_brown_fox.wav")
        XCTAssertEqual(TextMatch.normalize(text), Fixtures.expected["the_quick_brown_fox.wav"]!)
    }

    func testNumbersExactNormalized() async throws {
        let text = try await transcribed("numbers.wav")
        XCTAssertEqual(TextMatch.normalize(text), Fixtures.expected["numbers.wav"]!)
    }

    func testLong60sWithinWERBudget() async throws {
        let text = try await transcribed("long_60s.wav")
        let wer = TextMatch.wer(reference: Fixtures.expected["long_60s.wav"]!, hypothesis: text)
        print("long_60s WER = \(wer)")
        XCTAssertLessThanOrEqual(wer, 0.1)
    }

    func testSilenceProducesEmptyTranscript() async throws {
        // Both layers must hold: the VAD gate catches it before the model in the app path,
        // and the model itself returns empty for this fixture (spike S2).
        let samples = try Fixtures.samples("silence.wav")
        XCTAssertTrue(VAD.isSilence(samples, threshold: Config().silenceRMSThreshold))
        let text = try await transcribed("silence.wav")
        XCTAssertEqual(TextMatch.normalize(text), "")
    }

    func testSamplesPathMatchesFilePath() async throws {
        let samples = try Fixtures.samples("hello_world.wav")
        let text = try await Self.backend.transcribe(samples)
        XCTAssertEqual(TextMatch.normalize(text), "hello world")
    }

    func testStreamingSessionYieldsPartials() async throws {
        try await Self.backend.ensureModelReady()
        guard let session = await Self.backend.makeStreamingSession() else {
            return XCTFail("streaming session unavailable")
        }
        let samples = try Fixtures.samples("long_60s.wav")
        let updatesStream = await session.updates
        let collector = Task { () -> [StreamingUpdate] in
            var got: [StreamingUpdate] = []
            for await u in updatesStream { got.append(u) }
            return got
        }
        // Feed in ~1 s chunks.
        var i = 0
        while i < samples.count {
            let end = min(i + 16_000, samples.count)
            await session.feed(Array(samples[i..<end]))
            i = end
        }
        let finalText = try await session.finish()
        let updates = await collector.value
        print("streaming updates=\(updates.count) final.chars=\(finalText.count)")
        XCTAssertGreaterThan(updates.count, 0, "expected at least one partial update")
        XCTAssertFalse(finalText.isEmpty)
    }
}
