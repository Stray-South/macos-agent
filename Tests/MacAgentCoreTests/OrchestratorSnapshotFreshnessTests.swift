import Foundation
@testable import MacAgentCore
import Testing

// PR-3 invariant: after every non-wait action, the orchestrator forces a
// fresh AX snapshot on the next observe (`needsFreshPerception = true`).
// This is the production guard against stale-snapshot dispatch after
// switchApp / keyCombo cmd+tab / keyCombo cmd+space / menuSelect — any
// action whose execution reshapes the AX tree.
//
// Background: AXPerception's 200ms cache window can hand back a snapshot
// captured BEFORE the app switch occurred, with stale indices pointing
// into the previous app's tree. The 2026-05-23 live audit hit AX errors
// `-25200`/`-25202` consistent with this class of stale-handle dispatch.
// The orchestrator already invalidates the cache after every non-wait
// action (Orchestrator.swift:459); this test locks the invariant down
// with a behavioural assertion that a regression cannot pass.

private actor RecordingPerception: AXPerceiving {
    private(set) var forceRefreshHistory: [Bool] = []
    private let fixedSnapshot: PerceptionSnapshot

    init(bundleID: String = "com.example.app") {
        self.fixedSnapshot = try! PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: bundleID,
            elements: [
                UIElement(index: 0, role: "AXTextField", label: "Probe", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 100, height: 30)),
                          isEnabled: true, isVisible: true)
            ]
        )
    }

    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        forceRefreshHistory.append(forceRefresh)
        return ObservedSnapshot(snapshot: fixedSnapshot)
    }

    func recordedRefreshFlags() async -> [Bool] { forceRefreshHistory }
}

private actor ScriptedLLM: ActionThinking {
    let actions: [AgentAction]
    private var index = 0

    init(actions: [AgentAction]) {
        self.actions = actions
    }

    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        defer { index += 1 }
        return actions[min(index, actions.count - 1)]
    }
}

private struct EmptyVision: VisionPerceiving {
    func captureVisualContext() async throws -> VisionCapture {
        VisionCapture(observations: [], usedFullScreenFallback: false)
    }
}

private struct NoPlanner: TaskPlanning {
    func plan(task: String, snapshot: PerceptionSnapshot) async -> String? { nil }
}

@MainActor
private final class AutoApproveOverlay: OverlayControlling, @unchecked Sendable {
    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        completion(.approveOnce)
    }
}

// MARK: - Tests

@Test
func forceRefresh_isFalseOnFirstObserve_thenTrueAfterNonWaitAction() async throws {
    // Two-step script: keyCombo (non-wait, mutates AX tree) then complete.
    // Observe-1 sets up the snapshot (forceRefresh:false on cold start).
    // After keyCombo executes, orchestrator sets needsFreshPerception=true.
    // Observe-2 (before the complete action's pre-think observe) → forceRefresh:true.
    let perception = RecordingPerception()
    let overlay = await MainActor.run { AutoApproveOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: ScriptedLLM(actions: [
            AgentAction(type: .keyCombo, text: "cmd+tab", confidence: 0.9,
                        requiresConfirmation: false, rationale: "Switch app"),
            AgentAction(type: .complete, confidence: 0.9,
                        requiresConfirmation: false, rationale: "Done"),
        ]),
        perception: perception,
        visionFallback: EmptyVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        planner: NoPlanner(),
        onEvent: { _ in }
    )

    try await orchestrator.run(task: "switch and complete")

    let history = await perception.recordedRefreshFlags()
    #expect(history.count >= 2,
            "Need at least two observe() calls — got \(history.count). History: \(history)")
    #expect(history[0] == false,
            "First observe() must be forceRefresh:false (cold start, no prior action).")
    // Every observe after the first must be forceRefresh:true because every
    // preceding action was non-wait. Indexing only `history[1]` would be
    // fragile if the orchestrator ever inserts an extra observe (e.g. a
    // pre-plan observe); checking the all-true tail is robust to that.
    for (i, flag) in history.enumerated() where i > 0 {
        #expect(flag == true,
                "Observe #\(i + 1) must be forceRefresh:true — preceding action was non-wait. History: \(history)")
    }
}

@Test
func forceRefresh_remainsTrueAfterEachNonWaitAction() async throws {
    // Longer script: keyCombo, keyCombo, complete. Every observe after a
    // meaningful action must run a fresh capture.
    let perception = RecordingPerception()
    let overlay = await MainActor.run { AutoApproveOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: ScriptedLLM(actions: [
            AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                        requiresConfirmation: false, rationale: "Spotlight"),
            AgentAction(type: .keyCombo, text: "escape", confidence: 0.9,
                        requiresConfirmation: false, rationale: "Dismiss"),
            AgentAction(type: .complete, confidence: 0.9,
                        requiresConfirmation: false, rationale: "Done"),
        ]),
        perception: perception,
        visionFallback: EmptyVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        planner: NoPlanner(),
        onEvent: { _ in }
    )

    try await orchestrator.run(task: "spotlight then dismiss then complete")

    let history = await perception.recordedRefreshFlags()
    #expect(history.count >= 3,
            "Need at least three observes — got \(history.count). History: \(history)")
    #expect(history[0] == false, "Cold start.")
    // Every subsequent observe is post-non-wait → must be fresh.
    for (i, flag) in history.enumerated() where i > 0 {
        #expect(flag == true,
                "Observe #\(i + 1) must be forceRefresh:true — preceding action was non-wait. History: \(history)")
    }
}
