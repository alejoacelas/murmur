// postkeys — post a synthetic Ctrl+Space chord (layer-6 hotkey smoke, SPEC §10.4).
// Verified: synthetic modifier key events arrive at session taps as flagsChanged with correct
// flags, so the app's latched matcher sees exactly what real hardware produces.
import CoreGraphics
import Foundation

let src = CGEventSource(stateID: .combinedSessionState)
let ctrlDown = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: true)!
ctrlDown.flags = .maskControl
ctrlDown.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
let spaceDown = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: true)!
spaceDown.flags = .maskControl
spaceDown.post(tap: .cghidEventTap)
let spaceUp = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: false)!
spaceUp.flags = .maskControl
spaceUp.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.05)
let ctrlUp = CGEvent(keyboardEventSource: src, virtualKey: 0x3B, keyDown: false)!
ctrlUp.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
print("posted ctrl+space")
