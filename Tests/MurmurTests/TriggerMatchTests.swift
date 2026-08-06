import CoreGraphics
import XCTest

@testable import MurmurKit

/// Layer-3 hotkey logic tests (SPEC §10.4): the pure match function with synthetic
/// (latched-modifier, type, keycode) sequences — no live tap, no Input Monitoring.
final class TriggerMatchTests: XCTestCase {
    private let space = TriggerMatcher.keyCodeSpace
    private let keyA: CGKeyCode = 0x00

    private func flags(ctrl: Bool = false, cmd: Bool = false, fn: Bool = false, opt: Bool = false)
        -> CGEventFlags
    {
        var f = CGEventFlags()
        if ctrl { f.insert(.maskControl) }
        if cmd { f.insert(.maskCommand) }
        if fn { f.insert(.maskSecondaryFn) }
        if opt { f.insert(.maskAlternate) }
        return f
    }

    func testCtrlSpaceFiresAndSwallowsBothEdges() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        XCTAssertEqual(m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true)), .pass)
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true)), .fire)
        XCTAssertEqual(m.handle(type: .keyUp, keyCode: space, flags: flags(ctrl: true)), .swallow)
        XCTAssertEqual(m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags()), .pass)
        // Second tap toggles again.
        XCTAssertEqual(m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true)), .pass)
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true)), .fire)
        XCTAssertEqual(m.handle(type: .keyUp, keyCode: space, flags: flags(ctrl: true)), .swallow)
    }

    func testExactMatchRejectsCmdCtrlSpace() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true, cmd: true))
        XCTAssertEqual(
            m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true, cmd: true)), .pass,
            "superset modifiers must NOT fire (SPEC §4.2)")
    }

    func testLatchedStateNotEventFlags() {
        // The Space keyDown itself carries NO modifier bits — matching must rely on the latch.
        var m = TriggerMatcher(trigger: .ctrlSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags()), .fire)
    }

    func testPlainSpacePasses() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags()), .pass)
        XCTAssertEqual(m.handle(type: .keyUp, keyCode: space, flags: flags()), .pass)
    }

    func testOtherKeysWithCtrlPass() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: keyA, flags: flags(ctrl: true)), .pass)
    }

    func testAutorepeatSwallowedWithoutRefire() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true)), .fire)
        XCTAssertEqual(
            m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true), isAutorepeat: true),
            .swallow, "held chord must not toggle-flap")
        XCTAssertEqual(m.handle(type: .keyUp, keyCode: space, flags: flags(ctrl: true)), .swallow)
    }

    func testFnSpacePreset() {
        var m = TriggerMatcher(trigger: .fnSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3F, flags: flags(fn: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(fn: true)), .fire)
        XCTAssertEqual(m.handle(type: .keyUp, keyCode: space, flags: flags(fn: true)), .swallow)
        // Ctrl+Space must not fire the fn preset.
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true)), .pass)
    }

    func testReleaseModifierBeforeSpaceUpStillSwallowsUp() {
        var m = TriggerMatcher(trigger: .ctrlSpace)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags(ctrl: true))
        XCTAssertEqual(m.handle(type: .keyDown, keyCode: space, flags: flags(ctrl: true)), .fire)
        _ = m.handle(type: .flagsChanged, keyCode: 0x3B, flags: flags())  // ctrl released first
        XCTAssertEqual(
            m.handle(type: .keyUp, keyCode: space, flags: flags()), .swallow,
            "dangling space keyUp must not reach the focused app")
    }

    func testHUDStateTransitionsViaEngine() async throws {
        // SPEC §6 testability: hud state is observable without a screen.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-hud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(
            store: SessionStore(root: root), backend: MockBackend(), inserter: MockInserter(),
            config: Config())

        var hud = await engine.hudState
        XCTAssertEqual(hud.phase, .hidden)

        let src = FileAudioSource(url: Fixtures.url("long_60s.wav"), realtime: true)
        _ = try await engine.startRecording(source: src)
        hud = await engine.hudState
        XCTAssertEqual(hud.phase, .recording)

        _ = try await engine.stopAndFinalize()
        hud = await engine.hudState
        XCTAssertEqual(hud.phase, .transcribing)

        if let meta = await engine.lastSession() {
            await engine.runToCompletion(meta.id)
        }
        hud = await engine.hudState
        XCTAssertEqual(hud.phase, .hidden)
    }
}
