import Foundation
@testable import MacAgentCore
import Testing

// Unit tests for the live-LLM regression scenario library.
//
// The harness binary (`MacOSAgentSmokeAction`) is opt-in (env-gated) and
// makes real Anthropic calls — not part of routine CI. These tests cover
// the static scenario definitions and the outcome-classification logic
// using mock LLM clients, so a future change to scenarios or to the
// pass/fail predicate fails CI before it reaches the live harness.

private actor MockLLM: ActionThinking {
    let scriptedReply: AgentAction
    init(reply: AgentAction) { self.scriptedReply = reply }
    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        scriptedReply
    }
}

@Test
func defaultScenarios_includesEveryRegressedActionType() throws {
    // The 2026-05-23 audit caught Haiku failing to emit switchApp,
    // typeText, menuSelect, and scroll. Every one must remain covered.
    //
    // NOTE: this is a presence check on the audit-trigger set, NOT an
    // exhaustiveness check. Adding a new regression scenario type (e.g.
    // holdKey, drag) does not require updating this test — the new
    // scenario coexists. But if you delete one of the four audit-trigger
    // scenarios below, this test fails. Intentional asymmetry — see the
    // 2026-05-23 D4 adversarial-review notes.
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let expectedTypes = scenarios.map(\.expectedActionType).sorted()
    #expect(expectedTypes.contains("switchApp"),
            "Default scenarios must cover switchApp (audit-trigger action).")
    #expect(expectedTypes.contains("typeText"))
    #expect(expectedTypes.contains("menuSelect"))
    #expect(expectedTypes.contains("scroll"))
    #expect(expectedTypes.contains("click"),
            "Baseline click scenario must remain — regression on the simplest case must be detectable.")
}

@Test
func defaultScenarios_idsAreUnique() throws {
    // Outcome printing keys on scenario.id; duplicates would silently
    // overwrite each other in reports.
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let ids = scenarios.map(\.id)
    let unique = Set(ids)
    #expect(ids.count == unique.count,
            "Scenario IDs must be unique. Got: \(ids)")
}

@Test
func outcome_passesWhenTypeAndTextMatch() async throws {
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let typeTextScenario = scenarios.first { $0.id == "typeText_search_query" }!
    let goodAction = AgentAction(
        type: .typeText, targetIndex: 0, text: "octopus",
        confidence: 0.95, requiresConfirmation: false,
        rationale: "Typing the requested query."
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: typeTextScenario, action: goodAction)
    #expect(outcome.passed)
    #expect(outcome.observedActionType == "typeText")
    #expect(outcome.observedText == "octopus")
}

@Test
func outcome_failsOnWrongActionType() async throws {
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let typeTextScenario = scenarios.first { $0.id == "typeText_search_query" }!
    // Regression signature: model clicks the search field instead of typing.
    let regressedAction = AgentAction(
        type: .click, targetIndex: 0,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "Focusing the field first."
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: typeTextScenario, action: regressedAction)
    #expect(!outcome.passed,
            "click on a typeText scenario must FAIL — this is the regression class the harness detects.")
}

@Test
func outcome_failsOnMissingTextSubstring() async throws {
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let typeTextScenario = scenarios.first { $0.id == "typeText_search_query" }!
    // Right action type, wrong content — still a fail because the text
    // predicate guards intent.
    let wrongTextAction = AgentAction(
        type: .typeText, targetIndex: 0, text: "wikipedia",
        confidence: 0.9, requiresConfirmation: false,
        rationale: "Typing something else."
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: typeTextScenario, action: wrongTextAction)
    #expect(!outcome.passed)
}

@Test
func outcome_textSubstringIsCaseInsensitive() async throws {
    // The expected substring "com.apple.notes" should match a model that
    // returns "com.apple.Notes" with title-case casing in the bundle ID.
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let switchAppScenario = scenarios.first { $0.id == "switchApp_to_notes" }!
    let mixedCaseAction = AgentAction(
        type: .switchApp, text: "com.apple.Notes",
        confidence: 0.95, requiresConfirmation: false,
        rationale: "Switching."
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: switchAppScenario, action: mixedCaseAction)
    #expect(outcome.passed,
            "Bundle ID substring match must be case-insensitive to tolerate model casing variance.")
}

