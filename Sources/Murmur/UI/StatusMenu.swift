import AppKit
import MurmurKit

/// Menu bar presence (SPEC §12 M4). NSStatusItem rather than SwiftUI's MenuBarExtra because the
/// app uses main.swift top-level bootstrap; functionally equivalent for a glyph + menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let engine: Engine
    private let permissionsWindow: PermissionsWindowController
    private var phase: Engine.HUDPhase = .hidden

    init(engine: Engine, permissionsWindow: PermissionsWindowController) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.engine = engine
        self.permissionsWindow = permissionsWindow
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        setPhase(.hidden)
    }

    func setPhase(_ phase: Engine.HUDPhase) {
        self.phase = phase
        let symbol: String
        switch phase {
        case .hidden: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "waveform"
        }
        item.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Murmur (\(phase.rawValue))")
    }

    // Rebuild the menu lazily each open — cheap, always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let engine = self.engine
        let phase = self.phase
        Task { @MainActor in
            let last = await engine.lastSession()
            let permissions = Permissions.current()
            menu.removeAllItems()

            let state = NSMenuItem(
                title: phase == .hidden
                    ? "Murmur — idle" : "Murmur — \(phase.rawValue)",
                action: nil, keyEquivalent: "")
            state.isEnabled = false
            menu.addItem(state)

            if let last {
                let text = (last.transcript ?? "").isEmpty ? "(\(last.state.rawValue))" : last.transcript!
                let lastItem = NSMenuItem(
                    title: "Last: \(String(text.prefix(48)))", action: nil, keyEquivalent: "")
                lastItem.isEnabled = false
                menu.addItem(lastItem)
                if last.state == .transcribeFailed || last.state == .insertFailed {
                    let retry = NSMenuItem(
                        title: "Retry Last (\(last.state.rawValue))",
                        action: #selector(self.retryLast), keyEquivalent: "")
                    retry.target = self
                    menu.addItem(retry)
                }
            }
            menu.addItem(.separator())

            let toggle = NSMenuItem(
                title: phase == .recording ? "Stop Recording" : "Start Recording",
                action: #selector(self.toggleRecording), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)

            if !permissions.allGranted {
                let warn = NSMenuItem(
                    title: "⚠ Permissions missing…", action: #selector(self.showPermissions),
                    keyEquivalent: "")
                warn.target = self
                menu.addItem(warn)
            } else {
                let perms = NSMenuItem(
                    title: "Permissions…", action: #selector(self.showPermissions), keyEquivalent: "")
                perms.target = self
                menu.addItem(perms)
            }

            let open = NSMenuItem(
                title: "Open Recordings Folder", action: #selector(self.openRecordings),
                keyEquivalent: "")
            open.target = self
            menu.addItem(open)

            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Murmur", action: #selector(self.quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
        }
    }

    @objc private func toggleRecording() {
        let engine = self.engine
        Task { await engine.toggle() }
    }

    @objc private func retryLast() {
        let engine = self.engine
        Task {
            if let last = await engine.lastSession() {
                _ = try? await engine.retry(last.id)
            }
        }
    }

    @objc private func showPermissions() {
        permissionsWindow.show()
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(Paths.recordings)
    }

    @objc private func quit() {
        Log.info("app.quit", msg: "menu")
        Log.flush()
        NSApp.terminate(nil)
    }
}
