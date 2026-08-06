import Foundation
import XCTest

@testable import MurmurKit

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let cfg = Config.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))
        XCTAssertEqual(cfg.trigger, .ctrlSpace)
        XCTAssertEqual(cfg.insertion, .paste)
        XCTAssertTrue(cfg.preserveClipboard)
        XCTAssertEqual(cfg.retention, .keep)
    }

    func testParsesKnownFieldsAndIgnoresBrokenValues() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
            {"trigger":"fn-space","insertion":"type","preserveClipboard":false,
             "retention":"deleteOnSuccess","clipboardRestoreDelayMs":150,
             "model":"parakeet-v2","silenceRMSThreshold":0.01,
             "unknownField":true}
            """
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let cfg = Config.load(from: tmp)
        XCTAssertEqual(cfg.trigger, .fnSpace)
        XCTAssertEqual(cfg.insertion, .type)
        XCTAssertFalse(cfg.preserveClipboard)
        XCTAssertEqual(cfg.retention, .deleteOnSuccess)
        XCTAssertEqual(cfg.clipboardRestoreDelayMs, 150)
        XCTAssertEqual(cfg.silenceRMSThreshold, 0.01, accuracy: 1e-6)
    }

    func testInvalidEnumFallsBackToDefault() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-cfg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"trigger":"cmd-shift-q","insertion":"teleport"}"#.write(
            to: tmp, atomically: true, encoding: .utf8)
        let cfg = Config.load(from: tmp)
        XCTAssertEqual(cfg.trigger, .ctrlSpace)
        XCTAssertEqual(cfg.insertion, .paste)
    }
}
