import CoreGraphics
import Foundation

/// Unit 13b — process-wide stateful-mouse tracker. The macOS mouse-button
/// state is OS-global: only one left button can be "held" at a time across
/// the entire user session, regardless of how many Orchestrator instances
/// exist in our process. The singleton mirrors that reality.
///
/// Responsibilities:
///   - Track which CGMouseButton (if any) is currently held by the agent.
///   - Remember the last coordinate so the eventual mouseUp posts at the
///     right location (the LLM-emitted mouseUp may carry the same coord
///     as the mouseDown, but the watchdog has no such input — it falls
///     back to whatever the most recent mouseMove or mouseDown set).
///   - Run a 30 s watchdog Task that auto-releases on timeout. Held mouse
///     buttons that fail to release are an OS-level user-lockout risk
///     (the entire desktop becomes drag-selectable, modal dialogs
///     misbehave, …). The watchdog is the last line of defence; the
///     Orchestrator's terminal-event cleanup is the first.
///   - Provide an idempotent `release()` so multiple cleanup paths (the
///     LLM's own `.mouseUp`, the watchdog, the Orchestrator's `defer`,
///     the AppModel `abort()` belt-and-suspenders) can all fire without
///     posting duplicate up-events or crashing.
///
/// Threading: actor isolation serialises all state mutation. `release()`
/// posts a CGEvent from the actor's executor; `CGEvent.post(tap:)` on
/// `.cghidEventTap` is documented thread-safe.
public actor MouseHoldState {
    /// Process-wide singleton. CG mouse-button state is global, so the
    /// tracker must be too. Tests that need a clean slate call
    /// `resetForTesting()` in their setup.
    public static let shared = MouseHoldState()

    private var heldButton: CGMouseButton?
    private var lastCoordinate: CGPoint?
    private var watchdog: Task<Void, Never>?

    public init() {}

    /// True iff a button is currently held.
    public func isHeld() -> Bool { heldButton != nil }

    /// The button currently held, or nil if none. Used by the Executor to
    /// pick `.leftMouseDragged` vs `.rightMouseDragged` for a held-mouse
    /// `.mouseMove`.
    public func currentHeldButton() -> CGMouseButton? { heldButton }

    /// The last coordinate seen by `markHeld` or `updateCoordinate`.
    /// `internal` for test verification only.
    internal func currentCoordinate() -> CGPoint? { lastCoordinate }

    /// Mark a button as held and start the watchdog. The CGEvent for the
    /// down-press must be posted by the caller BEFORE calling this — we
    /// don't post it here so the call site can apply modifier flags and
    /// fail-fast on `CGEvent` allocation without leaving the tracker in
    /// an inconsistent state.
    ///
    /// Calling `markHeld` while another button is already held cancels
    /// the prior watchdog and installs a fresh one. The prior button is
    /// NOT released — the caller is expected to have already done that.
    public func markHeld(
        button: CGMouseButton,
        at coordinate: CGPoint,
        watchdogDuration: Duration = .seconds(30)
    ) {
        heldButton = button
        lastCoordinate = coordinate
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: watchdogDuration)
            // Re-check cancellation after sleep — markHeld() restarted the
            // watchdog OR release() fired it explicitly. Both cancel us.
            guard !Task.isCancelled else { return }
            _ = await self?.release()
        }
    }

    /// Update the tracked coordinate without touching the watchdog. Called
    /// during a held-mouse `.mouseMove` so the watchdog's eventual mouseUp
    /// (if it fires) lands at the most recent cursor position, not the
    /// original press point.
    public func updateCoordinate(_ coord: CGPoint) {
        lastCoordinate = coord
    }

    /// Release whatever button is held. Posts a mouseUp CGEvent at the
    /// last-known coordinate, cancels the watchdog, clears state.
    ///
    /// Idempotent: calling `release()` with nothing held is a no-op that
    /// returns `false`. Multiple terminal-cleanup paths converge here so
    /// the no-op return is the load-bearing safety property.
    ///
    /// Returns `true` iff a button was actually released.
    @discardableResult
    public func release() -> Bool {
        guard let button = heldButton else {
            // Even with nothing held, cancel any stray watchdog Task.
            // Defensive — markHeld always pairs them, but a future code
            // path could leave the watchdog installed without a button.
            watchdog?.cancel()
            watchdog = nil
            return false
        }
        let coord = lastCoordinate ?? .zero
        let upType: CGEventType
        switch button {
        case .right: upType = .rightMouseUp
        case .center: upType = .otherMouseUp
        default:     upType = .leftMouseUp
        }
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: upType,
            mouseCursorPosition: coord,
            mouseButton: button
        ) {
            up.post(tap: .cghidEventTap)
        }
        heldButton = nil
        lastCoordinate = nil
        watchdog?.cancel()
        watchdog = nil
        return true
    }

    /// Reset state without posting any CGEvent. Test-only — production
    /// callers must use `release()` so the OS-side button state stays
    /// consistent with our tracker.
    internal func resetForTesting() {
        heldButton = nil
        lastCoordinate = nil
        watchdog?.cancel()
        watchdog = nil
    }
}
