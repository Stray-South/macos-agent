import Foundation

/// H1 — pure outcome-verification verdict for one executed action.
public struct OutcomeCheck: Equatable, Sendable {
    /// Tri-state. `true` = the action's post-condition was observed to hold;
    /// `false` = it was checked and did NOT hold (likely a no-op); `nil` = not
    /// checkable (unverifiable action type, AX-blind screen).
    public let verified: Bool?
    public let detail: String

    public init(verified: Bool?, detail: String) {
        self.verified = verified
        self.detail = detail
    }

    static func unknown(_ detail: String) -> OutcomeCheck { OutcomeCheck(verified: nil, detail: detail) }
    static func pass(_ detail: String) -> OutcomeCheck { OutcomeCheck(verified: true, detail: detail) }
    static func fail(_ detail: String) -> OutcomeCheck { OutcomeCheck(verified: false, detail: detail) }
}

/// H1 — closed-loop outcome verification. Pure function (no display, no I/O):
/// given the action and the pre/post perception snapshots, decide whether the
/// action achieved its intended post-condition. Conservative by design — it
/// only asserts `false` when confident and returns `nil` (unknown) whenever the
/// signal is unreliable, so a false alarm never outranks honest silence.
/// Diagnostic only; nothing here gates an action.
///
/// Known limitations (acceptable for a v0 instrument, documented so the report
/// is read honestly): the post snapshot is AX-only (no Vision), the re-capture
/// is immediate so a slow-to-repaint UI can read as "no change", and structural
/// element equality treats benign churn (a ticking clock label) as a change.
/// All three err toward over-reporting success, not toward false failures.
public enum OutcomeVerifier {
    /// Action types whose post-condition this verifier can reason about. The
    /// orchestrator only re-perceives for these; everything else stays `nil`.
    public static func isVerifiable(_ type: ActionType) -> Bool {
        switch type {
        case .click, .doubleClick, .rightClick, .tripleClick,
             .menuSelect, .scroll, .typeText, .switchApp:
            return true
        default:
            return false
        }
    }

    public static func verify(action: AgentAction,
                              pre: PerceptionSnapshot,
                              post: PerceptionSnapshot) -> OutcomeCheck {
        switch action.type {
        case .switchApp:
            guard let target = action.text, !target.isEmpty else {
                return .unknown("switchApp had no target bundle id to verify against")
            }
            // Bundle IDs compared case-insensitively, matching the
            // switchApp-loop detector's normalization (Orchestrator H.6).
            return post.focusedAppBundleID.lowercased() == target.lowercased()
                ? .pass("frontmost app is now \(target)")
                : .fail("frontmost app is \(post.focusedAppBundleID), expected \(target)")

        case .typeText:
            guard let typed = action.text, !typed.isEmpty else {
                return .unknown("typeText had no text to verify")
            }
            // Compared in-process against live AX values BEFORE the receipt's
            // text is redacted; the detail never echoes the typed content.
            let needle = String(typed.prefix(40))
            if post.elements.contains(where: { ($0.value ?? "").contains(needle) }) {
                return .pass("typed text is present in a field after the action")
            }
            // Masked fields (passwords) and values not surfaced via AX can't be
            // confirmed — report unknown rather than a false failure.
            return .unknown("typed text not found in any visible field value (may be masked or not exposed via accessibility)")

        case .click, .doubleClick, .rightClick, .tripleClick, .menuSelect, .scroll:
            // AX-blind on either side: an empty element list means the screen is
            // unreadable via accessibility, so "no change" carries no signal.
            if pre.elements.isEmpty || post.elements.isEmpty {
                return .unknown("AX-blind screen; cannot tell whether \(action.type.rawValue) changed anything")
            }
            let changed = post.focusedAppBundleID != pre.focusedAppBundleID
                || post.elements != pre.elements
            return changed
                ? .pass("the screen changed after \(action.type.rawValue)")
                : .fail("no perceptible accessibility change after \(action.type.rawValue) (possible no-op)")

        default:
            return .unknown("\(action.type.rawValue) has no verifiable post-condition")
        }
    }
}
