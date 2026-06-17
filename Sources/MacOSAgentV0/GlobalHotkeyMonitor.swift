import AppKit

/// Unit 28 — voice-reachable global hotkeys for Approve / Reject / Abort.
///
/// A hands-free operator drives a target app by voice; the agent runs in
/// the background. Without a global hotkey, the only approval surface is
/// the in-window card (requires "Switch to macOS Agent", which steals
/// focus) or the HUD's `canBecomeKey == false` panel (no keyboard path at
/// all). Both are slow and fragile under Voice Control. A global hotkey
/// turns every gate into a one-utterance "Press F13" from any app, and —
/// critically — gives a focus-independent emergency brake (the Abort key)
/// that a force-quit cannot match (force-quit skips the executor's
/// held-input release).
///
/// Mechanism: `NSEvent.addGlobalMonitorForEvents` (fires when ANOTHER app
/// is frontmost) PLUS `addLocalMonitor` (fires when the agent itself is
/// frontmost) so the keys work in both states. Global monitors require the
/// Accessibility grant the agent already holds. Both are non-consuming —
/// the keystroke also reaches the focused app — which is why the defaults
/// are F13–F15: function keys almost no app claims, so the passthrough is
/// harmless. No Carbon `RegisterEventHotKey`, no external dependency
/// (Package.swift stays empty per the project hard rule).
enum HotkeyIntent: Equatable {
    case approve
    case reject
    case abort
}

@MainActor
final class GlobalHotkeyMonitor {
    /// macOS virtual key codes (kVK_F13/F14/F15 from Carbon/HIToolbox).
    /// Stable constants; named here so the mapping is the single source of
    /// truth and is unit-testable without an event tap.
    private enum KeyCode {
        static let f13: UInt16 = 105
        static let f14: UInt16 = 107
        static let f15: UInt16 = 113
    }

    /// Pure decode — the only logic worth unit-testing (monitor install
    /// itself needs a real HID tap). F13 → approve, F14 → reject,
    /// F15 → abort; everything else nil. `nonisolated` because it touches
    /// no actor state and is called both from the (non-isolated) NSEvent
    /// monitor closures and from synchronous tests.
    nonisolated static func intent(forKeyCode keyCode: UInt16) -> HotkeyIntent? {
        switch keyCode {
        case KeyCode.f13: return .approve
        case KeyCode.f14: return .reject
        case KeyCode.f15: return .abort
        default: return nil
        }
    }

    /// Human-readable bindings for the Settings display. Order matches
    /// the gate-decision severity (approve / reject / abort). `nonisolated`
    /// immutable data — readable from the SwiftUI view body and tests
    /// without an actor hop.
    nonisolated static let bindingDescriptions: [(intent: String, key: String)] = [
        ("Approve", "F13"),
        ("Reject", "F14"),
        ("Abort", "F15"),
    ]

    private var globalToken: Any?
    private var localToken: Any?

    /// True iff the cross-app global monitor is currently installed. The
    /// global monitor is the focus-independent brake (fires while another
    /// app is frontmost); it requires the Accessibility TCC grant. The
    /// local monitor (agent-frontmost only) does NOT. When this is false,
    /// only the agent-frontmost path is armed — the caller (AppModel) must
    /// re-arm via `start(includeGlobal: true, …)` once the grant lands, or
    /// the emergency Abort key is silently dead for the cross-app case.
    private(set) var globalActive: Bool = false

    /// Install the local key-down monitor always, and the global monitor
    /// only when `includeGlobal` is true. `handler` runs on the main actor
    /// (NSEvent delivers monitor callbacks on the main thread). Idempotent:
    /// a second `start` tears down the prior monitors first so we never
    /// leak a tap.
    ///
    /// `includeGlobal` MUST track `permissions.accessibilityGranted`:
    /// `addGlobalMonitorForEvents` returns a non-nil token even when the
    /// grant is absent — it just never fires — so installing it ungated
    /// gives a false sense of an armed brake. AppModel gates the install
    /// and re-arms on the grant's false→true transition.
    func start(includeGlobal: Bool, handler: @escaping @MainActor (HotkeyIntent) -> Void) {
        stop()
        if includeGlobal {
            globalToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if let intent = Self.intent(forKeyCode: event.keyCode) {
                    // Global monitor callbacks are delivered on the main
                    // thread, but the closure isn't statically @MainActor;
                    // hop explicitly so the @MainActor handler is called in
                    // isolation.
                    MainActor.assumeIsolated { handler(intent) }
                }
            }
            globalActive = (globalToken != nil)
        }
        // Local monitor must RETURN the event (nil would swallow it). We
        // never swallow — the function keys pass through to the agent's own
        // UI harmlessly, and swallowing could hide a keystroke the user
        // meant for a focused field.
        localToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let intent = Self.intent(forKeyCode: event.keyCode) {
                MainActor.assumeIsolated { handler(intent) }
            }
            return event
        }
    }

    /// Tear down both monitors. Idempotent. Called by AppModel when the
    /// monitor is replaced; the process-exit teardown handles the
    /// app-lifetime case (NSEvent monitors are released automatically when
    /// the process terminates, so there is no deinit cleanup — Swift 6
    /// forbids touching the non-Sendable tokens from a nonisolated deinit,
    /// and the OS teardown makes it unnecessary).
    func stop() {
        if let globalToken {
            NSEvent.removeMonitor(globalToken)
            self.globalToken = nil
        }
        if let localToken {
            NSEvent.removeMonitor(localToken)
            self.localToken = nil
        }
        globalActive = false
    }
}
