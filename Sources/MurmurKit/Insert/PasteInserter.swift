import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Real text insertion (SPEC §8.4, Appendix C). Default path: snapshot pasteboard → set our
/// string → synthesized Cmd+V → best-effort restore after a configurable delay (lossy by
/// design — file promises/custom providers don't round-trip). Typing fallback for
/// `insertion: "type"`. Focus is captured at recording START and re-checked here; if the user
/// refocused something else we try to re-activate the captured app, else fail safely into
/// `insertFailed` rather than pasting into the wrong window.
public actor PasteInserter: TextInserter {
    private let config: Config

    public init(config: Config) {
        self.config = config
    }

    public func captureFocus() async -> FocusTarget? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FocusTarget(
                bundleId: app.bundleIdentifier, pid: app.processIdentifier,
                appName: app.localizedName)
        }
    }

    public func insert(_ text: String, target: FocusTarget?) async throws {
        guard AXIsProcessTrusted() else {
            throw InsertionError.notPermitted("Accessibility not granted")
        }
        if Permissions.secureInputActive() {
            throw InsertionError.secureInputActive
        }
        if let target {
            try await ensureFrontmost(target)
        }
        switch config.insertion {
        case .paste:
            try await paste(text)
        case .type:
            try await type(text)
        }
    }

    // MARK: focus re-check

    private func ensureFrontmost(_ target: FocusTarget) async throws {
        if await frontPID() == target.pid { return }
        // Try to bring the captured app back (common in toggle mode).
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            _ = await MainActor.run { app.activate(options: []) }
            for _ in 0..<10 {  // up to ~1 s
                try? await Task.sleep(nanoseconds: 100_000_000)
                if await frontPID() == target.pid { return }
            }
        }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
        throw InsertionError.focusChanged(
            "captured=\(target.appName ?? "?") frontmost=\(front)")
    }

    private func frontPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    // MARK: paste path

    private func paste(_ text: String) async throws {
        // Snapshot as plain (type, data) pairs — Sendable, unlike NSPasteboardItem. Lossy for
        // custom providers/file promises by design (SPEC §8.4: best-effort restore).
        let saved: [[(String, Data)]] = await MainActor.run {
            let pb = NSPasteboard.general
            let copies = pb.pasteboardItems?.map { item in
                item.types.compactMap { t -> (String, Data)? in
                    guard let d = item.data(forType: t) else { return nil }
                    return (t.rawValue, d)
                }
            } ?? []
            pb.clearContents()
            pb.setString(text, forType: .string)
            return copies
        }
        // Give the pasteboard write a beat to settle before the target reads it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        try postKey(virtualKey: 0x09, flags: .maskCommand)  // Cmd+V

        if config.preserveClipboard {
            let delayNs = UInt64(max(config.clipboardRestoreDelayMs, 50)) * 1_000_000
            Task {
                try? await Task.sleep(nanoseconds: delayNs)
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    let items = saved.map { pairs -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (type, data) in pairs {
                            item.setData(data, forType: NSPasteboard.PasteboardType(type))
                        }
                        return item
                    }
                    if !items.isEmpty { pb.writeObjects(items) }
                }
                Log.debug("insert.clipboard_restored", msg: "items=\(saved.count)")
            }
        }
    }

    // MARK: typing fallback (ASCII-ish only — SPEC §8.4)

    private func type(_ text: String) async throws {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertionError.postFailed("no CGEventSource")
        }
        let chars = Array(text.utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 20, chars.count)])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { throw InsertionError.postFailed("CGEvent create failed") }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            i += 20
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        guard let src = CGEventSource(stateID: .combinedSessionState),
            let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        else { throw InsertionError.postFailed("CGEvent create failed") }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
