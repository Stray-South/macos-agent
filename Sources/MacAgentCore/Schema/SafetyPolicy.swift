import Foundation

public enum SafetyTier: String, Codable, Sendable, Comparable {
    case auto
    case preview
    case confirm

    /// Unit 23 — total ordering: `auto < preview < confirm`. Enables
    /// `max(tierA, tierB)` semantics for tier-floor composition (e.g.
    /// when the LLM task classifier returns RISKY and the orchestrator
    /// must raise the per-step tier to at least `.preview`). The
    /// ordering matches the safety-escalation direction: a higher
    /// tier requires more operator approval.
    private var rank: Int {
        switch self {
        case .auto: return 0
        case .preview: return 1
        case .confirm: return 2
        }
    }

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct SafetyPolicy: Sendable {
    public init() {}

    public static func classify(_ action: AgentAction, snapshot: PerceptionSnapshot) -> SafetyTier {
        // Unit 36 — workspace file writes ALWAYS confirm, unconditionally and
        // first: the agent acts off-screen on disk, so the operator sees path
        // + content on the card before any byte is written. Placed at the top
        // so the `requiresConfirmation → .preview` rule (and any other branch)
        // can never demote a disk write below confirm.
        if action.type == .writeFile { return .confirm }
        if action.confidence < 0.6 { return .confirm }
        // A negative targetIndex escapes the bounds-checked destructive/sensitive helpers
        // below (each guards `idx >= 0`), which would let a hallucinated -1 pointing at a
        // "Delete" element write a receipt with `approved: true, tier: auto`. Force confirm
        // uniformly; Executor.resolveTarget still throws missingTarget regardless.
        if let idx = action.targetIndex, idx < 0 { return .confirm }
        // Coordinate-only clicks (CU pipeline, vision-only apps): the destructive,
        // sensitive, and commercial checks all guard `idx >= 0` and return false when
        // targetIndex is nil — falling through to .auto would let a click on a "Delete"
        // pixel auto-execute. We can't introspect labels from a coordinate, so the only
        // safe floor is .preview: user sees the action card before it fires.
        // NOTE (ordering): .preview is the floor only for a coord click that is
        // PLAUSIBLY on-target. A click FAR from any AX element resolves to
        // confidence 0.45 in ComputerUseClient.nearestElement (the >200pt bucket,
        // which also nils targetIndex), so the `confidence < 0.6 -> .confirm` rule
        // above ALREADY escalated it to .confirm before reaching here — the model
        // clicking into the void gets the strongest gate, not .preview. Confirmed
        // live 2026-06-16: a CU left_click far from any element classified CONFIRM.
        // scroll with nil targetIndex falls through to .auto — scroll is positional
        // navigation, not destructive-label-gated, so the floor doesn't apply.
        if action.targetIndex == nil,
           action.type == .click || action.type == .doubleClick || action.type == .tripleClick || action.type == .rightClick {
            return .preview
        }
        // menuSelect: LLM encodes the menu path in action.text (e.g. "File > Move to Trash"),
        // typically with targetIndex: nil. isDestructive() guard-exits on nil, so destructive
        // keywords in the text are never seen. Check text directly before the element-index path.
        if action.type == .menuSelect,
           let text = action.text?.lowercased(),
           destructiveKeywords.contains(where: { text.contains($0) })
               || wholeWordDestructiveKeywords.contains(where: { containsWholeWord($0, in: text) }) {
            return .confirm
        }
        if isDestructive(action, snapshot: snapshot) { return .confirm }
        if isSensitiveTarget(action, snapshot: snapshot) { return .confirm }
        if isCommercialAction(action, snapshot: snapshot) { return .confirm }
        if isDangerousKeyCombo(action) { return .confirm }
        if isRiskyKeyCombo(action) { return .preview }
        // Long-held modifier keys (shift, cmd, ctrl, alt, option) can trigger
        // system-level features (Sticky Keys popup after ~5s shift, modal
        // shortcuts when an unintended app has focus). Surface as .preview.
        // Short non-modifier holds (≤1s) are safe — the keyCombo-style fallthrough
        // at the end of classify() classifies those at .auto.
        if isDangerousHeldKey(action) { return .preview }
        // click/doubleClick intentionally excluded: cursor positioning and text selection in a
        // terminal cannot inject or execute commands. typeText (injection) and keyCombo (execution)
        // cover the dangerous paths.
        if isShellContext(snapshot),
           action.type == .typeText || action.type == .keyCombo || action.type == .holdKey {
            return .confirm
        }
        if action.type == .typeText, let text = action.text, isDangerousText(text) { return .confirm }
        if action.type == .typeText { return .preview }
        if action.type == .menuSelect { return .preview }
        if action.requiresConfirmation { return .preview }
        // Switching apps is visible and potentially disruptive — require preview confirmation.
        if action.type == .switchApp { return .preview }
        // Drag operations (text selection, slider drag, drag-and-drop) can have
        // visible side effects beyond a single click — surface as .preview so
        // the user sees the start→end span before execution.
        if action.type == .drag { return .preview }
        // Undo only reverts the agent's own last action — always safe, no confirmation needed.
        // Unit 35 — clipboard reads floor at .preview: the content is sent
        // to the model API, so the operator sees the card before it fires.
        if action.type == .readClipboard { return .preview }
        if action.type == .undo { return .auto }
        // .holdKey short non-modifier holds are auto-safe (caught by the
        // isDangerousHeldKey check above when they're risky).
        if action.type == .holdKey { return .auto }
        // Unit 13a — stateful mouse classification floor. These actions
        // hold OS-level mouse-button state across executor calls (13b
        // wires the live machine). Floor at .preview so the operator
        // sees every press/release/move during a held-down session in
        // semi-autonomous and confirm modes. Autonomous mode promotes
        // to .auto via AutonomyMode.adjustedTier. The held-mouse
        // invariant (block most non-mouse actions while a button is
        // down) ships in 13b alongside the state machine.
        if action.type == .mouseDown || action.type == .mouseUp || action.type == .mouseMove {
            return .preview
        }
        // Unit 38 — unknown-keyCombo floor. Previously any keyCombo not in
        // the dangerous/risky lists fell through to .auto, so an unrecognized
        // chord auto-fired: cmd+ctrl+q (lock screen), cmd+shift+3/4
        // (screenshot), cmd+ctrl+space (emoji), fn-layer system combos, and
        // app-specific destructive shortcuts the lists don't know about. Now
        // only an explicit benign allowlist (navigation + ubiquitous text
        // editing) stays .auto; every other combo floors to .preview so the
        // operator sees the unrecognized chord before it fires.
        if action.type == .keyCombo {
            return isBenignKeyCombo(action) ? .auto : .preview
        }
        return .auto
    }

    // Shell-specific patterns for typeText content inspection. Separate from
    // destructiveKeywords (which guards element labels) — these are command-syntax
    // patterns, not UI strings. Checked before the generic typeText → .preview fallback.
    private static let dangerousTextPatterns = [
        "rm -r",       // recursive delete (rm -rf, rm -rfd, etc.)
        "rm -f",       // force delete without -r
        "sudo ",       // privilege escalation (trailing space avoids "pseudocode" false positive)
        "shutdown",    // system shutdown
        "reboot",      // system reboot
        "halt",        // system halt
        "poweroff",    // system power off
        "mkfs",        // filesystem format
        "dd if=",      // raw disk write
        "(){ :|",      // fork bomb signature (matches :(){ :|:& };: and : (){ :|:& };:)
        "> /dev/",     // redirect to device node
        "curl ",       // network fetch (commonly piped to a shell); trailing space avoids "curly"
        "wget ",       // network fetch
        "bash -c",     // inline shell execution
        "python -c",   // inline Python execution
        "python3 -c",  // inline Python execution
        "perl -e",     // inline Perl execution
        // Deliberately NOT "nc " (netcat): it is a substring of common code
        // tokens — "func ", "sync ", "async " — and would mis-confirm benign
        // typeText. Reverse shells via nc still surface as .preview.
        // Accepted tradeoff: these fire on ANY typeText (like rm/sudo above), so
        // benign prose mentioning "curl"/"wget" gets an extra .confirm. That is
        // the safe direction — a network-fetch-then-exec payload must not slip to
        // .preview (and autonomous-widen to .auto) just because the focused app
        // is not a recognized shell bundle (web-SSH terminals, scripting IDEs).
    ]

    private static func isDangerousText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return dangerousTextPatterns.contains(where: lower.contains)
    }