@Test
func runAll_executesEveryScenario() async throws {
    // Use a mock that always returns click[0] — every scenario except
    // baseline-click should fail. The baseline-click scenario passes
    // because it expects `.click` with no `expectedTextSubstring` or
    // `forbiddenTargetIndex` constraint. Other scenarios fail for one
    // of two reasons:
    //   - non-click expectedActionType (switchApp, typeText, etc.)
    //   - or, post-Unit-20, the recovery scenario fails because
    //     `forbiddenTargetIndex: 0` rejects click[0] regardless of type.
    // Both branches are scenario-count - 1 in aggregate; this exercises
    // the runAll plumbing without depending on each scenario's failure
    // reason.
    let mock = MockLLM(reply: AgentAction(
        type: .click, targetIndex: 0,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "Always click."
    ))
    let outcomes = try await ActionRegressionScenarios.runAll(llm: mock)
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    #expect(outcomes.count == scenarios.count,
            "runAll must produce one outcome per default scenario.")
    let failures = outcomes.filter { !$0.passed }
    #expect(failures.count == scenarios.count - 1,
            "Exactly the baseline-click scenario should pass when the mock always returns click[0]. Other scenarios fail on type mismatch OR (recovery) on forbiddenTargetIndex=0. Got failures: \(failures.map(\.scenario.id))")
}

// Unit 17 / Path F: structural checks on the new dogfood-motivated scenarios.

@Test
func openAppViaVerbScenario_expectsSwitchAppNotKeyCombo() throws {
    // Dogfood failure 2026-05-27: LLM emitted `keyCombo cmd+space` (Spotlight)
    // for "Open Notes" instead of switchApp. This regression guard catches
    // any future model with the same strategy bias.
    let s = try ActionRegressionScenarios.openAppViaVerbScenario()
    #expect(s.expectedActionType == "switchApp",
            "open-verb scenario must demand switchApp — that's the whole point of the regression guard")
    #expect(s.expectedTextSubstring?.lowercased().contains("com.apple.notes") == true,
            "expected bundleID substring must name the target app")
    #expect(s.task.lowercased().contains("open"),
            "task wording must use the 'open' verb that triggered the dogfood failure")
    // The most-likely regression is `keyCombo cmd+space` — assert it would FAIL.
    let spotlightAction = AgentAction(
        type: .keyCombo, text: "cmd+space",
        confidence: 0.9, requiresConfirmation: false,
        rationale: "Open Spotlight to find Notes"
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: s, action: spotlightAction)
    #expect(!outcome.passed,
            "Spotlight emission MUST be classified as a regression — this is the documented failure mode")
}

@Test
func launchAppColdScenario_expectsSwitchAppWithBundleIDNotInRunningApps() throws {
    let s = try ActionRegressionScenarios.launchAppColdScenario()
    #expect(s.expectedActionType == "switchApp")
    #expect(s.expectedTextSubstring?.lowercased().contains("com.apple.calculator") == true)
    // The cold-launch path requires Calculator absent from runningApps —
    // exercises NSWorkspace.openApplication, not just app activation.
    // Case-insensitive check — bundleID convention drift across the
    // codebase (some "com.apple.notes" lowercase, some "com.apple.Notes"
    // title-case) means a string-exact `contains` would pass trivially
    // when the runningApps list uses a different casing. The assertion's
    // intent is "Calculator is NOT pre-staged as already-running" —
    // express that explicitly.
    let runningBundles = s.runningApps.map(\.bundleID)
    let hasCalculator = runningBundles.contains { $0.lowercased() == "com.apple.calculator" }
    #expect(!hasCalculator,
            "scenario must exclude Calculator from runningApps so the cold-launch path is what's exercised")
}

// MARK: - Unit 20 — forbiddenTargetIndex matcher + recovery scenario

@Test
func outcome_forbiddenTargetIndexNil_isBackCompat() throws {
    // Old scenarios without forbiddenTargetIndex must behave identically
    // to pre-Unit-20: type match + optional text match = pass.
    let scenario = try ActionRegressionScenarios.baselineClickScenario()
    #expect(scenario.forbiddenTargetIndex == nil,
            "baseline scenario must not set forbiddenTargetIndex — back-compat path")
    let action = AgentAction(
        type: .click, targetIndex: 0,
        confidence: 1.0, requiresConfirmation: false,
        rationale: "click any index — forbidden=nil ignored"
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: scenario, action: action)
    #expect(outcome.passed,
            "scenario with forbiddenTargetIndex=nil must accept any targetIndex")
}

