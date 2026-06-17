import Foundation
@testable import MacAgentCore
import Testing

// Unit 24 — T1 coverage for `ActionRegressionScenarios.runMultiStep`.
//
// These tests use a `MockSequencedLLM` to validate the harness mechanic
// without making any live API calls. The mock returns scripted actions
// in order; tests assert the harness:
//   1. Walks ALL steps when each passes
//   2. Fail-fast: stops at the first diverging step (saves API spend)
//   3. nil-advanceSnapshot keeps cursor unchanged for the next call
//   4. History append shape matches production (assistant role + rationale,
//      cap at `historyCap` entries)
//
// The matching T2 layer (live LLM, multi-step scenarios in `defaultScenarios()`)
// regression-guards real model behaviour and ships via `MacOSAgentSmokeAction`.

private actor MockSequencedLLM: ActionThinking {
    let scripted: [AgentAction]
    var callIndex: Int = 0
    /// History snapshots captured at each call site. Lets a test assert the
    /// harness mutated history per production parity (Orchestrator.swift PARITY-ANCHOR: history-append).
    var capturedHistories: [[LLMMessage]] = []
    /// Snapshots captured at each call site. Lets a test assert the harness
    /// advanced (or didn't advance) the cursor per ExpectedStep.advanceSnapshot.
    var capturedSnapshots: [PerceptionSnapshot] = []

    init(scripted: [AgentAction]) {
        self.scripted = scripted
    }

    func nextAction(
        task: String,
        snapshot: PerceptionSnapshot,
        history: [LLMMessage],
        runningApps: [RunningApp]
    ) async throws -> AgentAction {
        capturedHistories.append(history)
        capturedSnapshots.append(snapshot)
        defer { callIndex += 1 }
        return scripted[min(callIndex, scripted.count - 1)]
    }
}

// MARK: - Fixture helpers

private func snapshotA() throws -> PerceptionSnapshot {
    try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.example.A",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "A",
                      value: nil,
                      frame: CodableRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                      isEnabled: true, isVisible: true)
        ]
    )
}

private func snapshotB() throws -> PerceptionSnapshot {
    try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.example.B",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "B",
                      value: nil,
                      frame: CodableRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                      isEnabled: true, isVisible: true)
        ]
    )
}

private func snapshotC() throws -> PerceptionSnapshot {
    try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.example.C",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "C",
                      value: nil,
                      frame: CodableRect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                      isEnabled: true, isVisible: true)
        ]
    )
}

// MARK: - Tests

@Test
func multiStepHarness_walksAllStepsWhenEachPasses() async throws {
    let a = try snapshotA(), b = try snapshotB()
    let scenario = ActionRegressionScenarios.Scenario(
        id: "multistep_happy_path",
        task: "fixture",
        snapshot: a,
        expectedActionType: "switchApp",
        expectedSteps: [
            .init(expectedActionType: "switchApp", advanceSnapshot: b),
            .init(expectedActionType: "click"),
        ]
    )
    let llm = MockSequencedLLM(scripted: [
        AgentAction(type: .switchApp, text: "com.example.B", confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 0 switchApp"),
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1 click"),
    ])
    let outcomes = try await ActionRegressionScenarios.runAll(llm: llm, scenarios: [scenario])
    let outcome = try #require(outcomes.first)
    #expect(outcome.passed,
            "happy path: every step matches the script, parent Outcome must pass")
    #expect(outcome.stepOutcomes.count == 2,
            "happy path: every step produces a StepOutcome")
    let allPassed = outcome.stepOutcomes.allSatisfy(\.passed)
    #expect(allPassed,
            "every step must individually pass")
}

@Test
func multiStepHarness_failFastStopsAtFirstDivergence() async throws {
    let a = try snapshotA(), b = try snapshotB(), c = try snapshotC()
    let scenario = ActionRegressionScenarios.Scenario(
        id: "multistep_fail_fast",
        task: "fixture",
        snapshot: a,
        expectedActionType: "switchApp",
        expectedSteps: [
            .init(expectedActionType: "switchApp", advanceSnapshot: b),
            .init(expectedActionType: "click", advanceSnapshot: c),
            .init(expectedActionType: "typeText"),
        ]
    )
    let llm = MockSequencedLLM(scripted: [
        AgentAction(type: .switchApp, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 0 ok"),
        // Step 1 diverges — script returns scroll instead of click.
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1 scroll WRONG"),
        // Step 2 should never run — harness fail-fasts after step 1.
        AgentAction(type: .typeText, text: "should not be observed", confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 2 not reached"),
    ])
    let outcomes = try await ActionRegressionScenarios.runAll(llm: llm, scenarios: [scenario])
    let outcome = try #require(outcomes.first)
    #expect(!outcome.passed,
            "fail-fast: parent Outcome must be false when any step diverges")
    #expect(outcome.stepOutcomes.count == 2,
            "fail-fast: stepOutcomes contains step 0 (pass) + step 1 (fail), step 2 absent — saves API spend")
    #expect(outcome.stepOutcomes[0].passed)
    #expect(!outcome.stepOutcomes[1].passed,
            "step 1 must be the diverging step in the surfaced outcomes")
    // Pin the LLM call count to validate the fail-fast actually short-circuited
    // the network call for step 2.
    let callCount = await llm.callIndex
    #expect(callCount == 2,
            "LLM must have been called exactly 2× (steps 0 + 1, NOT step 2) — fail-fast saves the third call")
}

