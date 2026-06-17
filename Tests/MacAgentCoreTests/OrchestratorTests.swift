import Foundation
import MacAgentCore
import Testing

@Test
func orchestratorWritesReceiptForApprovedAction() async throws {
    let overlay = await MainActor.run { TestOverlay(decisions: [true]) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let orchestrator = Orchestrator(
        llm: MockLLM(actions: [
            AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done"),
        ]),
        perception: MockPerception(),
        visionFallback: MockVision(),
        overlay: overlay,
        receiptWriter: writer,
        throughlineStore: nil
    )

    try await orchestrator.run(task: "Finish")

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let content = try String(contentsOf: files[0])
    #expect(content.contains("\"executionResult\":\"task complete\""))
}

@Test
func orchestratorPausesForPreviewAndLogsRejection() async throws {
    let overlay = await MainActor.run { TestOverlay(decisions: [false]) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let orchestrator = Orchestrator(
        llm: MockLLM(actions: [
            AgentAction(type: .typeText, targetIndex: 0, text: "hello", confidence: 0.9, requiresConfirmation: false, rationale: "Type"),
        ]),
        perception: MockPerception(),
        visionFallback: MockVision(),
        overlay: overlay,
        receiptWriter: writer,
        throughlineStore: nil
    )

    try await orchestrator.run(task: "Type hello")

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    let content = try String(contentsOf: files[0])
    #expect(content.contains("\"approved\":false"))
}

private actor MockLLM: ActionThinking {
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

private struct MockPerception: AXPerceiving {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXTextField", label: "Message", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 100, height: 30)), isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

private struct MockVision: VisionPerceiving {
    func captureVisualContext() async throws -> VisionCapture {
        VisionCapture(observations: [], usedFullScreenFallback: false)
    }
}

@Test
func parsePlanStepsExtractsNumberedLines() {
    let plan = """
    [PLAN for this task — follow these steps in order]
    1. Click the "New Note" button
    2. Type the note content
    3. Press cmd+s to save
    """
    let steps = Orchestrator.parsePlanSteps(from: plan)
    #expect(steps.count == 3)
    #expect(steps[0] == "Click the \"New Note\" button")
    #expect(steps[1] == "Type the note content")
    #expect(steps[2] == "Press cmd+s to save")
}

@Test
func parsePlanStepsReturnEmptyForSingleStep() {
    let plan = "[PLAN]\n1. Click OK"
    let steps = Orchestrator.parsePlanSteps(from: plan)
    #expect(steps.isEmpty) // single step — no strip shown
}

@Test
func planProgressEventEmittedAndStepAdvancesAfterMeaningfulAction() async throws {
    let collector = EventCollector()
    let overlay = await MainActor.run { TestOverlay(decisions: [true, true]) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: MockLLM(actions: [
            // keyCombo doesn't require target resolution — safe in headless tests.
            AgentAction(type: .keyCombo, text: "cmd+n", confidence: 0.9, requiresConfirmation: false, rationale: "Step 1"),
            AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done"),
        ]),
        perception: MockPerception(),
        visionFallback: MockVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        planner: MockPlanner(),
        onEvent: { event in await collector.append(event) }
    )

    try await orchestrator.run(task: "Create a new note and save it with some content in it")

    let events = await collector.events
    let progressEvents = events.compactMap { event -> (steps: [String], currentStep: Int)? in
        if case .planProgress(let steps, let step) = event { return (steps, step) }
        return nil
    }
    // Initial planProgress emitted at step 0
    #expect(progressEvents.first?.currentStep == 0)
    #expect(progressEvents.first?.steps.count == 3)
    // After the click action, step advances to 1
    #expect(progressEvents.dropFirst().first?.currentStep == 1)
}

// Regression for the meaningful-action classifier (Orchestrator.swift:421-427)
// missing `.tripleClick` and `.drag` — both should advance the plan step pointer
// because they make real UI progress (text-select, slider/DnD), unlike
// scroll/wait/complete/clarify/undo/switchApp.
@Test
func planProgressAdvancesForTripleClickAndDrag() async throws {
    let collector = EventCollector()
    let overlay = await MainActor.run { TestOverlay(decisions: [true, true, true]) }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: MockLLM(actions: [
            // tripleClick: text-select use case. coordinate set so resolveTarget
            // takes the .coordinate fallback (no AX needed in headless test).
            AgentAction(type: .tripleClick, confidence: 0.9, requiresConfirmation: false,
                        rationale: "Select paragraph",
                        coordinate: CodablePoint(.init(x: 100, y: 100))),
            // drag: slider/DnD use case.
            AgentAction(type: .drag, confidence: 0.9, requiresConfirmation: false,
                        rationale: "Drag slider to 50%",
                        coordinate: CodablePoint(.init(x: 300, y: 100)),
                        startCoordinate: CodablePoint(.init(x: 100, y: 100))),
            AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "Done"),
        ]),
        perception: MockPerception(),
        visionFallback: MockVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        planner: MockPlanner(),
        onEvent: { event in await collector.append(event) }
    )

    try await orchestrator.run(task: "Select the paragraph then drag the slider")

    let events = await collector.events
    let progress = events.compactMap { event -> Int? in
        if case .planProgress(_, let step) = event { return step }
        return nil
    }
    // Initial emit at 0, advance after tripleClick → 1, advance after drag → 2.
    #expect(progress.first == 0, "initial planProgress at step 0; got \(progress)")
    #expect(progress.contains(1), "tripleClick must advance the pointer to step 1; got \(progress)")
    #expect(progress.contains(2), "drag must advance the pointer to step 2; got \(progress)")
}

private actor EventCollector {
    var events: [OrchestratorEvent] = []
    func append(_ event: OrchestratorEvent) { events.append(event) }
}

private struct MockPlanner: TaskPlanning {
    func plan(task: String, snapshot: PerceptionSnapshot) async -> String? {
        """
        [PLAN for this task — follow these steps in order]
        1. Click the New Note button
        2. Type the note content
        3. Press cmd+s to save
        """
    }
}

@MainActor
private final class TestOverlay: OverlayControlling, @unchecked Sendable {
    private var decisions: [Bool]

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}

    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        let approve = decisions.isEmpty ? true : decisions.removeFirst()
        completion(approve ? .approveOnce : .rejectOnce)
    }
}
