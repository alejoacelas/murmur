import AppKit
import MurmurKit
import SwiftUI

/// Floating live-transcript pill (SPEC §6). Display nicety only — the inserted text always
/// comes from the authoritative batch pass. Non-activating, click-through, joins all Spaces,
/// never steals focus.
@MainActor
final class TranscriptHUD {
    private let panel: NSPanel
    private let model = HUDModel()
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func apply(phase: Engine.HUDPhase, partial: String) {
        hideTask?.cancel()
        switch phase {
        case .recording:
            model.phase = .recording
            model.partial = partial
            show()
        case .transcribing:
            model.phase = .transcribing
            show()
        case .hidden:
            // Auto-hide shortly after insert/cancel (SPEC §6) so the pill doesn't blink out
            // the instant text lands.
            hideTask = Task { [panel] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func show() {
        position()
        panel.orderFrontRegardless()  // never activates, never steals focus
    }

    /// Just below the pointer (SPEC §6 — no caret tracking in v1).
    private func position() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - size.width - 8))
            origin.y = max(screen.frame.minY + 8, origin.y)
        }
        panel.setFrameOrigin(origin)
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    enum Phase {
        case recording, transcribing
    }
    @Published var phase: Phase = .recording
    @Published var partial: String = ""
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                Text(model.partial.isEmpty ? "listening…" : model.partial)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .font(.system(size: 12))
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("transcribing…")
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: 340)
        .fixedSize()
    }
}
