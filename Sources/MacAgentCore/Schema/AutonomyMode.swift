import Foundation

public enum AutonomyMode: String, Codable, CaseIterable, Sendable {
    case confirmEveryAction
    case semiAutonomous
    case autonomous
    /// Watch mode — the agent perceives, plans, and proposes each action in the HUD,
    /// but never executes. Use this to preview what the agent would do before unleashing it.
    case readOnly

    public var displayName: String {
        switch self {
        case .confirmEveryAction: return "Before Every Action"
        case .semiAutonomous: return "Semi-Autonomous"
        case .autonomous: return "Autonomous"
        case .readOnly: return "Watch Only"
        }
    }

    public var shortLabel: String {
        switch self {
        case .confirmEveryAction: return "Manual"
        case .semiAutonomous: return "Semi"
        case .autonomous: return "Auto"
        case .readOnly: return "Watch"
        }
    }

    public var explanation: String {
        switch self {
        case .confirmEveryAction:
            return "Pause before every action so you can review each step."
        case .semiAutonomous:
            return "Allow safe actions automatically and stop for risky or visible changes."
        case .autonomous:
            return "Allow the agent to continue on safe paths with minimal interruption."
        case .readOnly:
            return "See every proposed action in the HUD without executing anything. Safe observation mode."
        }
    }

    public func adjustedTier(for action: AgentAction, baseTier: SafetyTier) -> SafetyTier {
        switch self {
        case .confirmEveryAction:
            switch action.type {
            case .complete, .clarify, .wait, .say:
                return baseTier
            default:
                return baseTier == .confirm ? .confirm : .preview
            }
        case .semiAutonomous:
            return baseTier
        case .autonomous:
            switch baseTier {
            case .confirm:
                return .confirm
            case .preview:
                // menuSelect navigates visible system menus — always keep at .preview
                // even in autonomous mode so the user can see which menu path was chosen.
                if action.type == .menuSelect { return .preview }
                // Unit 35 — clipboard reads stay .preview even in autonomous
                // mode: the content leaves the machine (sent to the model),
                // a privacy boundary autonomy must not widen silently.
                if action.type == .readClipboard { return .preview }
                // Risky/unknown keyboard chords (SafetyPolicy.isRiskyKeyCombo +
                // the Unit 38 non-benign-keyCombo floor) and dangerous long
                // modifier holds (isDangerousHeldKey) land at .preview
                // SPECIFICALLY so the operator sees the chord before it fires:
                // lock screen (cmd+ctrl+q), force-quit (cmd+option+escape),
                // screenshot (cmd+shift+3/4), app quit/close (cmd+q/cmd+w).
                // Benign combos and short holds already classify at .auto and
                // never reach this .preview branch, so autonomous mode must not
                // blanket-widen the genuinely risky ones back to .auto.
                if action.type == .keyCombo || action.type == .holdKey {
                    return .preview
                }
                // Mirror SafetyPolicy.classify's coord-only floor (lines 26-29) AND the
                // typeText sensitivity guard (isSensitiveTarget requires idx >= 0): a CU
                // pixel click or blind typeText without a resolved AX index has no label
                // to introspect, so destructive / sensitive / commercial checks return
                // false and the SafetyPolicy floor lands at .preview. Autonomous mode
                // must NOT widen that — a pixel click on "Delete" or a blind type into
                // a password field would otherwise auto-fire silently.
                if action.targetIndex == nil,
                   action.type == .click || action.type == .doubleClick
                       || action.type == .tripleClick || action.type == .rightClick
                       || action.type == .typeText {
                    return .preview
                }
                // Auto-approve all other preview actions — confidence gating caused CU
                // pixel-coord clicks (which always have sub-0.85 AX confidence) to stall
                // indefinitely waiting for overlay approval.
                return .auto
            case .auto:
                return .auto
            }
        case .readOnly:
            // All non-terminal actions surface in the HUD so the user can see the plan.
            // 33a — say joins the exemption: speech is not an OS action and
            // gating it parked a preview gate per narration (CU text-only
            // fallback maps narration to say since Unit 33).
            switch action.type {
            case .complete, .clarify, .wait, .say: return baseTier
            default: return .preview
            }
        }
    }
}
