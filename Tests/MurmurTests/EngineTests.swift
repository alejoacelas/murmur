import Foundation
import XCTest

@testable import MurmurKit

/// Layer-2 persistence/retry tests (SPEC §10.4): mock backend + inserter, real files, real
/// state machine. Fast — no model, no permissions.
final class EngineTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!
    private var backend: MockBackend!
    private var inserter: MockInserter!
    private var engine: Engine!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-engine-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
        backend = MockBackend()
        inserter = MockInserter()
        engine = Engine(store: store, backend: backend, inserter: inserter, config: Config())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func fixture(_ name: String) -> URL { Fixtures.url(name) }

    // MARK: happy path

    func testInjectHappyPathReachesInsertedAndPersistsArtifacts() async throws {
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        XCTAssertEqual(result.transcript, "mock transcript")

        let meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .inserted)
        XCTAssertEqual(meta?.transcript, "mock transcript")
        XCTAssertGreaterThan(meta?.durationSec ?? 0, 0.5)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: store.cafURL(result.sessionId).path), "authoritative CAF")
        XCTAssertTrue(fm.fileExists(atPath: store.wavURL(result.sessionId).path), "derived WAV")
        XCTAssertTrue(fm.fileExists(atPath: store.transcriptURL(result.sessionId).path))

        let insertedTexts = await inserter.inserted
        XCTAssertEqual(insertedTexts, ["mock transcript"])

        // The CAF really contains the fixture audio (round-trip duration check).
        let samples = try AudioFiles.loadCanonicalSamples(store.cafURL(result.sessionId))
        XCTAssertEqual(Double(samples.count) / 16_000, meta?.durationSec ?? -1, accuracy: 0.05)
    }

    func testSilenceInjectGatesAndInsertsNothing() async throws {
        let result = try await engine.inject(wav: fixture("silence.wav"))
        XCTAssertEqual(result.transcript, "")
        let meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .inserted)  // terminal success, nothing inserted
        let insertedTexts = await inserter.inserted
        XCTAssertTrue(insertedTexts.isEmpty)
        let calls = await backend.transcribeCalls
        XCTAssertEqual(calls, 0, "silence must not reach the model (SPEC §5.4)")
    }

    // MARK: retry classification

    func testTransientFailuresAutoRetryToSuccess() async throws {
        await backend.setTransientFailures(2)
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        let meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .inserted)
        XCTAssertEqual(meta?.attempts, 3)  // 2 failures + 1 success
        let calls = await backend.transcribeCalls
        XCTAssertEqual(calls, 3)
    }

    func testTransientBudgetExhaustsThenManualRetryHeals() async throws {
        await backend.setTransientFailures(99)
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        var meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .transcribeFailed)
        XCTAssertEqual(meta?.failureClass, .transient)
        XCTAssertEqual(meta?.attempts, 3)

        // Launch recovery must NOT thrash: budget is spent.
        let callsBefore = await backend.transcribeCalls
        await engine.recoverAtLaunch()
        let callsAfterRecover = await backend.transcribeCalls
        XCTAssertEqual(callsBefore, callsAfterRecover)

        // Manual retry resets the budget; backend is healthy now.
        await backend.setTransientFailures(0)
        meta = try await engine.retry(result.sessionId)
        XCTAssertEqual(meta?.state, .inserted)
        XCTAssertEqual(meta?.transcript, "mock transcript")
    }

    func testPermanentFailureDoesNotAutoRetry() async throws {
        await backend.setPermanentOnce()
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        let meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .transcribeFailed)
        XCTAssertEqual(meta?.failureClass, .permanent)
        XCTAssertEqual(meta?.attempts, 1, "permanent failure must stop immediately")

        let callsBefore = await backend.transcribeCalls
        await engine.recoverAtLaunch()
        let callsAfter = await backend.transcribeCalls
        XCTAssertEqual(callsBefore, callsAfter, "recovery must not thrash on permanent failures")
    }

    func testInsertFailedRetryReinsertsWithoutRetranscribing() async throws {
        await inserter.setFailNext()
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        var meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .insertFailed)
        XCTAssertEqual(meta?.transcript, "mock transcript", "transcript survives insert failure")
        let callsAfterFailure = await backend.transcribeCalls

        meta = try await engine.retry(result.sessionId)
        XCTAssertEqual(meta?.state, .inserted)
        let callsAfterRetry = await backend.transcribeCalls
        XCTAssertEqual(callsAfterFailure, callsAfterRetry, "retry of insertFailed must NOT re-transcribe")
        let insertedTexts = await inserter.inserted
        XCTAssertEqual(insertedTexts, ["mock transcript"])
    }

    // MARK: fault injection (the control-API path)

    func testInjectedTranscribeFaultsClassifyCorrectly() async throws {
        _ = await engine.setFault(kind: "fail-transcribe", value: "permanent")
        let r1 = try await engine.inject(wav: fixture("hello_world.wav"))
        let m1 = await store.load(r1.sessionId)
        XCTAssertEqual(m1?.state, .transcribeFailed)
        XCTAssertEqual(m1?.failureClass, .permanent)

        _ = await engine.setFault(kind: "fail-transcribe", value: "off")
        let r2 = try await engine.inject(wav: fixture("hello_world.wav"))
        let m2 = await store.load(r2.sessionId)
        XCTAssertEqual(m2?.state, .inserted)
    }

    func testInjectedInsertFault() async throws {
        _ = await engine.setFault(kind: "fail-insert", value: "on")
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        let meta = await store.load(result.sessionId)
        XCTAssertEqual(meta?.state, .insertFailed)
        _ = await engine.setFault(kind: "fail-insert", value: "off")
        let healed = try await engine.retry(result.sessionId)
        XCTAssertEqual(healed.state, .inserted)
    }

    // MARK: crash recovery

    func testCrashMidRecordingIsFinalizedAndCompleted() async throws {
        // Fabricate what a SIGKILL mid-recording leaves behind: meta stuck in `recording`,
        // a valid partial CAF (S12), no WAV.
        let meta = try await store.create(model: "parakeet-v2")
        try TestAudio.writeCAF(TestAudio.tone(seconds: 2.0), to: store.cafURL(meta.id))

        await engine.recoverAtLaunch()

        let recovered = await store.load(meta.id)
        XCTAssertEqual(recovered?.state, .inserted)
        XCTAssertEqual(recovered?.transcript, "mock transcript")
        XCTAssertEqual(recovered?.durationSec ?? 0, 2.0, accuracy: 0.05)
    }

    func testCrashMidRecordingWithNoAudioIsMarkedPermanent() async throws {
        let meta = try await store.create(model: "parakeet-v2")  // recording, no CAF ever written
        await engine.recoverAtLaunch()
        let recovered = await store.load(meta.id)
        XCTAssertEqual(recovered?.state, .transcribeFailed)
        XCTAssertEqual(recovered?.failureClass, .permanent)
    }

    func testOrphanDirIsAdoptedAndCompleted() async throws {
        let id = "20990101-000000000-orph"
        try FileManager.default.createDirectory(at: store.dir(id), withIntermediateDirectories: true)
        try TestAudio.writeCAF(TestAudio.tone(seconds: 1.0), to: store.cafURL(id))

        await engine.recoverAtLaunch()

        let meta = await store.load(id)
        XCTAssertEqual(meta?.state, .inserted)
        XCTAssertEqual(meta?.transcript, "mock transcript")
    }

    func testInsertFailedIsLeftForManualRetryAtLaunch() async throws {
        _ = await engine.setFault(kind: "fail-insert", value: "on")
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        _ = await engine.setFault(kind: "fail-insert", value: "off")

        await engine.recoverAtLaunch()
        let meta = await store.load(result.sessionId)
        XCTAssertEqual(
            meta?.state, .insertFailed,
            "relaunch must not blind-paste into whatever is focused (SPEC §7.3)")
    }

    // MARK: recording lifecycle guards

    func testDoubleStartThrows() async throws {
        let src = FileAudioSource(url: fixture("long_60s.wav"), realtime: true)
        _ = try await engine.startRecording(source: src)
        do {
            _ = try await engine.startRecording(source: FileAudioSource(url: fixture("hello_world.wav")))
            XCTFail("second start must throw")
        } catch {}
        _ = try await engine.stopAndFinalize()
    }

    func testStopWithoutStartThrows() async {
        do {
            _ = try await engine.stopAndFinalize()
            XCTFail("stop without start must throw")
        } catch {}
    }

    func testAwaitStateReachesTerminal() async throws {
        let result = try await engine.inject(wav: fixture("hello_world.wav"))
        let ok = await engine.awaitState(id: result.sessionId, state: .inserted, timeoutMs: 1000)
        XCTAssertTrue(ok)
        let no = await engine.awaitState(id: result.sessionId, state: .recording, timeoutMs: 200)
        XCTAssertFalse(no)
    }
}
