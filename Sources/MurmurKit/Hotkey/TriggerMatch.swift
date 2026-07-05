import CoreGraphics
import Foundation

/// Pure, unit-testable hotkey matching (SPEC §4.2, Appendix A). The live CGEventTap feeds every
/// event through `handle`; layer-3 tests call it with synthetic sequences — no tap needed.
///
/// Rules encoded here:
/// - Match on LATCHED modifier state (updated from flagsChanged), not the key event's own flags.
/// - EXACT modifier match: Ctrl+Space must not fire on Cmd+Ctrl+Space.
/// - Swallow both keyDown and keyUp of the trigger chord; swallow (but don't re-fire) autorepeat.
public struct TriggerMatcher: Sendable {
    public struct Latched: Equatable, Sendable {
        public var fn = false
        public var ctrl = false
        public var cmd = false
        public var opt = false
        public var shift = false

        public init() {}
    }

    public enum Decision: Equatable, Sendable {
        /// Toggle recording AND swallow this event.
        case fire
        /// Swallow this event (trigger chord artifacts: its keyUp, its autorepeat).
        case swallow
        /// Not ours — let it through.
        case pass
    }

    public let trigger: Config.Trigger
    public private(set) var latched = Latched()
    private var swallowKeyUp = false
    private var chordHeld = false

    public init(trigger: Config.Trigger) {
        self.trigger = trigger
    }

    public static let keyCodeSpace: CGKeyCode = 0x31

    public mutating func handle(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags, isAutorepeat: Bool = false)
        -> Decision
    {
        switch type {
        case .flagsChanged:
            latched.fn = flags.contains(.maskSecondaryFn)
            latched.ctrl = flags.contains(.maskControl)
            latched.cmd = flags.contains(.maskCommand)
            latched.opt = flags.contains(.maskAlternate)
            latched.shift = flags.contains(.maskShift)
            return .pass

        case .keyDown:
            guard keyCode == Self.keyCodeSpace, modifiersMatchExactly() else { return .pass }
            swallowKeyUp = true
            if isAutorepeat || chordHeld {
                return .swallow  // holding the chord must not toggle-flap
            }
            chordHeld = true
            return .fire

        case .keyUp:
            if keyCode == Self.keyCodeSpace, swallowKeyUp {
                swallowKeyUp = false
                chordHeld = false
                return .swallow
            }
            return .pass

        default:
            return .pass
        }
    }

    /// Exact match on the supported modifier subset (SPEC §4.2) — supersets must NOT fire.
    private func modifiersMatchExactly() -> Bool {
        switch trigger {
        case .ctrlSpace:
            return latched.ctrl && !latched.fn && !latched.cmd && !latched.opt && !latched.shift
        case .fnSpace:
            return latched.fn && !latched.ctrl && !latched.cmd && !latched.opt && !latched.shift
        }
    }
}
