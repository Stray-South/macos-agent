/// ReceiptReplayFormatterTests.swift
///
/// Unit 16 — pure-function tests for the receipt replay rendering
/// surface. No I/O; all fixtures are synthetic `ActionLogEntry` arrays.
/// Privacy-relevant assertions ride on `--show-text`: typeText
/// `action.text` redaction is the load-bearing default per Path E's
/// runbook.
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - Fixtures

private func entry(
    type: ActionType,
    text: String? = nil,
    targetIndex: Int? = nil,
    approved: Bool = true,
    executionResult: String = "ok",
    tier: String = "auto",
    timestamp: Date = Date(timeIntervalSince1970: 1_779_572_000)
) -> ActionLogEntry {
    ActionLogEntry(
        timestamp: timestamp,
        action: AgentAction(
            type: type,
            targetIndex: targetIndex,
            text: text,
            confidence: 0.9,
            requiresConfirmation: false,
            rationale: "fixture"
        ),
        tier: tier,
        approved: approved,
        executionResult: executionResult,
        durationMs: 1,
        snapshotHash: "hash"
    )
}

// MARK: - format()

@Test
func formatter_typeText_redactedByDefault() {
    let e = entry(type: .typeText, text: "super-secret-password")
    let line = ReceiptReplayFormatter.format(e, showText: false)
    #expect(line.contains("\"***\""),
            "typeText must redact action.text by default — Path E privacy invariant")
    #expect(!line.contains("super-secret-password"),
            "verbatim cleartext must NEVER appear when showText=false")
}

@Test
func formatter_typeText_showsVerbatimWhenOptIn() {
    let e = entry(type: .typeText, text: "hello world")
    let line = ReceiptReplayFormatter.format(e, showText: true)
    #expect(line.contains("\"hello world\""),
            "--show-text opt-in must print typeText payload verbatim")
}

@Test
func formatter_keyCombo_neverRedacted() {
    // Other action types' `text` (key combos, menu paths) carries no
    // privacy risk — never redact, even with showText=false.
    let e = entry(type: .keyCombo, text: "cmd+l")
    let line = ReceiptReplayFormatter.format(e, showText: false)
    #expect(line.contains("\"cmd+l\""),
            "keyCombo text is structural — must NOT be redacted by --show-text=false")
}

@Test
func formatter_menuSelect_neverRedacted() {
    let e = entry(type: .menuSelect, text: "File > New Note")
    let line = ReceiptReplayFormatter.format(e, showText: false)
    #expect(line.contains("File > New Note"))
}

@Test
func formatter_approved_clean_emitsCheckMark() {
    // ✓ — approved AND executed cleanly. The default `ok` executionResult
    // in `entry()` does not start with "error:", so this is the clean path.
    let line = ReceiptReplayFormatter.format(entry(type: .click, approved: true))
    #expect(line.contains("[✓]"))
}

@Test
func formatter_rejected_emitsCrossMark() {
    let line = ReceiptReplayFormatter.format(entry(type: .click, approved: false, executionResult: "rejected"))
    #expect(line.contains("[✗]"))
}

@Test
func formatter_approvedButErrorExecution_emitsWarningMark() {
    // Reviewer-caught Sev-2: previous 2-state design conflated
    // "operator approved" with "executed cleanly". The ⚠ marker
    // distinguishes the "approved but executor threw" case — the
    // exact pattern from 2026-05-23 receipts where the operator
    // hadn't rejected anything but the AX press still failed.
    let line = ReceiptReplayFormatter.format(entry(
        type: .click, approved: true,
        executionResult: "error: The requested target element could not be resolved."
    ))
    #expect(line.contains("[⚠]"),
            "approved + execution-failed must surface a warning glyph distinct from [✓] — operator scanning the output should not read approved-but-errored as success")
    #expect(!line.contains("[✓]"))
}

@Test
func formatter_typeText_redactedWhenShowTextFalse_evenIfApproved() {
    // Defense-in-depth check: privacy redaction is independent of
    // approved/error state. The execution path must not leak text
    // even when execution failed (LLM-emitted "Submit credentials"
    // typeText that the AX press then rejected).
    let e = entry(type: .typeText, text: "leaked-content",
                  approved: true, executionResult: "error: stale")
    let line = ReceiptReplayFormatter.format(e, showText: false)
    #expect(line.contains("\"***\""))
    #expect(!line.contains("leaked-content"))
}

