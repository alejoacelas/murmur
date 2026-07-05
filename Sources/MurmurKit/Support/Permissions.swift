import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The three TCC grants, gated by feature (SPEC §8.6): file-transcribe needs none, recording
/// needs Microphone, insertion needs Accessibility, the hotkey tap needs Input Monitoring.
public struct PermissionsStatus: Sendable, Codable, Equatable {
    public var microphone: Bool
    public var inputMonitoring: Bool
    public var accessibility: Bool

    public var allGranted: Bool { microphone && inputMonitoring && accessibility }
}

public enum Permissions {
    public static func current() -> PermissionsStatus {
        PermissionsStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            inputMonitoring: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted())
    }

    /// True when running inside an active Aqua GUI session (event taps/posting need one, S13).
    public static func hasGUISession() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["kCGSSessionOnConsoleKey"] as? Bool) ?? false
    }

    /// True when another process holds Secure Input (blocks taps/paste/typing — SPEC §8.4).
    public static func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}
