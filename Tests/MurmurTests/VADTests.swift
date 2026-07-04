import XCTest

@testable import MurmurKit

final class VADTests: XCTestCase {
    func testSilenceFixtureIsBelowThresholdAndSpeechAbove() throws {
        let silence = try Fixtures.samples("silence.wav")
        let speech = try Fixtures.samples("hello_world.wav")
        let threshold = Config().silenceRMSThreshold

        let silenceRMS = VAD.rms(silence)
        let speechRMS = VAD.rms(speech)
        print("VAD rms: silence=\(silenceRMS) speech=\(speechRMS) threshold=\(threshold)")

        XCTAssertTrue(VAD.isSilence(silence, threshold: threshold),
            "silence fixture rms=\(silenceRMS) should be below \(threshold)")
        XCTAssertFalse(VAD.isSilence(speech, threshold: threshold),
            "speech fixture rms=\(speechRMS) should be above \(threshold)")
    }

    func testEmptyInputIsSilence() {
        XCTAssertTrue(VAD.isSilence([], threshold: 0.002))
    }
}