@Test
func formatter_clarify_text_redactedByDefault() {
    // Reviewer-caught Sev-2 #1: `.clarify` is NOT in the always-safe
    // whitelist. Defense-in-depth: any action type whose text isn't
    // structurally constrained (keyCombo / menuSelect / switchApp)
    // must redact by default.
    let e = entry(type: .clarify, text: "user said: my password is hunter2")
    let line = ReceiptReplayFormatter.format(e, showText: false)
    #expect(line.contains("\"***\""),
            ".clarify text must be redacted by default — defense against future schema or LLM behavior putting sensitive content in unexpected action types")
    #expect(!line.contains("hunter2"))
}

@Test
func formatter_textAlwaysSafe_whitelistIsExactlyThreeTypes() {
    // Pin the whitelist contents. If a new action type is added that
    // legitimately carries only structural text (e.g. a future
    // bundle-ID-only action), it should be ADDED here explicitly,
    // not allowed by accident. This test forces a deliberate choice.
    #expect(ReceiptReplayFormatter.textAlwaysSafe(.keyCombo))
    #expect(ReceiptReplayFormatter.textAlwaysSafe(.menuSelect))
    #expect(ReceiptReplayFormatter.textAlwaysSafe(.switchApp))
    // Everything else must be FALSE — privacy-default-deny.
    let neverSafe: [ActionType] = [
        .click, .doubleClick, .tripleClick, .rightClick, .typeText,
        .scroll, .wait, .undo, .complete, .clarify, .drag, .holdKey,
        .mouseDown, .mouseUp, .mouseMove,
    ]
    for t in neverSafe {
        #expect(!ReceiptReplayFormatter.textAlwaysSafe(t),
                "\(t) must NOT be on the always-safe whitelist — defense-in-depth")
    }
}

@Test
func formatter_targetIndexBracketed() {
    let line = ReceiptReplayFormatter.format(entry(type: .click, targetIndex: 42))
    #expect(line.contains("click[42]"),
            "targetIndex must render in brackets so jq-style scanning still works")
}

@Test
func formatter_tierUppercased() {
    let line = ReceiptReplayFormatter.format(entry(type: .click, tier: "preview"))
    #expect(line.contains("tier=PREVIEW"))
}

@Test
func formatter_longText_truncated() {
    let payload = String(repeating: "x", count: 200)
    let line = ReceiptReplayFormatter.format(entry(type: .typeText, text: payload), showText: true)
    #expect(line.count < 200,
            "long typeText must be truncated to keep terminal output readable")
    #expect(line.contains("..."), "truncation must be visually marked with ellipsis")
}

@Test
func formatter_longExecutionResult_truncated() {
    let result = "error: " + String(repeating: "y", count: 200)
    let line = ReceiptReplayFormatter.format(entry(type: .click, executionResult: result))
    #expect(line.contains("..."), "long executionResult must be truncated")
}

// MARK: - isError

@Test
func isError_rejectedAlwaysCountsAsError() {
    // approved=false catches both capability-deny and user-reject paths.
    #expect(ReceiptReplayFormatter.isError(entry(type: .click, approved: false, executionResult: "rejected")))
    #expect(ReceiptReplayFormatter.isError(entry(type: .complete, approved: false, executionResult: "rejected-immediate-complete")))
}

@Test
func isError_errorPrefixCountsAsError() {
    #expect(ReceiptReplayFormatter.isError(entry(type: .click, executionResult: "error: missing target")))
    #expect(ReceiptReplayFormatter.isError(entry(type: .menuSelect, executionResult: "error: Menu item 'X' not found")))
}

@Test
func isError_normalSuccessIsNotError() {
    #expect(!ReceiptReplayFormatter.isError(entry(type: .click, executionResult: "clicked")))
    #expect(!ReceiptReplayFormatter.isError(entry(type: .complete, executionResult: "task complete")))
    #expect(!ReceiptReplayFormatter.isError(entry(type: .wait, executionResult: "waited")))
}

@Test
func isError_caseSensitive() {
    // Orchestrator's catch site writes `"error: \(...)"` lowercase exactly.
    // The filter does NOT match `"Error:"` (would catch error messages
    // that include the word "Error" elsewhere — false positive class).
    #expect(!ReceiptReplayFormatter.isError(entry(type: .click, executionResult: "Error: capitalized")))
}

// MARK: - filter()

