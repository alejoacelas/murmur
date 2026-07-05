import Foundation
import XCTest

@testable import MurmurKit

final class SessionStoreTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-store-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateSaveLoadRoundtrip() async throws {
        let meta = try await store.create(model: "parakeet-v2")
        XCTAssertEqual(meta.state, .recording)
        var updated = meta
        updated.state = .transcribed
        updated.transcript = "hello"
        updated.durationSec = 1.5
        try await store.save(updated)

        let loaded = await store.load(meta.id)
        XCTAssertEqual(loaded?.state, .transcribed)
        XCTAssertEqual(loaded?.transcript, "hello")
        XCTAssertEqual(loaded?.durationSec, 1.5)
        // transcript.txt mirror
        let txt = try String(contentsOf: store.transcriptURL(meta.id), encoding: .utf8)
        XCTAssertEqual(txt, "hello")
    }

    func testAllSortedById() async throws {
        let a = try await store.create(model: "m")
        let b = try await store.create(model: "m")
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), [a.id, b.id].sorted())
    }

    func testAdoptOrphanWithAudioOnly() async throws {
        let id = "20990101-000000000-orfn"
        try FileManager.default.createDirectory(at: store.dir(id), withIntermediateDirectories: true)
        try TestAudio.writeCAF(TestAudio.tone(seconds: 0.5), to: store.cafURL(id))
        let adopted = await store.adoptOrphans(model: "m")
        XCTAssertEqual(adopted.map(\.id), [id])
        XCTAssertEqual(adopted.first?.state, .recorded)
        // Re-running adopts nothing new.
        let again = await store.adoptOrphans(model: "m")
        XCTAssertTrue(again.isEmpty)
    }

    func testDirWithoutAudioIsNotAdopted() async throws {
        let id = "20990101-000000000-noau"
        try FileManager.default.createDirectory(at: store.dir(id), withIntermediateDirectories: true)
        let adopted = await store.adoptOrphans(model: "m")
        XCTAssertTrue(adopted.isEmpty)
    }
}
