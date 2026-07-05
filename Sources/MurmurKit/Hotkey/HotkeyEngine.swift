import CoreGraphics
import Foundation

/// Live CGEventTap wiring around the pure `TriggerMatcher` (SPEC §4, Appendix A). Session-level
/// active tap (an active/default tap is required to swallow events); needs Input Monitoring.
/// The callback stays minimal: matcher decision, then hop off for the toggle action.
public final class HotkeyEngine: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher: TriggerMatcher
    private let onFire: @Sendable () -> Void
    private let lock = NSLock()

    public init(trigger: Config.Trigger, onFire: @escaping @Sendable () -> Void) {
        self.matcher = TriggerMatcher(trigger: trigger)
        self.onFire = onFire
    }

    public enum HotkeyError: Error, CustomStringConvertible {
        case tapCreateFailed

        public var description: String {
            "CGEventTap creation failed — Input Monitoring not granted? (SPEC §8.6)"
        }
    }

    /// Install the tap on the current run loop (call from the main thread).
    public func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,  // active: returning nil swallows the event
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let engine = Unmanaged<HotkeyEngine>.fromOpaque(refcon).takeUnretainedValue()
                    return engine.handle(type: type, event: event)
                },
                userInfo: refcon)
        else {
            throw HotkeyError.tapCreateFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("hotkey.tap_installed", msg: "trigger=\(matcher.trigger.rawValue)")
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables taps that stall or when the user opts out; mandatory re-enable (§4.2).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.warn("hotkey.tap_reenabled", msg: "type=\(type.rawValue)")
            }
            return nil
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        lock.lock()
        let decision = matcher.handle(
            type: type, keyCode: keyCode, flags: event.flags, isAutorepeat: isRepeat)
        lock.unlock()

        switch decision {
        case .fire:
            onFire()  // must be cheap+async; blocking here gets the tap killed
            return nil
        case .swallow:
            return nil
        case .pass:
            return Unmanaged.passUnretained(event)
        }
    }
}