@Test
func outcome_forbiddenTargetIndexMatches_fails() throws {
    // The recovery scenario forbids index 0. An LLM that ignores the
    // hint and re-emits click[0] must FAIL the outcome predicate.
    let scenario = try ActionRegressionScenarios.recoveryFromExecutorErrorScenario()
    #expect(scenario.forbiddenTargetIndex == 0)
    let regressingAction = AgentAction(
        type: .click, targetIndex: 0,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "regression: re-emit click[0] despite recovery hint"
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: scenario, action: regressingAction)
    #expect(!outcome.passed,
            "LLM re-emitting the forbidden index MUST fail the outcome (that's the entire purpose of forbiddenTargetIndex)")
}

@Test
func outcome_forbiddenTargetIndexDifferent_passes() throws {
    // Same scenario, but the LLM correctly picks index 1 (Cancel).
    let scenario = try ActionRegressionScenarios.recoveryFromExecutorErrorScenario()
    let competentAction = AgentAction(
        type: .click, targetIndex: 1,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "honor recovery hint: pick Cancel instead of Submit"
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: scenario, action: competentAction)
    #expect(outcome.passed,
            "LLM picking a non-forbidden index must pass — that's the success signal")
}

@Test
func outcome_forbiddenTargetIndex_nilLLMIndex_passes() throws {
    // An LLM that emits .click with action.targetIndex=nil (relying on
    // coordinate only) trivially doesn't violate forbiddenTargetIndex.
    // The match should pass; this isn't a regression class
    // forbiddenTargetIndex was designed to catch.
    let scenario = try ActionRegressionScenarios.recoveryFromExecutorErrorScenario()
    let coordOnlyAction = AgentAction(
        type: .click, targetIndex: nil,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "coord-only click — no index to forbid"
    )
    let outcome = ActionRegressionScenarios.Outcome(scenario: scenario, action: coordOnlyAction)
    #expect(outcome.passed,
            "nil action.targetIndex doesn't match forbidden=0 (Int? equality), so passes")
}

@Test
func recoveryFromExecutorErrorScenario_structure() throws {
    // Pin the scenario's shape so a future edit can't silently
    // change its regression-guard behavior.
    let s = try ActionRegressionScenarios.recoveryFromExecutorErrorScenario()
    #expect(s.id == "recovery_picks_alternative")
    #expect(s.expectedActionType == "click")
    #expect(s.forbiddenTargetIndex == 0,
            "forbiddenTargetIndex MUST be 0 — that's the index the task wording tells the LLM failed")
    // The snapshot must have ≥2 enabled buttons so the LLM has somewhere
    // to go after avoiding index 0.
    let enabledButtons = s.snapshot.elements.filter { $0.isEnabled && $0.role == "AXButton" }
    #expect(enabledButtons.count >= 2,
            "recovery scenario must offer at least 2 enabled buttons (the forbidden one + ≥1 alternative)")
    // Task wording must inline the recovery hint (the T2 harness has no
    // history channel for the production Orchestrator's recovery prompt).
    // Tighten the assertion to ALL of: explicit don't-retry instruction,
    // the specific index it points to, AND the alternative-required cue.
    // A future wording edit that drops one signal still produces a
    // visible test failure rather than silently weakening the hint.
    let task = s.task.lowercased()
    #expect(task.contains("do not retry"),
            "task wording must contain the literal don't-retry instruction")
    #expect(task.contains("index 0"),
            "task wording must name the specific forbidden index so the LLM has a concrete reference")
    #expect(task.contains("different"),
            "task wording must cue the LLM that an alternative target is required")
}

@Test
func defaultScenarios_includesRecoveryScenario() throws {
    // Unlike openAppViaVerbScenario (quarantined for known prompt bias),
    // the recovery scenario ships in defaults — a competent LLM should
    // honor an explicit "do NOT" instruction, so failing it IS the
    // regression signal we want.
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    let hasRecovery = scenarios.contains { $0.id == "recovery_picks_alternative" }
    #expect(hasRecovery,
            "recoveryFromExecutorErrorScenario must be in defaults — instruction-following is a bar a competent action model meets")
}

// MARK: - Unit 24 multi-step scenario shape