@Test
func multiStepHarness_nilAdvanceSnapshotKeepsCursorUnchanged() async throws {
    let a = try snapshotA()
    let scenario = ActionRegressionScenarios.Scenario(
        id: "multistep_nil_advance",
        task: "fixture",
        snapshot: a,
        expectedActionType: "scroll",
        expectedSteps: [
            // Both steps use the SAME snapshot — the harness must feed
            // snapshot `a` to both nextAction calls.
            .init(expectedActionType: "scroll", advanceSnapshot: nil),
            .init(expectedActionType: "scroll"),
        ]
    )
    let llm = MockSequencedLLM(scripted: [
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 0"),
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1"),
    ])
    _ = try await ActionRegressionScenarios.runAll(llm: llm, scenarios: [scenario])
    let snapshots = await llm.capturedSnapshots
    #expect(snapshots.count == 2,
            "two calls captured")
    // Snapshots must be value-equal to `a` — same focusedAppBundleID, same hash.
    #expect(snapshots[0].focusedAppBundleID == snapshots[1].focusedAppBundleID,
            "nil-advanceSnapshot must feed the SAME snapshot to step N+1")
    #expect(snapshots[0].hash == snapshots[1].hash,
            "snapshot hashes must match — cursor was not advanced")
}

@Test
func multiStepHarness_historyAppendShapeMatchesProduction() async throws {
    // Production loop (Orchestrator.swift PARITY-ANCHOR: history-append): appends
    // LLMMessage(role: "assistant", content: action.rationale).
    // Harness must mirror exactly so a future step's prompt context
    // mirrors what production would feed.
    //
    // Unit 25e — production now appends both an assistant rationale AND
    // a user observation turn after each successful action (Orchestrator
    // .swift around line 760). The harness mirrors that. After Unit 25e,
    // each completed step contributes 2 history messages, not 1.
    let a = try snapshotA(), b = try snapshotB(), c = try snapshotC()
    let scenario = ActionRegressionScenarios.Scenario(
        id: "multistep_history_shape",
        task: "fixture",
        snapshot: a,
        expectedActionType: "switchApp",
        expectedSteps: [
            .init(expectedActionType: "switchApp", advanceSnapshot: b),
            .init(expectedActionType: "click", advanceSnapshot: c),
            .init(expectedActionType: "complete"),
        ]
    )
    let llm = MockSequencedLLM(scripted: [
        AgentAction(type: .switchApp, confidence: 0.9,
                    requiresConfirmation: false, rationale: "RATIONALE_ZERO"),
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "RATIONALE_ONE"),
        AgentAction(type: .complete, confidence: 0.9,
                    requiresConfirmation: false, rationale: "RATIONALE_TWO"),
    ])
    _ = try await ActionRegressionScenarios.runAll(llm: llm, scenarios: [scenario])
    let histories = await llm.capturedHistories
    #expect(histories.count == 3, "three calls captured")
    #expect(histories[0].isEmpty,
            "step 0's history must be empty — first call in the trajectory")
    // Step 1's call: history has 2 entries from step 0 (assistant rationale + user observation).
    #expect(histories[1].count == 2,
            "step 1's history must contain step 0's assistant rationale + the synthetic user observation")
    #expect(histories[1].first?.role == "assistant",
            "Unit 25e parity: first entry is the assistant rationale (Orchestrator.swift PARITY-ANCHOR: history-append)")
    #expect(histories[1].first?.content == "RATIONALE_ZERO",
            "Unit 25e parity: assistant content is the prior action's rationale verbatim")
    #expect(histories[1].last?.role == "user",
            "Unit 25e parity: second entry is the synthetic user observation (Orchestrator.swift around line 760)")
    #expect(histories[1].last?.content == "Previous action observed: switchApp executed",
            "Unit 25e parity: user observation content names the action type that just executed")
    // Step 2's call: history has 4 entries from steps 0 + 1 (2 per step).
    #expect(histories[2].count == 4,
            "step 2's history accumulates 2 messages from each of step 0 + step 1")
    #expect(histories[2].last?.role == "user",
            "newest entry is the immediately-prior step's user observation, keeping conversation alternation")
    #expect(histories[2].last?.content == "Previous action observed: click executed",
            "newest user observation names the action type from step 1")
}
