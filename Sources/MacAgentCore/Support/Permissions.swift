import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionState: Equatable, Sendable {
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    /// Remote Desktop uses the same TCC service as Screen Recording on macOS (kTCCServiceScreenCapture).
    /// It appears as a separate entry in System Settings > Privacy & Security on macOS 14+ when an app
    /// uses ScreenCaptureKit. Granting Screen Recording typically covers both, but both must show as
    /// allowed in System Settings for the agent to capture and interact with windows reliably.
    public let remoteDesktopGranted: Bool

    public init(accessibilityGranted: Bool, screenRecordingGranted: Bool, remoteDesktopGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.remoteDesktopGranted = remoteDesktopGranted
    }

    /// Backward-compat alias used by legacy call sites.
    public var screenCaptureGranted: Bool { screenRecordingGranted }

    /// True when the minimum required permission for running tasks is granted.
    /// Accessibility is the hard gate; screen capture enables vision-fallback OCR.
    /// The UI uses this to enable the Send button.
    public var allGranted: Bool {
        accessibilityGranted
    }

    /// True only when all three permissions are fully granted.
    public var fullyGranted: Bool {
        accessibilityGranted && screenRecordingGranted && remoteDesktopGranted
    }
}

public enum Permissions {
    // MARK: - System Settings deep-link URLs
    // macOS 13 (Ventura)+ uses com.apple.settings.PrivacySecurity.extension.
    // Earlier macOS used com.apple.preference.security. Both URL forms are tried
    // so the open call never silently fails if Apple renames the extension again.

    private static let privacyBaseURLs: [String] = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        "x-apple.systempreferences:com.apple.preference.security",
    ]

    // MARK: - Checking

    public static func current(promptIfNeeded: Bool) -> PermissionState {
        let options = ["AXTrustedCheckOptionPrompt": promptIfNeeded] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        // Screen Recording and Remote Desktop share the kTCCServiceScreenCapture TCC service.
        // CGPreflightScreenCaptureAccess() returns true when the user has granted access;
        // both "Screen Recording" and "Remote Desktop" entries in System Settings reflect this value.
        let captureGranted = CGPreflightScreenCaptureAccess()
        return PermissionState(
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: captureGranted,
            remoteDesktopGranted: captureGranted
        )
    }

    // MARK: - Requesting

    @MainActor
    public static func requestMissingPermissions() async -> PermissionState {
        // Accessibility — the system dialog fires when promptIfNeeded is true.
        let state = current(promptIfNeeded: true)

        if !state.screenRecordingGranted {
            // Trigger the system prompt. If it was previously denied the system shows
            // nothing — open System Settings directly so the user can flip the toggle.
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                openPrivacyPane("Privacy_ScreenCapture")
            }
        }

        return current(promptIfNeeded: true)
    }

    /// Request Accessibility: fires the system prompt AND opens System Settings directly.
    /// On macOS 14+ the prompt no longer shows a dialog — it just adds the app to the
    /// System Settings list. Opening the pane explicitly ensures the user sees it.
    @MainActor
    public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // Always open the pane so the user can see the toggle / add the app manually.
        // Apps not in /Applications may not appear automatically — the user taps + to browse.
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Open System Settings to the Accessibility pane.
    @MainActor
    public static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Open System Settings to the Screen Recording pane (covers Remote Desktop too).
    @MainActor
    public static func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    /// Try each known base URL in order; use NSWorkspace's return value to detect
    /// whether the OS accepted the URL before trying the next candidate.
    @MainActor
    private static func openPrivacyPane(_ pane: String) {
        for base in privacyBaseURLs {
            guard let url = URL(string: "\(base)?\(pane)") else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        // Last resort: open top-level Privacy & Security without a deep-link anchor.
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