    /// Returns true when `word` appears in `text` as a whole word —
    /// not embedded within a longer word (e.g. "send" in "resend" or "send2").
    /// Word-boundary predicate: letters and digits count as word-continuation characters.
    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: word, options: .caseInsensitive, range: searchRange) {
            let before = range.lowerBound == text.startIndex
                || (!text[text.index(before: range.lowerBound)].isLetter
                    && !text[text.index(before: range.lowerBound)].isNumber)
            let after = range.upperBound == text.endIndex
                || (!text[range.upperBound].isLetter
                    && !text[range.upperBound].isNumber)
            if before && after { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    // Authoritative list — keep in sync with MANIFEST.md §Safety Model.
    // internal so @testable tests can verify parity without driving classify().
    internal static let destructiveKeywords = [
        "clear", "delete", "destroy", "disable", "discard", "empty", "erase", "format",
        "overwrite", "purge", "remove", "reset", "revoke", "sign out", "terminate",
        "trash", "uninstall", "wipe",
    ]

    // Keywords that require whole-word matching to avoid substring false positives.
    // "send" as substring matches "Resend" and "Unsend" — both reversible, low-harm.
    // Checked separately in isDestructive() and the menuSelect text scan.
    internal static let wholeWordDestructiveKeywords: Set<String> = ["send"]

    // Keywords that identify sensitive input fields where typeText must always be .confirm.
    // Covers credential, 2FA, and payment fields. Separate from destructiveKeywords —
    // these gate data entry, not irreversible actions.
    // internal so @testable tests can verify parity.
    internal static let sensitiveTargetLabels = [
        // Password fields
        "password",
        // 2FA / OTP fields — multi-char/phrase entries (substring match is safe)
        "one-time code", "verification code", "6-digit code",
        "two-factor", "authenticator", "auth code", "security code",
        // Payment card fields — multi-char/phrase entries
        "card number", "expiry", "credit card",
    ]

    // Short abbreviations requiring whole-word match to avoid false positives.
    // "2fa", "cvv", "cvc", "otp" are ≤3-char tokens — substring match risks collisions
    // with unrelated UI labels. Checked separately via containsWholeWord().
    internal static let wholeWordSensitiveLabels: Set<String> = ["2fa", "cvv", "cvc", "otp"]

    // Multi-word phrases identifying commercial transaction buttons. Scoped to
    // click/doubleClick only — avoids short-word false positives from "buy", "order", etc.
    // internal so @testable tests can verify parity.
    internal static let commercialActionKeywords = [
        "place order", "buy now", "confirm purchase", "complete transaction",
        "checkout", "pay now", "submit order",
    ]

    // Bundle IDs of terminal emulators and shells. typeText and keyCombo in these contexts
    // always require .confirm — shell has full system access.
    // VSCode is intentionally excluded: its bundle ID cannot distinguish the editor pane
    // from the integrated terminal. isDangerousText() still gates destructive command content.
    // internal for testability.
    internal static let shellBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "io.alacritty.Alacritty",
    ]

    private static func isDestructive(_ action: AgentAction, snapshot: PerceptionSnapshot) -> Bool {
        guard let idx = action.targetIndex, idx >= 0 else { return false }

        if idx < snapshot.visionIndexOffset {
            // AX path — check element label.
            // Logically implied by idx < visionIndexOffset (= min(elements.count, 80)),
            // but retained as an explicit in-bounds assertion.
            guard idx < snapshot.elements.count else { return false }
            let el = snapshot.elements[idx]
            let label = el.label.lowercased()
            if destructiveKeywords.contains(where: label.contains)
                || wholeWordDestructiveKeywords.contains(where: { containsWholeWord($0, in: label) }) {
                return true
            }
            // D.2 fix: also inspect element.value for typeText actions only.
            // Scoped to typeText — clipboard injection is a typeText concern. Checking value
            // on click/doubleClick would false-positive on benign elements whose live value
            // (e.g. a search field containing "delete old emails") includes a keyword.
            if action.type == .typeText, let rawValue = el.value {
                let val = rawValue.lowercased()
                return destructiveKeywords.contains(where: val.contains)
                    || wholeWordDestructiveKeywords.contains(where: { containsWholeWord($0, in: val) })
            }
            return false
        } else {
            // Vision path — check OCR observation text.
            // Guard defends against a stale or LLM-hallucinated index past the end of visionObservations.
            let visionIdx = idx - snapshot.visionIndexOffset
            guard visionIdx < snapshot.visionObservations.count else { return false }
            let text = snapshot.visionObservations[visionIdx].text.lowercased()
            return destructiveKeywords.contains(where: text.contains)
                || wholeWordDestructiveKeywords.contains(where: { containsWholeWord($0, in: text) })
        }
    }

    /// Returns true when typeText targets a field that must never be auto-typed:
    /// AXSecureTextField (password fields from the OS), or fields whose label or OCR
    /// text contains a sensitive keyword (2FA codes, credit card fields, etc.).
    private static func isSensitiveTarget(_ action: AgentAction, snapshot: PerceptionSnapshot) -> Bool {
        guard action.type == .typeText,
              let idx = action.targetIndex, idx >= 0 else { return false }

        if idx < snapshot.visionIndexOffset {
            // AX path — role check first (OS-guaranteed), then label keyword fallback.
            guard idx < snapshot.elements.count else { return false }
            let el = snapshot.elements[idx]
            if el.role == "AXSecureTextField" { return true }
            let label = el.label.lowercased()
            return sensitiveTargetLabels.contains(where: label.contains)
                || wholeWordSensitiveLabels.contains(where: { containsWholeWord($0, in: label) })
        } else {
            // Vision path — OCR text keyword match only (no role available).
            let visionIdx = idx - snapshot.visionIndexOffset
            guard visionIdx < snapshot.visionObservations.count else { return false }
            let text = snapshot.visionObservations[visionIdx].text.lowercased()
            return sensitiveTargetLabels.contains(where: text.contains)
                || wholeWordSensitiveLabels.contains(where: { containsWholeWord($0, in: text) })
        }
    }

    /// Returns true when clicking a button whose label identifies a commercial transaction.
    private static func isCommercialAction(_ action: AgentAction, snapshot: PerceptionSnapshot) -> Bool {
        guard action.type == .click || action.type == .doubleClick || action.type == .tripleClick,
              let idx = action.targetIndex, idx >= 0 else { return false }

        if idx < snapshot.visionIndexOffset {
            guard idx < snapshot.elements.count else { return false }
            let label = snapshot.elements[idx].label.lowercased()
            return commercialActionKeywords.contains(where: { label.contains($0) })
        } else {
            let visionIdx = idx - snapshot.visionIndexOffset
            guard visionIdx < snapshot.visionObservations.count else { return false }
            let text = snapshot.visionObservations[visionIdx].text.lowercased()
            return commercialActionKeywords.contains(where: { text.contains($0) })
        }
    }

    /// Returns true when the frontmost app is a terminal emulator or shell environment.
    private static func isShellContext(_ snapshot: PerceptionSnapshot) -> Bool {
        shellBundleIDs.contains(snapshot.focusedAppBundleID)
    }

    /// Key combos that are irreversible or destructive — always require confirmation.
    private static func isDangerousKeyCombo(_ action: AgentAction) -> Bool {
        guard action.type == .keyCombo, let combo = action.text?.lowercased() else { return false }
        let destructive = [
            "cmd+delete",           // Move to Trash (Finder)
            "cmd+shift+delete",     // Empty Trash (with dialog)
            "cmd+shift+option+delete", // Empty Trash (no dialog)
            "ctrl+delete",
        ]
        return destructive.contains(where: combo.contains)
    }

    /// Key combos that close or quit the app — require at least preview.
    private static func isRiskyKeyCombo(_ action: AgentAction) -> Bool {
        guard action.type == .keyCombo, let combo = action.text?.lowercased() else { return false }
        let risky = ["cmd+q", "cmd+w", "cmd+option+w", "cmd+option+escape"]
        return risky.contains(combo)
    }

    /// Unit 38 — combos safe enough to auto-fire in any context: bare
    /// navigation/whitespace keys and the ubiquitous text-editing chords.
    /// Anything NOT on this list floors to .preview (the safe default for an
    /// unrecognized chord — see classify()). A combo is benign only if EVERY
    /// token matches: "cmd+c return" is benign, "cmd+c cmd+ctrl+q" is not.
    /// Editing chords that mutate (cmd+x cut, cmd+z undo) are included because
    /// they are reversible/in-document and the agent has a dedicated `.undo`;
    /// destructive/quit/system chords are already caught above OR fall to the
    /// preview floor.
    private static let benignKeyTokens: Set<String> = [
        // Bare keys — navigation + whitespace + submit/cancel.
        "return", "enter", "tab", "escape", "esc", "space",
        "up", "down", "left", "right",
        "home", "end", "pageup", "pagedown", "delete", "backspace",
        // Ubiquitous, reversible text editing (cmd-modified single letters).
        "cmd+c", "cmd+v", "cmd+x", "cmd+a", "cmd+z", "cmd+shift+z",
        "cmd+f", "cmd+g", "cmd+shift+g", "cmd+l",
        "shift+tab",
    ]

    private static func isBenignKeyCombo(_ action: AgentAction) -> Bool {
        guard action.type == .keyCombo,
              let combo = action.text?.lowercased().trimmingCharacters(in: .whitespaces),
              !combo.isEmpty else { return false }
        // text may carry several space-separated presses (e.g. "cmd+l return").
        // Benign only if EVERY press is on the allowlist.
        let presses = combo.split(separator: " ").map(String.init)
        return presses.allSatisfy { benignKeyTokens.contains($0) }
    }

    /// Risky `.holdKey` actions — modifier keys (shift, cmd, ctrl, alt, option,
    /// fn) held for ≥1 second. Threshold matches macOS's Sticky Keys default
    /// (~5s for shift) with a conservative 1s cap because focus on the wrong
    /// app during a long held modifier produces visible unintended state
    /// (auto-scroll, auto-select). Short non-modifier holds are `.auto`-safe.
    private static let modifierKeyTokens: Set<String> = [
        "shift", "cmd", "command", "ctrl", "control",
        "alt", "option", "fn",
    ]
    private static func isDangerousHeldKey(_ action: AgentAction) -> Bool {
        guard action.type == .holdKey,
              let combo = action.text?.lowercased(),
              let durationMs = action.durationMs,
              durationMs >= 1000 else {
            return false
        }
        // The combo string can be "shift", "cmd+shift" (modifier-prefixed), or
        // "a"/"return"/etc. Any token being a modifier triggers the floor.
        for token in combo.split(separator: "+").map(String.init) {
            if modifierKeyTokens.contains(token) { return true }
        }
        return false
    }

    // MARK: - Safety floor for capability rules

    /// Returns true when an action falls into a category that no user capability rule can
    /// widen (i.e., an `allow` rule must not auto-approve these). Used by the rule evaluator
    /// in Orchestrator to prevent rules from bypassing the safety floor.
    ///
    /// Covers: destructive element labels, sensitive input targets, commercial transaction
    /// buttons, dangerous key combos, long-held modifier keys, drag, and
    /// shell-context typeText/keyCombo/holdKey.
    public static func isDestructiveOrSensitive(
        _ action: AgentAction,
        snapshot: PerceptionSnapshot
    ) -> Bool {
        // Coordinate-only clicks AND typeText: floor-bound against capability-
        // rule widening. Note the asymmetry vs `classify()`:
        //   - `classify()` lines 26-29 floor coord-only CLICK variants only
        //   - typeText reaches `.preview` via classify()'s generic typeText
        //     fallthrough at line 58 (which applies regardless of targetIndex)
        // The widen-guard predicate must list BOTH to prevent an `allow` rule
        // from auto-promoting either: blind typing into a field that might
        // be a password / 2FA / OTP cannot be label-checked (isSensitiveTarget
        // guards idx >= 0 same as isDestructive), so it stays floor-bound here
        // even though classify routes it through a different path.
        if action.targetIndex == nil,
           action.type == .click || action.type == .doubleClick
               || action.type == .tripleClick || action.type == .rightClick
               || action.type == .typeText {
            return true
        }
        // menuSelect with destructive path text
        if action.type == .menuSelect,
           let text = action.text?.lowercased(),
           destructiveKeywords.contains(where: { text.contains($0) })
               || wholeWordDestructiveKeywords.contains(where: { containsWholeWord($0, in: text) }) {
            return true
        }
        // Drag operations carry visible side effects (text selection, slider
        // manipulation, drag-and-drop). Today `classify()` floors `.drag` at
        // `.preview` and the rule evaluator at Orchestrator.swift:333-345 only
        // widens `.confirm → .preview`, so `.drag` can't reach `.auto` via an
        // `.allow` rule. This entry is defense-in-depth: if the widen guard
        // ever relaxes (e.g. to make "Always allow" truly skip the gate),
        // `.drag` stays floor-bound regardless.
        if action.type == .drag { return true }
        // App switches are intrinsically `.preview` (SafetyPolicy.swift:62) so
        // they can't reach `.auto` via the current widen guard (only widens
        // `.confirm → .preview`). Floor-bind defensively so a future widen-
        // guard relaxation doesn't auto-promote them.
        if action.type == .switchApp { return true }
        // Unit 13a — stateful-mouse defense-in-depth. Mirror the `.drag` and
        // `.switchApp` pattern above: `classify()` floors these at `.preview`
        // and the current widen guard only promotes `.confirm → .preview`,
        // but a future widen-guard relaxation must not auto-promote a held
        // mouse press past `.preview`. The 13b held-mouse invariant adds
        // `.confirm` promotion for cross-cutting actions DURING a held
        // session; this floor-bind guarantees the held-mouse actions
        // themselves stay floor-bound regardless of rule evaluation.
        if action.type == .mouseDown || action.type == .mouseUp || action.type == .mouseMove {
            return true
        }
        // Unit 35a — clipboard reads floor-bound for the same reason: the
        // content leaves the machine for the model API, so an `allow` rule
        // must never let a future widen-guard relaxation auto-fire it past
        // `.preview`. Mirrors the .drag/.switchApp/.mouseDown defense.
        if action.type == .readClipboard { return true }
        // Unit 36 — file writes are confirm-tier; floor-bind so no rule path
        // can ever widen a disk write below confirm.
        if action.type == .writeFile { return true }
        // Unit 38a — unrecognized keyCombos floor at .preview in classify();
        // floor-bind so an `allow` rule can't auto-promote an unknown chord.
        // Benign combos (return, cmd+c, …) classify .auto and never reach
        // here as a floor concern.
        if action.type == .keyCombo, !isBenignKeyCombo(action) { return true }
        return isDestructive(action, snapshot: snapshot)
            || isSensitiveTarget(action, snapshot: snapshot)
            || isCommercialAction(action, snapshot: snapshot)
            || isDangerousKeyCombo(action)
            || isDangerousHeldKey(action)
            || (isShellContext(snapshot)
                && (action.type == .typeText || action.type == .keyCombo || action.type == .holdKey))
    }

    // MARK: - Held-mouse invariant (Unit 13b)

    /// Promotes a classified tier to `.confirm` when a mouse button is
    /// currently held by the agent AND the action is not one of the
    /// hold-compatible types (`.mouseUp`, `.mouseMove`, `.scroll`,
    /// `.wait`, `.complete`). Held-mouse runs (drag-select, rubber-band,
    /// slider grab) are visible OS-level state — every cross-cutting
    /// action during a held session is operator-visible by definition,
    /// so we floor at `.confirm` to surface the cross-cut to the user.
    ///
    /// Never DOWNGRADES — if `classify()` already returned `.confirm`
    /// because the action is destructive/sensitive, the held-mouse path
    /// preserves that. Only promotes `.auto` and `.preview` to `.confirm`
    /// during a held session.
    ///
    /// Called by `Orchestrator.run()` AFTER the capability-rule
    /// evaluator so the held-mouse invariant is the final word — an
    /// `allow` rule cannot widen a cross-cutting action below `.confirm`
    /// while a button is held.
    ///
    /// `heldMouseAtStart` reflects the snapshot taken BEFORE the action
    /// runs: a `.mouseDown` that starts the hold sees `false`; the
    /// subsequent `.mouseUp`/`.mouseMove`/cross-cuts during the hold
    /// see `true`. The same snapshot is recorded on the receipt for
    /// post-hoc audit.
    public static func heldMouseAdjusted(
        tier: SafetyTier,
        action: AgentAction,
        heldMouseAtStart: Bool
    ) -> SafetyTier {
        guard heldMouseAtStart else { return tier }
        switch action.type {
        case .mouseUp, .mouseMove, .scroll, .wait, .complete, .say:
            return tier
        default:
            // Promote only — never downgrade. `.confirm` stays `.confirm`,
            // `.auto`/`.preview` become `.confirm`.
            return .confirm
        }
    }
}