@Test
func multiStepScenarios_inDefaults() throws {
    // Unit 25h — BOTH multi-step scenarios un-quarantined. The Unit 25
    // chain closed the isFocused schema gap that originally forced them
    // into audit-only. Live audit-mode T2 run (2026-06-03) confirmed
    // 10/10 with the corrected Safari 3-step trajectory and the Notes
    // 3-step trajectory. They now serve as default regression guards
    // for multi-step orchestration in single-app trajectories.
    let scenarios = try ActionRegressionScenarios.defaultScenarios()
    #expect(scenarios.contains { $0.id == "multistep_safari_search" },
            "safariSearchSequenceScenario ships in defaults as of Unit 25h — 3-step (switchApp → cmd+l → typeText) trajectory verified at 10/10 in live audit run")
    #expect(scenarios.contains { $0.id == "multistep_open_notes_search_complete" },
            "openNotesThenSearchThenCompleteScenario ships in defaults as of Unit 25h — 3-step (switchApp → click → typeText) trajectory verified")
    // The audit set now strictly = defaults + 1 (openAppViaVerbScenario,
    // the "Open" verb Spotlight-bias known-failing).
    let audit = try ActionRegressionScenarios.auditScenariosIncludingKnownFailing()
    #expect(audit.count == scenarios.count + 1,
            "Audit set = defaults + 1 known-failing (openAppViaVerbScenario)")
    #expect(audit.contains { $0.id == "open_notes_verb_test" },
            "openAppViaVerbScenario remains in audit-only — Spotlight prompt bias is a separate gap")
}

@Test
func multiStepScenarios_haveNonNilExpectedSteps() throws {
    let safari = try ActionRegressionScenarios.safariSearchSequenceScenario()
    let notes = try ActionRegressionScenarios.openNotesThenSearchThenCompleteScenario()
    // Unit 25g — Safari is now 3 steps (switchApp → keyCombo cmd+l →
    // typeText). The 2-step variant (direct switchApp → typeText) was
    // unrealistic because Safari does not auto-focus the URL bar on
    // switchApp; cmd+l is the realistic intermediate.
    #expect(safari.expectedSteps?.count == 3,
            "safariSearchSequence must walk 3 steps (switchApp → keyCombo cmd+l → typeText) — matches real Safari focus behavior")
    #expect(notes.expectedSteps?.count == 3,
            "openNotesThenSearchThenComplete must walk 3 steps (switchApp → click → typeText)")
}

@Test
func scenario_maxStepsCapEnforced() throws {
    // Crash-loud guard — operators can't accidentally ship a 10-step
    // $2-per-run scenario. Adjusting the cap is a deliberate doc change.
    #expect(ActionRegressionScenarios.Scenario.maxSteps == 3,
            "Scenario.maxSteps cap pinned at 3 — raising requires updating the doc + bumping per-run cost estimate")
}

@Test
func stepOutcome_typeMatchPredicate() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "x", elements: []
    )
    let step = ActionRegressionScenarios.ExpectedStep(
        expectedActionType: "switchApp",
        expectedTextSubstring: "com.apple.notes"
    )
    let action = AgentAction(
        type: .switchApp, text: "com.apple.Notes", confidence: 0.9,
        requiresConfirmation: false, rationale: "switching"
    )
    let outcome = ActionRegressionScenarios.StepOutcome(step: 0, expected: step, action: action)
    #expect(outcome.passed,
            "StepOutcome with matching type + substring must pass")
    _ = snapshot  // suppress unused warning
}

@Test
func stepOutcome_typeMismatchFails() throws {
    let step = ActionRegressionScenarios.ExpectedStep(expectedActionType: "switchApp")
    let action = AgentAction(
        type: .keyCombo, text: "cmd+space", confidence: 0.9,
        requiresConfirmation: false, rationale: "spotlight"
    )
    let outcome = ActionRegressionScenarios.StepOutcome(step: 0, expected: step, action: action)
    #expect(!outcome.passed,
            "StepOutcome must fail when action type diverges — Spotlight-loop regression signal")
}

@Test
func stepOutcome_forbiddenIndexFails() throws {
    let step = ActionRegressionScenarios.ExpectedStep(
        expectedActionType: "click",
        forbiddenTargetIndex: 0
    )
    let action = AgentAction(
        type: .click, targetIndex: 0, confidence: 0.9,
        requiresConfirmation: false, rationale: "clicking submit"
    )
    let outcome = ActionRegressionScenarios.StepOutcome(step: 0, expected: step, action: action)
    #expect(!outcome.passed,
            "StepOutcome must fail when LLM picks the forbidden index — mirrors single-action Outcome semantics")
}
