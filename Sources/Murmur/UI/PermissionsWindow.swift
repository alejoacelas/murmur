import AppKit
import MurmurKit
import SwiftUI

/// Live green/red status for the three TCC grants + deep links into System Settings
/// (SPEC §8.6). macOS often needs an app relaunch to see a fresh grant — say so.
@MainActor
final class PermissionsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Murmur Permissions"
            w.contentView = NSHostingView(rootView: PermissionsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PermissionsView: View {
    @State private var status = Permissions.current()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Microphone", granted: status.microphone,
                pane: "com.apple.preference.security?Privacy_Microphone",
                why: "recording your voice")
            row("Input Monitoring", granted: status.inputMonitoring,
                pane: "com.apple.preference.security?Privacy_ListenEvent",
                why: "the global hotkey")
            row("Accessibility", granted: status.accessibility,
                pane: "com.apple.preference.security?Privacy_Accessibility",
                why: "inserting text at your cursor")
            Divider()
            Text("After granting a permission, quit and relaunch Murmur — macOS applies grants at launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .onReceive(timer) { _ in status = Permissions.current() }
    }

    private func row(_ name: String, granted: Bool, pane: String, why: String) -> some View {
        HStack {
            Circle()
                .fill(granted ? .green : .red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text("needed for \(why)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