@Test
func filter_errorsOnly_keepsOnlyErrors() {
    let entries = [
        entry(type: .click, executionResult: "clicked"),
        entry(type: .click, executionResult: "error: stale"),
        entry(type: .click, approved: false, executionResult: "rejected"),
        entry(type: .wait, executionResult: "waited"),
    ]
    let filtered = ReceiptReplayFormatter.filter(entries: entries, errorsOnly: true)
    #expect(filtered.count == 2)
}

@Test
func filter_dateMatchesUTCCalendarDay() {
    // 2026-05-23 00:00:00 UTC and 2026-05-23 23:59:59 UTC must both match.
    let early = Date(timeIntervalSince1970: 1_779_494_400)  // 2026-05-23 00:00:00 UTC
    let late  = Date(timeIntervalSince1970: 1_779_580_799) // 2026-05-23 23:59:59 UTC
    let nextDay = Date(timeIntervalSince1970: 1_779_580_801) // 2026-05-24 00:00:01 UTC

    let entries = [
        entry(type: .click, timestamp: early),
        entry(type: .click, timestamp: late),
        entry(type: .click, timestamp: nextDay),
    ]
    guard let target = ReceiptReplayFormatter.parseDateFlag("2026-05-23") else {
        Issue.record("date parser failed")
        return
    }
    let filtered = ReceiptReplayFormatter.filter(entries: entries, date: target)
    #expect(filtered.count == 2, "must include both 00:00:00Z and 23:59:59Z UTC; exclude the next day")
}

@Test
func filter_capHonored() {
    let entries = (0..<50).map { _ in entry(type: .click) }
    let filtered = ReceiptReplayFormatter.filter(entries: entries, cap: 10)
    #expect(filtered.count == 10)
}

@Test
func filter_combinedDateAndErrors() {
    let day1 = Date(timeIntervalSince1970: 1_779_494_400)  // 2026-05-23 UTC
    let day2 = Date(timeIntervalSince1970: 1_779_580_801)  // 2026-05-24 UTC
    let entries = [
        entry(type: .click, executionResult: "error: x", timestamp: day1),
        entry(type: .click, executionResult: "clicked", timestamp: day1),
        entry(type: .click, executionResult: "error: y", timestamp: day2),
    ]
    let target = ReceiptReplayFormatter.parseDateFlag("2026-05-23")!
    let filtered = ReceiptReplayFormatter.filter(entries: entries, date: target, errorsOnly: true)
    #expect(filtered.count == 1, "only day1's error must survive both filters")
    #expect(filtered.first?.executionResult == "error: x")
}

// MARK: - parseDateFlag()

@Test
func parseDateFlag_acceptsYYYYMMDD() {
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-05-23") != nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("2024-01-01") != nil)
}

@Test
func parseDateFlag_today_returnsStartOfTodayUTC() {
    let now = Date(timeIntervalSince1970: 1_779_572_000)  // 2026-05-23 23:33:20 UTC
    guard let parsed = ReceiptReplayFormatter.parseDateFlag("today", now: now) else {
        Issue.record("parser failed on 'today'")
        return
    }
    // start of 2026-05-23 UTC = 1_779_494_400
    #expect(parsed.timeIntervalSince1970 == 1_779_494_400,
            "'today' must resolve to start-of-day in UTC, matching filename alignment")
}

@Test
func parseDateFlag_invalidReturnsNil() {
    #expect(ReceiptReplayFormatter.parseDateFlag("not-a-date") == nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("2026/05/23") == nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("") == nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-13-99") == nil,
            "out-of-range components must be rejected")
}

@Test
func parseDateFlag_trimsAndIsCaseInsensitiveForToday() {
    let now = Date(timeIntervalSince1970: 1_779_572_000)
    #expect(ReceiptReplayFormatter.parseDateFlag("  TODAY  ", now: now) != nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("Today", now: now) != nil)
}

@Test
func parseDateFlag_rejectsOutOfRangeMonthAndDay() {
    // Reviewer-caught Sev-1: explicit range validation in the
    // pre-validator. Pinned BEFORE the DateFormatter handoff so the
    // CLI's behavior doesn't silently depend on Foundation's
    // calendar-overflow contract (platform-dependent).
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-13-01") == nil,
            "month 13 must be rejected by the pre-validator")
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-00-15") == nil,
            "month 0 must be rejected")
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-05-32") == nil,
            "day 32 must be rejected")
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-05-00") == nil,
            "day 0 must be rejected")
    // Positive: valid edge cases still pass.
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-01-01") != nil)
    #expect(ReceiptReplayFormatter.parseDateFlag("2026-12-31") != nil)
}
