// InsertionProbe — tiny e2e target (SPEC §10.5). A focused NSTextView that mirrors its content
// to a readback file, replacing AppleScript/TextEdit (no 4th TCC domain, no focus flakiness).
//
//   PROBE_OUT   readback file (default $MURMUR_HOME-independent: /tmp-ish TMPDIR/probe-out.txt)
//
// Writes "<PROBE_OUT>.ready" once the window is key and the app is active; then mirrors the
// text view's contents to PROBE_OUT on every change (event-driven + 100 ms failsafe timer).
import AppKit
import Foundation

let outPath: String = {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        if a == "--out", let v = it.next() { return v }
    }
    return ProcessInfo.processInfo.environment["PROBE_OUT"]
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("probe-out.txt")
}()
let outURL = URL(fileURLWithPath: outPath)
let readyURL = URL(fileURLWithPath: outPath + ".ready")
let clearURL = URL(fileURLWithPath: outPath + ".clear")  // harness touches this to reset the view
try? FileManager.default.removeItem(at: outURL)
try? FileManager.default.removeItem(at: readyURL)
try? FileManager.default.removeItem(at: clearURL)

final class ProbeController: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    private var lastWritten = "\u{0}never"
    private var announcedReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 200, y: 200, width: 480, height: 300)
        window = NSWindow(
            contentRect: rect, styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "InsertionProbe"

        let scroll = NSScrollView(frame: rect)
        textView = NSTextView(frame: rect)
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.delegate = self
        scroll.documentView = textView
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        print("PROBE launched pid=\(getpid()) out=\(outPath)")
        fflush(stdout)
    }

    func textDidChange(_ notification: Notification) {
        mirror()
    }

    private func tick() {
        if FileManager.default.fileExists(atPath: clearURL.path) {
            try? FileManager.default.removeItem(at: clearURL)
            textView.string = ""
        }
        // Heartbeat: the ready marker exists ONLY while this window is truly frontmost + key.
        // The harness checks the marker's freshness right before pasting so a user grabbing
        // focus mid-run aborts the test instead of pasting into their app.
        let ready =
            NSApp.isActive && window.isKeyWindow && window.firstResponder === textView
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        if ready {
            try? "ready \(Date().timeIntervalSince1970)\n".write(
                to: readyURL, atomically: true, encoding: .utf8)
            if !announcedReady {
                announcedReady = true
                print("PROBE ready (key window, focused text view)")
                fflush(stdout)
            }
        } else if announcedReady {
            try? FileManager.default.removeItem(at: readyURL)
        }
        mirror()
    }

    private func mirror() {
        let text = textView.string
        guard text != lastWritten else { return }
        lastWritten = text
        try? text.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Cmd+V is a MENU key equivalent — without an Edit menu the paste chord is dead. This is why
// the probe must build a real menu bar even though no human ever clicks it.
let mainMenu = NSMenu()
let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit InsertionProbe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

let controller = ProbeController()
app.delegate = controller
app.run()
