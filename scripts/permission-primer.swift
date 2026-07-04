// permission-primer.swift — standalone helper to FRONTLOAD the one manual step.
//
// SIP is enabled and this Mac isn't MDM-enrolled, so the three TCC permissions Murmur needs
// (Microphone, Input Monitoring, Accessibility) can't be granted programmatically — they need a
// one-time human toggle. This binary is bundled as Murmur.app with the REAL bundle id + stable
// cert, then run so it (a) triggers each system prompt and (b) polls status until all three are
// granted, so the agent can detect completion. Because the bundle id + designated requirement are
// identical to the real app, the grants persist for every later rebuild.
//
// It reuses the exact same detection APIs the real app's Permissions.swift will use (§8.6).

import Foundation
import AVFoundation
import CoreGraphics
import ApplicationServices

func micGranted() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
}
func inputMonitoringGranted() -> Bool {
    CGPreflightListenEventAccess()
}
func accessibilityGranted() -> Bool {
    AXIsProcessTrusted()
}

func statusLine() -> String {
    let mic = micGranted(), im = inputMonitoringGranted(), ax = accessibilityGranted()
    return "STATUS {\"microphone\":\(mic),\"inputMonitoring\":\(im),\"accessibility\":\(ax)}"
}

let statusLogURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Murmur")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("primer-status.log")
}()

func emit(_ s: String) {
    print(s)
    fflush(stdout)
    // Also append to a file so we can observe status when launched detached via `open`.
    if let data = (s + "\n").data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: statusLogURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: statusLogURL)
        }
    }
}

emit("PRIMER Murmur permission primer starting (pid \(getpid())).")
emit("PRIMER Bundle: \(Bundle.main.bundleIdentifier ?? "nil") at \(Bundle.main.bundlePath)")
emit(statusLine())

// Trigger the three system prompts (only where not already granted).
if !micGranted() {
    emit("PRIMER Requesting Microphone… (click Allow on the dialog)")
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        FileHandle.standardOutput.write("PRIMER mic requestAccess -> \(granted)\n".data(using: .utf8)!)
    }
}
if !inputMonitoringGranted() {
    emit("PRIMER Requesting Input Monitoring… (approve, then toggle Murmur ON in System Settings)")
    _ = CGRequestListenEventAccess()
}
if !accessibilityGranted() {
    emit("PRIMER Requesting Accessibility… (toggle Murmur ON in System Settings > Privacy & Security > Accessibility)")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

// Poll until all three are granted, or time out.
let deadline = Date().addingTimeInterval(900) // 15 minutes
var lastStatus = ""
while Date() < deadline {
    let s = statusLine()
    if s != lastStatus { emit(s); lastStatus = s }
    if micGranted() && inputMonitoringGranted() && accessibilityGranted() {
        emit("PRIMER ALL GRANTED — permissions complete.")
        exit(0)
    }
    // Keep a run loop turning so completion handlers / prompts behave.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
}
emit("PRIMER TIMEOUT — not all permissions granted.")
emit(statusLine())
exit(2)
