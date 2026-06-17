/// IntegrationTests.swift
///
/// End-to-end pipeline tests that exercise the full Orchestrator loop
/// with mock LLM, mock perception, and real on-disk support objects
/// (ReceiptWriter, ThroughlineStore). Covers Throughline persistence,
/// planner injection, and multi-run memory.
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - Throughline persistence

@Test
func throughlinePersistsTaskOutcomeAfterSuccessfulRun() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let throughlineURL = tmp.appendingPathComponent("throughline.json")
    let store = ThroughlineStore(fileURL: throughlineURL)

    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store
    )

    // Step 1: confirm the gate (immediate-complete guard requires confirm on step 1)
    try await orchestrator.run(task: "Open a new note in Notes")

    // Give the fire-and-forget Task time to write
    try await Task.sleep(for: .milliseconds(100))

    let saved = await store.load()
    #expect(!saved.taskHistory.isEmpty, "Throughline must record the completed task")
    #expect(saved.taskHistory.first?.task == "Open a new note in Notes")
    #expect(saved.taskHistory.first?.outcome == "success")
}

@Test
func throughlineAccumulatesMultipleRuns() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))

    for i in 1...3 {
        let overlay = await MainActor.run { IntegrationOverlay() }
        let orchestrator = Orchestrator(
            llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
            perception: FixedPerception(),
            visionFallback: FixedVision(),
            overlay: overlay,
            receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts/\(i)")),
            throughlineStore: store
        )
        try await orchestrator.run(task: "Task \(i)")
        try await Task.sleep(for: .milliseconds(50))
    }

    let saved = await store.load()
    #expect(saved.taskHistory.count == 3, "All 3 runs must appear in throughline history")
    // Newest first
    #expect(saved.taskHistory.first?.task == "Task 3")
}

@Test
func throughlinePromptBlockInjectsContextIntoRun() async throws {
    // Pre-seed the throughline with a hard boundary and a position.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))
    var seeded = AgentThroughline()
    seeded.addBoundary("Never empty the trash without user confirmation.")
    seeded.establish(key: "preferred_browser", value: "Safari")
    await store.save(seeded)

    let capture = PromptCaptureActor()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: CapturingLLM(capture: capture),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store
    )

    try await orchestrator.run(task: "Open Safari")
    let task = await capture.capturedTask
    #expect(task.contains("Never empty the trash"), "Hard boundaries must appear in LLM task context")
    #expect(task.contains("preferred_browser"), "Established positions must appear in LLM task context")
    #expect(task.contains("Open Safari"), "Original task must appear in LLM task context")
}

// MARK: - Planner injection

@Test
func plannerOutputIsInjectedIntoSubsequentThinkCalls() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    let capture = SequencedPromptCapture()
    let overlay = await MainActor.run { IntegrationOverlay() }
    // LLM: first call returns wait (no real target needed), second returns complete.
    // This exercises the two-step loop without needing a real AX element lookup.
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .wait, confidence: 0.9, requiresConfirmation: false, rationale: "Waiting for UI"),
            AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done"),
        ], capture: capture),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        planner: StubPlanner(plan: "1. Click Continue\n2. Verify result")
    )

    try await orchestrator.run(task: "Navigate to the settings panel, find the display section, and update the resolution preference")

    let tasks = await capture.tasks
    // The plan is injected into currentTask before the first think() on step 1,
    // so it must appear in every think() call throughout the run.
    #expect(tasks.count >= 2, "LLM must be called for each step")
    #expect(tasks.allSatisfy { $0.contains("1. Click Continue") },
            "Plan must be present in all think() calls — it is injected before step 1 think")
}

@Test
func planProgressInjectedAndAdvancesWithMeaningfulAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let capture = SequencedPromptCapture()
    let overlay = await MainActor.run { IntegrationOverlay() }
    // Step 1: .click at index 0 — meaningful, advances currentPlanStep from 0 → 1.
    // Step 2: .complete — LLM sees the updated progress (step 2 of 2).
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                        requiresConfirmation: false, rationale: "click button"),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: capture),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        // "1. Click button\n2. Complete task" → parsePlanSteps → ["Click button", "Complete task"]
        planner: StubPlanner(plan: "1. Click button\n2. Complete task")
    )
    // Task must be > 6 words and not start with a single-action prefix to trigger the planner.
    try await orchestrator.run(task: "Navigate to the settings panel and click the button")
    let tasks = await capture.tasks
    #expect(tasks.count >= 2, "LLM must be called twice")
    // First think() call: currentPlanStep = 0 → "step 1 of 2"
    #expect(tasks[0].contains("[PLAN PROGRESS: step 1 of 2"),
            "First think() must include [PLAN PROGRESS: step 1 of 2]")
    // After the click executes, currentPlanStep advances to 1.
    // Second think() call: "step 2 of 2"
    #expect(tasks[1].contains("[PLAN PROGRESS: step 2 of 2"),
            "Second think() must include [PLAN PROGRESS: step 2 of 2] after click advanced the step")
}

@Test
func plannerFailureDoesNotAbortRun() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        planner: FailingPlanner()    // always returns nil
    )

    // Should complete without throwing even though planner returned nil.
    try await orchestrator.run(task: "Do something simple")
}

// MARK: - Receipt viewer data integrity

@Test
func receiptsFromMultipleRunsAreReadableInOrder() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let actions: [ActionType] = [.click, .typeText, .menuSelect, .complete]
    for (i, type) in actions.enumerated() {
        let entry = ActionLogEntry(
            action: AgentAction(type: type, targetIndex: i, confidence: 0.9, requiresConfirmation: false, rationale: "Step \(i)"),
            tier: "auto",
            approved: true,
            executionResult: "ok",
            durationMs: i * 5,
            snapshotHash: "snap\(i)"
        )
        try await writer.write(entry)
    }

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "jsonl" }
    #expect(files.count == 1, "All entries should go into a single JSONL file (same day)")

    let lines = (try String(contentsOf: files[0]))
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 4, "All 4 entries must be present")

    // Every line must decode cleanly
    for line in lines {
        let decoded = try decoder.decode(ActionLogEntry.self, from: Data(line.utf8))
        #expect(decoded.approved == true)
    }
}

// MARK: - Vision path

@Test
func visionSectionRendersCorrectly() {
    let obs = [VisionObservation(text: "Submit", boundingBox: CodableRect(CGRect(x: 100, y: 200, width: 80, height: 30)))]
    let section = ClaudeLLMClient.visionSection(observations: obs, indexOffset: 5)
    #expect(section.contains("[VISION-5]"), "Vision section must use the provided index offset")
    #expect(section.contains("\"Submit\""), "Vision section must include the observation text")
    #expect(section.contains("(100,200,80,30)"), "Vision section must include the bounding box")
}

/// Verifies the full observe→merge→think→complete pipeline when AX elements are empty
/// and vision observations are present. The LLM returns .complete immediately, so
/// resolveTarget() is not exercised here (complete has no target). What IS covered:
/// - VisionOnlyPerception → empty AX snapshot
/// - VisionWithObservationFallback → merged snapshot with visionObservations non-empty
/// - visionIndexOffset = 0 (no AX elements) does not panic or misroute
/// - Throughline records outcome as "success"
/// Executor vision dispatch (resolveTarget → CGPoint → CGEvent) is tested by
/// ExecutorTests where CGEvent synthesis can be verified without a real display.
@Test
func visionSnapshotMergeCompletesRunSuccessfully() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))

    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, targetIndex: 0, confidence: 0.9, requiresConfirmation: false, rationale: "Done via vision")),
        perception: VisionOnlyPerception(),
        visionFallback: VisionWithObservationFallback(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store
    )

    try await orchestrator.run(task: "Click the Submit button")
    try await Task.sleep(for: .milliseconds(100))

    let saved = await store.load()
    #expect(saved.taskHistory.first?.outcome == "success", "Vision-only run must complete as success")
}

// MARK: - Throughline data model

@Test
func throughlinePromptBlockFormatsAllSections() {
    var t = AgentThroughline()
    #expect(t.promptBlock().isEmpty, "Empty throughline must produce empty prompt block")

    t.addBoundary("Never delete files.")
    t.establish(key: "browser", value: "Safari")
    t.record(TaskRecord(task: "Open Notes", outcome: "success", stepCount: 3, appBundleID: "com.apple.Notes"))

    let block = t.promptBlock()
    #expect(block.contains("Never delete files."))
    #expect(block.contains("browser: Safari"))
    #expect(block.contains("Open Notes"))
    #expect(block.contains("success"))
    #expect(block.contains("PERSISTENT CONTEXT"))
}

@Test
func throughlineRemoveBoundaryRemovesMatchingRule() {
    var t = AgentThroughline()
    t.addBoundary("Never delete files.")
    t.addBoundary("Always confirm before sending email.")
    t.removeBoundary("Never delete files.")
    #expect(t.hardBoundaries == ["Always confirm before sending email."])
}

@Test
func throughlineRemovePositionRemovesKey() {
    var t = AgentThroughline()
    t.establish(key: "browser", value: "Safari")
    t.establish(key: "editor", value: "Xcode")
    t.removePosition(key: "browser")
    #expect(t.positions == ["editor": "Xcode"])
}

@Test
func throughlineClearHistoryPreservesBoundariesAndPositions() {
    var t = AgentThroughline()
    t.addBoundary("Never delete files.")
    t.establish(key: "browser", value: "Safari")
    t.record(TaskRecord(task: "Open Notes", outcome: "success", stepCount: 2, appBundleID: "com.apple.Notes"))
    t.clearHistory()
    #expect(t.taskHistory.isEmpty)
    #expect(t.hardBoundaries == ["Never delete files."])
    #expect(t.positions["browser"] == "Safari")
}

@Test
func throughlineHistoryCapAtMaxHistory() {
    var t = AgentThroughline()
    for i in 0..<(AgentThroughline.maxHistory + 5) {
        t.record(TaskRecord(task: "Task \(i)", outcome: "success", stepCount: 1, appBundleID: "app"))
    }
    #expect(t.taskHistory.count == AgentThroughline.maxHistory, "History must be capped at maxHistory")
    #expect(t.taskHistory.first?.task == "Task \(AgentThroughline.maxHistory + 4)", "Newest entry must be first")
}

// MARK: - Mocks

private actor FixedLLM: ActionThinking {
    let action: AgentAction
    init(action: AgentAction) { self.action = action }
    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction { action }
}

private actor CapturingLLM: ActionThinking {
    let capture: PromptCaptureActor
    private var callCount = 0

    init(capture: PromptCaptureActor) { self.capture = capture }

    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        await capture.capture(task)
        callCount += 1
        return AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")
    }
}

private actor SequencedLLM: ActionThinking {
    private let actions: [AgentAction]
    private let capture: SequencedPromptCapture
    private var index = 0

    init(actions: [AgentAction], capture: SequencedPromptCapture) {
        self.actions = actions
        self.capture = capture
    }

    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        await capture.capture(task)
        defer { index += 1 }
        return actions[min(index, actions.count - 1)]
    }
}

private struct FixedPerception: AXPerceiving {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Continue", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                          isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

private struct FixedVision: VisionPerceiving {
    func captureVisualContext() async throws -> VisionCapture {
        VisionCapture(observations: [], usedFullScreenFallback: false)
    }
}

/// AX perception that always returns an empty element list, triggering vision fallback.
private struct VisionOnlyPerception: AXPerceiving {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.electron",
            elements: []
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// Vision fallback that returns a single observation, simulating an Electron app screen.
private struct VisionWithObservationFallback: VisionPerceiving {
    func captureVisualContext() async throws -> VisionCapture {
        let obs = VisionObservation(
            text: "Submit",
            boundingBox: CodableRect(CGRect(x: 200, y: 400, width: 100, height: 40))
        )
        return VisionCapture(observations: [obs], usedFullScreenFallback: true, captureOrigin: .zero)
    }
}

@MainActor
private final class IntegrationOverlay: OverlayControlling, @unchecked Sendable {
    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        completion(.approveOnce)
    }
}

private struct StubPlanner: TaskPlanning {
    let plan: String
    func plan(task: String, snapshot: PerceptionSnapshot) async -> String? {
        "[PLAN for this task — follow these steps in order]\n\(plan)"
    }
}

private struct FailingPlanner: TaskPlanning {
    func plan(task: String, snapshot: PerceptionSnapshot) async -> String? { nil }
}

// Separate actor types needed because CapturingLLM and SequencedLLM need different capture types.
private actor PromptCaptureActor {
    var capturedTask: String = ""
    func capture(_ task: String) { capturedTask = task }
}

private actor SequencedPromptCapture {
    var tasks: [String] = []
    func capture(_ task: String) { tasks.append(task) }
}

// MARK: - Error and edge-case paths

/// LLM returns .clarify on the first call, .complete on subsequent calls.
private actor ClarifyThenCompleteLLM: ActionThinking {
    private var callCount = 0
    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        defer { callCount += 1 }
        if callCount == 0 {
            return AgentAction(type: .clarify, confidence: 0.9, requiresConfirmation: false, rationale: "Need more info")
        }
        return AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")
    }
}

/// Perception that succeeds for the first (failOn-1) calls, then throws permissionsRevoked.
private actor FailingAfterNthCallPerception: AXPerceiving {
    private var callCount = 0
    let failOn: Int
    init(failOn: Int) { self.failOn = failOn }
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        callCount += 1
        guard callCount < failOn else { throw AXPerceptionError.permissionsRevoked }
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 60, height: 30)),
                          isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// LLM that always throws a given error.
private actor ThrowingLLM: ActionThinking {
    let error: Error
    init(error: Error) { self.error = error }
    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        throw error
    }
}

/// Overlay that always rejects every action gate.
@MainActor
private final class RejectingOverlay: OverlayControlling, @unchecked Sendable {
    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        completion(.rejectOnce)
    }
}

/// Unit 29 — overlay that STORES the gate completion instead of answering,
/// so the gate parks and the timeout heartbeat fires. The test invokes the
/// stored completion later to resume the run, simulating a slow (e.g.
/// hands-free) operator who answers after the timeout interval.
@MainActor
private final class DeferringOverlay: OverlayControlling, @unchecked Sendable {
    var storedCompletion: ((ApprovalDecision) -> Void)?
    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {
        storedCompletion = completion // park — do NOT auto-respond
    }
}

/// Holds an Orchestrator reference so the event handler can call resume() after the
/// run suspends into withCheckedContinuation. Needed because actors can't be weakly
/// captured by non-class types.
private actor OrchestratorBox {
    var orchestrator: Orchestrator?
    func set(_ o: Orchestrator) { orchestrator = o }
    func resume() async { await orchestrator?.resume(withClarification: "today") }
}

private actor IntegrationEventCollector {
    var events: [OrchestratorEvent] = []
    func append(_ event: OrchestratorEvent) { events.append(event) }
    func contains(_ predicate: (OrchestratorEvent) -> Bool) -> Bool { events.contains(where: predicate) }
    func allEvents() -> [OrchestratorEvent] { events }
    func count(_ predicate: (OrchestratorEvent) -> Bool) -> Int { events.filter(predicate).count }
}

// V — clarification happy path
@Test
func clarificationResumeCompletesRunSuccessfully() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let box = OrchestratorBox()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)

    let orchestrator = Orchestrator(
        llm: ClarifyThenCompleteLLM(),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in
            await collector.append(event)
            if case .clarificationRequested = event {
                // Defer resume so withCheckedContinuation has time to set pendingClarification.
                Task {
                    try? await Task.sleep(for: .milliseconds(10))
                    await box.resume()
                }
            }
        }
    )
    await box.set(orchestrator)

    try await orchestrator.run(task: "What is the status of my download?")

    #expect(await collector.contains { if case .clarificationRequested = $0 { return true }; return false },
            "clarificationRequested must be emitted")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "finished must be emitted after clarification is answered")
}

// C — permissions revoked mid-run
@Test
func permissionsRevokedDuringObserveThrowsOrchestratorError() async throws {
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            // wait → triggers a second observe call → perception throws on call 2
            AgentAction(type: .wait, confidence: 0.9, requiresConfirmation: false, rationale: "Waiting"),
            AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done"),
        ], capture: SequencedPromptCapture()),
        perception: FailingAfterNthCallPerception(failOn: 2),
        visionFallback: FixedVision(),
        // Fast wait so the test doesn't block for 1s.
        executor: Executor(waitDuration: .milliseconds(1)),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )

    do {
        try await orchestrator.run(task: "Wait for the page to load")
        Issue.record("Expected OrchestratorError.permissionsRevoked to be thrown")
    } catch let error as OrchestratorError {
        #expect(error == .permissionsRevoked)
    }
}

// Unit 7 — perception throw must (a) write a throughline TaskRecord and
// (b) emit .failed BEFORE rethrowing. Pre-Unit-7, observe() throws
// bypassed all 18 throughline-record sites because each lived inside the
// loop's per-step branches; runs aborted via AX failure left no telemetry
// entry. The chokepoint catch in run() closes the gap for both Unit 5's
// new .agentIsFrontmost and the pre-existing .permissionsRevoked path
// (which is remapped to OrchestratorError.permissionsRevoked inside
// observe()).
private actor AgentFrontmostOnFirstCallPerception: AXPerceiving {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        throw AXPerceptionError.agentIsFrontmost(bundleID: "com.southernreach.macos-agent-v0")
    }
}

/// Final-pass-review regression: AX walk succeeds and returns the fallback
/// app's bundleID, but a subsequent vision merge throws. Used to verify
/// Unit 7's catch records the AX-walked bundleID (not "unknown") in the
/// throughline TaskRecord.
private actor AXSucceedsWithFallbackBundleIDPerception: AXPerceiving {
    let walkedBundleID: String
    init(walkedBundleID: String) { self.walkedBundleID = walkedBundleID }
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        // Return a snapshot with zero elements — this forces Orchestrator.observe()
        // into its vision-merge branch.
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: walkedBundleID,
            elements: [],
            agentIsOverlaid: true
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// Vision capture that always throws — combined with the perception above,
/// drives the "AX succeeds, vision throws" path through Unit 7's catch.
private struct ThrowingVision: VisionPerceiving {
    func captureVisualContext() async throws -> VisionCapture {
        throw VisionPerceptionError.noDisplay
    }
}

@Test
func axPerceptionThrow_writesThroughlineAndEmitsFailed() async throws {
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let throughlineURL = tmp.appendingPathComponent("throughline.json")
    let store = ThroughlineStore(fileURL: throughlineURL)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: AgentFrontmostOnFirstCallPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store,
        onEvent: { event in await collector.append(event) }
    )

    // Catch unconditionally so an unexpected error type surfaces as a test
    // failure rather than silently skipping the assertions below. Reviewer
    // flagged the prior `catch let error as AXPerceptionError` pattern as
    // vacuously-passing on unexpected error types.
    do {
        try await orchestrator.run(task: "Switch to Notes")
        Issue.record("Expected AXPerceptionError.agentIsFrontmost to be thrown; orchestrator returned normally.")
        return
    } catch let error as AXPerceptionError {
        guard case .agentIsFrontmost = error else {
            Issue.record("Expected .agentIsFrontmost; got \(error)")
            return
        }
    } catch {
        Issue.record("Expected AXPerceptionError, got \(type(of: error)): \(error)")
        return
    }

    // .failed must have been emitted with the AXPerceptionError's localized text.
    let failedEvents = await collector.allEvents().compactMap { event -> String? in
        if case .failed(let message) = event { return message }
        return nil
    }
    #expect(failedEvents.count == 1, "exactly one .failed event for the AX throw; got \(failedEvents.count)")
    #expect(failedEvents.first?.contains("com.southernreach.macos-agent-v0") == true,
            ".failed message must carry the AXPerceptionError.localizedDescription text")

    // Throughline TaskRecord must be present with outcome "error".
    let throughline = await store.load()
    #expect(throughline.taskHistory.count == 1,
            "exactly one TaskRecord written for the failed run; got \(throughline.taskHistory.count)")
    #expect(throughline.taskHistory.first?.outcome == "error",
            "TaskRecord outcome must be 'error' for a perception-throw failure")
    #expect(throughline.taskHistory.first?.task == "Switch to Notes")
}

// Parallel coverage: the pre-existing AXPerceptionError.permissionsRevoked
// path is also covered by Unit 7's catch — observe() remaps it to
// OrchestratorError.permissionsRevoked at line 690-692 before it reaches
// the catch, but the catch body is shared with `agentIsFrontmost`. Without
// this test, a future refactor that accidentally branched the catch on
// specific error types would silently skip the permissionsRevoked
// throughline-write without any test failure.
@Test
func permissionsRevoked_writesThroughlineAndEmitsFailed() async throws {
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: FailingAfterNthCallPerception(failOn: 1),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store,
        onEvent: { event in await collector.append(event) }
    )

    do {
        try await orchestrator.run(task: "Permission-denied task")
        Issue.record("Expected OrchestratorError.permissionsRevoked to be thrown; orchestrator returned normally.")
        return
    } catch let error as OrchestratorError {
        #expect(error == .permissionsRevoked)
    } catch {
        Issue.record("Expected OrchestratorError.permissionsRevoked, got \(type(of: error)): \(error)")
        return
    }

    let failedEvents = await collector.allEvents().compactMap { event -> String? in
        if case .failed(let message) = event { return message }
        return nil
    }
    #expect(failedEvents.count == 1,
            "exactly one .failed event for the permissionsRevoked throw; got \(failedEvents.count)")

    let throughline = await store.load()
    #expect(throughline.taskHistory.count == 1,
            "exactly one TaskRecord written for the permissionsRevoked run; got \(throughline.taskHistory.count)")
    #expect(throughline.taskHistory.first?.outcome == "error",
            "TaskRecord outcome must be 'error' for a permissions-revoked failure")
    #expect(throughline.taskHistory.first?.task == "Permission-denied task")
}

// Live-found 2026-06-15 (Track A live verification): with an AX-empty screen and
// Screen Recording NOT granted, the vision fallback's SCShareableContent capture
// threw and the WHOLE run hard-failed with a cryptic "declined TCCs for ...
// display capture" — contradicting the permissions banner's "Screen Recording
// optional" promise. observe() now catches a vision-capture failure, emits ONE
// clear warning, and proceeds on the AX-only snapshot. Safety is unaffected:
// every proposed action still runs through SafetyPolicy + the gate regardless of
// perception quality. This test pins the CORRECTED contract (it replaces the old
// axSuccessThenVisionThrow_throughlineKeepsAXBundleID, which asserted the run
// hard-failed): a vision-capture failure must NOT end the run, and the AX-walked
// bundleID is still recorded (stamped right after AX capture, before vision).
@Test
func axSuccessThenVisionFailure_degradesToAXOnlyInsteadOfFailing() async throws {
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: AXSucceedsWithFallbackBundleIDPerception(walkedBundleID: "com.apple.notes"),
        visionFallback: ThrowingVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store,
        onEvent: { event in await collector.append(event) }
    )

    // The run must NOT throw — a vision-capture failure is no longer fatal.
    try await orchestrator.run(task: "Switch to Notes")

    // Exactly one actionable "Vision unavailable" warning surfaced to the operator
    // (instead of a cryptic TCC crash).
    let visionWarnings = await collector.allEvents().compactMap { event -> String? in
        if case .warning(let message) = event, message.contains("Vision unavailable") { return message }
        return nil
    }
    #expect(visionWarnings.count == 1, "exactly one vision-degraded warning; got \(visionWarnings.count)")

    // No .failed event — the run completed despite vision being unavailable.
    let failed = await collector.allEvents().contains { if case .failed = $0 { return true }; return false }
    #expect(!failed, "vision-capture failure must not produce a .failed event anymore")

    // Throughline still records the AX-walked bundleID, and outcome is NOT an error.
    let throughline = await store.load()
    #expect(throughline.taskHistory.count == 1, "expected exactly one TaskRecord")
    #expect(throughline.taskHistory.first?.appBundleID == "com.apple.notes",
            "appBundleID must still reflect the AX-walked app.")
    #expect(throughline.taskHistory.first?.outcome != "error",
            "vision-capture failure must no longer be recorded as a run-ending error.")
}

// Track A adversarial-review follow-up: the vision-unavailable warning must fire
// at MOST once per run, not once per observe(). An AX-poor app (empty elements
// every step) with Screen Recording denied hits the failed vision branch on
// every loop iteration; without the per-run dedup flag this would emit N
// identical warnings and flood the conversation. Two-step run → exactly one.
@Test
func visionUnavailable_warnsOnceAcrossMultipleDegradedSteps() async throws {
    let collector = IntegrationEventCollector()
    let capture = SequencedPromptCapture()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .wait, confidence: 0.9, requiresConfirmation: false, rationale: "pause", durationMs: 1),
            AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done"),
        ], capture: capture),
        perception: AXSucceedsWithFallbackBundleIDPerception(walkedBundleID: "com.apple.notes"),
        visionFallback: ThrowingVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )

    try await orchestrator.run(task: "Two-step task on an AX-poor screen")

    let visionWarnings = await collector.allEvents().compactMap { event -> String? in
        if case .warning(let message) = event, message.contains("Vision unavailable") { return message }
        return nil
    }
    #expect(visionWarnings.count == 1,
            "vision-unavailable warning must be emitted exactly once per run across multiple degraded observes; got \(visionWarnings.count)")
}

// H — Fatal LLM error (missingAPIKey) emits .failed immediately with no recovery
@Test
func fatalLLMErrorInThinkEmitsFailedImmediately() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: ThrowingLLM(error: LLMError.missingAPIKey),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )

    do {
        try await orchestrator.run(task: "Summarise this page")
        Issue.record("Expected OrchestratorError.apiKeyMissing to be thrown")
    } catch let error as OrchestratorError {
        #expect(error == .apiKeyMissing)
    }
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("ANTHROPIC_API_KEY") }
        return false
    }, ".failed must surface the missing-key message from LLMError")
    #expect(!(await collector.contains { if case .recovering = $0 { return true }; return false }),
            "Fatal LLM error must not trigger recovery")
}

// T — immediate complete on step 1 rejected via confirm gate
@Test
func immediateCompleteOnStep1RejectedEmitsFailed() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { RejectingOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ThroughlineStore(fileURL: tmp.appendingPathComponent("throughline.json"))
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .complete, confidence: 0.9, requiresConfirmation: false, rationale: "Done")),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: store,
        onEvent: { event in await collector.append(event) }
    )

    // Does not throw — the orchestrator emits .failed and breaks the loop.
    try await orchestrator.run(task: "Is the task done?")

    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Immediate completion signal rejected") }
        return false
    }, ".failed with rejection message must be emitted")

    try await Task.sleep(for: .milliseconds(100))
    let saved = await store.load()
    #expect(saved.taskHistory.first?.outcome == "rejected", "Throughline must record outcome as rejected")
}

// I — DecodingError in think retries up to budget, then emits .failed
@Test
func decodingErrorInThinkRetriesThenFails() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let decodingError = DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [], debugDescription: "synthetic test error", underlyingError: nil)
    )
    let orchestrator = Orchestrator(
        llm: ThrowingLLM(error: decodingError),
        perception: FixedPerception(),
        visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )

    var threw = false
    do {
        try await orchestrator.run(task: "Click Submit")
    } catch {
        threw = true
    }
    #expect(threw, "Must throw after think recovery budget exhausted")
    let recoveringCount = await collector.count { if case .recovering = $0 { return true }; return false }
    #expect(recoveringCount == 3, "Must emit exactly 3 .recovering events (maxThinkRecoverySteps)")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("retries") }
        return false
    }, ".failed with retry exhaustion message must be emitted")
}

// MARK: - Partial run recovery

// J — Executor failure triggers recovery pass; run completes after LLM emits undo then complete
@Test
func executorFailureTriggerRecoveryAndRunCompletes() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    // step 1 click succeeds, step 2 click fails (triggers recovery), step 3 undo succeeds, step 4 complete
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9, requiresConfirmation: false, rationale: "click"),
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9, requiresConfirmation: false, rationale: "retry click"),
        AgentAction(type: .undo, confidence: 1.0, requiresConfirmation: false, rationale: "undo last action"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let executor = FailingAfterNthCallExecutor(failOn: 2, thenSucceed: true)
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "Test recovery success")
    try await Task.sleep(for: .milliseconds(100))
    #expect(await collector.contains { if case .recovering = $0 { return true }; return false },
            "Recovery event must be emitted on executor failure")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete successfully after recovery")
    #expect(!(await collector.contains { if case .failed = $0 { return true }; return false }),
            "No .failed event when recovery succeeds")
}

// K — Recovery budget exhaustion: 3 recovery passes then .failed emitted and error thrown
@Test
func recoveryBudgetExhaustedEmitsFailed() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = FixedLLM(action: AgentAction(
        type: .click, targetIndex: 0, confidence: 0.9,
        requiresConfirmation: false, rationale: "click"))
    let executor = FailingAfterNthCallExecutor(failOn: 1, thenSucceed: false)
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) }
    )
    var caughtError: Error?
    do { try await orchestrator.run(task: "Test budget exhaustion") } catch { caughtError = error }
    try await Task.sleep(for: .milliseconds(100))
    let events = await collector.events
    let recoveringCount = events.filter { if case .recovering = $0 { return true }; return false }.count
    #expect(caughtError != nil, "Run must throw after recovery budget exhausted")
    #expect(recoveringCount == 3, "Must attempt exactly maxRecoverySteps (3) recovery passes")
    #expect(await collector.contains { if case .failed = $0 { return true }; return false },
            ".failed must be emitted after budget exhaustion")
}

// Unit 14 — when the executor throws `.targetStale`, the recovery prompt
// injected into conversationHistory must carry the SPECIFIC index, label,
// and elementCount hints. The generic "the last action failed" prompt is
// not enough — receipts show the LLM re-picks the same dead index across
// fresh snapshots without the specific hint.

private actor TargetStaleExecutor: ActionPerforming {
    private var callCount = 0
    let staleAfter: Int
    init(staleAfter: Int = 1) { self.staleAfter = staleAfter }
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        callCount += 1
        if callCount == staleAfter {
            throw ExecutorError.targetStale(
                actionType: .click,
                requestedIndex: 216,
                elementCount: 42,
                lastKnownLabel: "Search field"
            )
        }
        return "ok"
    }
}

private actor RecoveryHistoryCaptureLLM: ActionThinking {
    private let actions: [AgentAction]
    private var index = 0
    var seenHistories: [[LLMMessage]] = []
    init(actions: [AgentAction]) { self.actions = actions }
    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        seenHistories.append(history)
        defer { index += 1 }
        return actions[min(index, actions.count - 1)]
    }
}

@Test
func targetStaleRecoveryPromptCarriesIndexLabelAndElementCount() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = RecoveryHistoryCaptureLLM(actions: [
        // Step 1 click → executor throws .targetStale → recovery message injected
        AgentAction(type: .click, targetIndex: 216, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click stale idx"),
        // Step 2 (after recovery): different action so the loop can complete
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done after recovery"),
    ])
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: TargetStaleExecutor(staleAfter: 1), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json"))
    )
    try await orchestrator.run(task: "Test stale-target recovery prompt")

    let histories = await llm.seenHistories
    #expect(histories.count >= 2, "expected at least 2 nextAction calls (original + recovery)")
    // The SECOND nextAction call sees the recovery message in its history
    // (the orchestrator appended it before continuing the loop). Filter to
    // role=="user" so the assertion can't be satisfied by an LLM-mock
    // rationale that happens to contain the same phrases — the recovery
    // injection is a user-role message and must stand on its own.
    let recoveryUserMessages = histories[1].filter { $0.role == "user" }.map(\.content).joined(separator: "|")
    #expect(recoveryUserMessages.contains("216"),
            "recovery prompt must name the dead index (LLM was re-picking 216 across fresh snapshots in 2026-05-23 receipts)")
    #expect(recoveryUserMessages.contains("Search field"),
            "recovery prompt must name the labelled element so the LLM has a concrete reference for what to NOT re-pick")
    #expect(recoveryUserMessages.contains("42"),
            "recovery prompt must name the current element count so the LLM knows the snapshot has changed")
    #expect(recoveryUserMessages.contains("Do NOT retry"),
            "recovery prompt must instruct the LLM not to re-pick the dead index (exact canonical phrase)")
    #expect(recoveryUserMessages.contains("only to the immediately following observation"),
            "recovery prompt must scope the prohibition to the NEXT snapshot only — UI reflow can reassign index N to a different element later")
}

// Unit 18B — disabled-element recovery prompt symmetric to Unit 14's
// stale-target prompt. The recovery message must name the disabled
// element AND tell the LLM that re-observing alone won't help (it'll
// still be disabled) — the LLM needs to satisfy the enabling
// condition OR pick a different element.

private actor TargetDisabledExecutor: ActionPerforming {
    private var callCount = 0
    let disabledAfter: Int
    init(disabledAfter: Int = 1) { self.disabledAfter = disabledAfter }
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        callCount += 1
        if callCount == disabledAfter {
            throw ExecutorError.targetDisabled(
                actionType: .click,
                requestedIndex: 7,
                label: "Submit"
            )
        }
        return "ok"
    }
}

@Test
func targetDisabledRecoveryPromptCarriesLabelAndEnablingConditionHint() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = RecoveryHistoryCaptureLLM(actions: [
        AgentAction(type: .click, targetIndex: 7, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click disabled Submit"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ])
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: TargetDisabledExecutor(disabledAfter: 1), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json"))
    )
    try await orchestrator.run(task: "Test disabled-element recovery prompt")
    let histories = await llm.seenHistories
    #expect(histories.count >= 2, "expected at least 2 nextAction calls (original + recovery)")
    // Filter to role=="user" so an assistant rationale containing the
    // same words can't satisfy the assertion vacuously.
    let recoveryUserMessages = histories[1].filter { $0.role == "user" }.map(\.content).joined(separator: "|")
    #expect(recoveryUserMessages.contains("disabled"),
            "Recovery prompt must say 'disabled' so the LLM knows the failure class")
    #expect(recoveryUserMessages.contains("Submit"),
            "Recovery prompt must name the disabled element's label so the LLM has a concrete reference")
    #expect(recoveryUserMessages.contains("satisfy") || recoveryUserMessages.contains("precondition")
                || recoveryUserMessages.contains("required field"),
            "Recovery prompt must hint at the enabling-condition strategy — re-observing alone won't help")
    // Negative: the stale-specific phrasing must NOT appear (those are
    // different failure classes with different recovery strategies).
    #expect(!recoveryUserMessages.contains("no longer in the snapshot"),
            "Disabled-element prompt must NOT reuse stale-target phrasing")
}

@Test
func nonStaleErrorUsesGenericRecoveryPrompt() async throws {
    // Regression guard: a non-stale executor error (e.g. executionFailed)
    // must still use the original generic recovery prompt, not the
    // stale-target-specific one.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = RecoveryHistoryCaptureLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "first click fails"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ])
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: FailingAfterNthCallExecutor(failOn: 1, thenSucceed: true),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json"))
    )
    try await orchestrator.run(task: "Test generic recovery prompt")

    let histories = await llm.seenHistories
    #expect(histories.count >= 2)
    let recoveryHistory = histories[1]
    let allText = recoveryHistory.map(\.content).joined(separator: "|")
    #expect(allText.contains("Use 'undo'") || allText.contains("try a different approach"),
            "non-stale errors must still use the original recovery prompt (undo hint)")
    // Negative: the stale-specific text must NOT appear.
    #expect(!allText.contains("snapshot now has"),
            "generic recovery prompt must not contain stale-target-specific phrasing")
}

// Reviewer-caught Sev-2 (Unit 18B): symmetric to
// `nonStaleErrorUsesGenericRecoveryPrompt` but inverted — guards
// that `.targetStale` doesn't accidentally trigger the disabled-
// specific prompt phrasing. The recovery branch is now a three-arm
// chain; without this test a future edit that conflates the stale
// arm with the disabled arm would silently pass all existing tests.
@Test
func staleErrorDoesNotUseDisabledRecoveryPrompt() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = RecoveryHistoryCaptureLLM(actions: [
        AgentAction(type: .click, targetIndex: 216, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click stale idx"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ])
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: TargetStaleExecutor(staleAfter: 1), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json"))
    )
    try await orchestrator.run(task: "stale-not-disabled regression guard")
    let histories = await llm.seenHistories
    let recoveryUserMessages = histories[1].filter { $0.role == "user" }.map(\.content).joined(separator: "|")
    // Positive: stale-specific phrasing IS present. Use a substring
    // that's stable across minor phrasing tweaks ("the snapshot" /
    // "the current snapshot" both qualify).
    #expect(recoveryUserMessages.contains("no longer in"),
            "stale recovery prompt MUST contain its canonical 'no longer in [the] snapshot' phrasing")
    // Negative: disabled-specific phrasing must NOT appear. Catches a
    // future edit that conflates the two error cases in the recovery
    // chain (e.g. accidentally extending the .targetDisabled case to
    // also match .targetStale).
    #expect(!recoveryUserMessages.contains("YET DISABLED"),
            "stale recovery prompt must not contain disabled-specific phrasing")
    #expect(!recoveryUserMessages.contains("enabling condition"),
            "stale recovery prompt must not mention enabling conditions — that's the disabled arm")
}

// MARK: - Multi-app orchestration (switchApp)

// L — switchApp action executes without error and run completes
@Test
func switchAppActionRunsToCompletion() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Notes",
                    confidence: 0.95, requiresConfirmation: false, rationale: "switch to Notes"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) },
        runningAppsProvider: {
            [RunningApp(bundleID: "com.apple.Safari", name: "Safari"),
             RunningApp(bundleID: "com.apple.Notes", name: "Notes")]
        }
    )
    try await orchestrator.run(task: "Copy from Safari to Notes")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete successfully after switchApp")
    #expect(!(await collector.contains { if case .failed = $0 { return true }; return false }),
            "No .failed event when switchApp succeeds")
}

// M — switchApp with unknown bundle ID triggers recovery
@Test
func switchAppUnknownBundleIDTriggersRecovery() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    // Unit 27 — varied targets per iteration. The previous fixture used
    // FixedLLM with a single repeated bundle ID, which now trips the
    // new H.6 sameSwitchAppLoop detector (correctly — that's the
    // defensive re-emission pattern). To preserve the original intent
    // of exercising the recovery-budget-exhaustion path on repeated
    // switchApp failures, the LLM now varies the target each call so
    // H.6's same-target counter never increments beyond 1.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.fake.A", confidence: 0.9,
                    requiresConfirmation: false, rationale: "first attempt"),
        AgentAction(type: .switchApp, text: "com.fake.B", confidence: 0.9,
                    requiresConfirmation: false, rationale: "second attempt"),
        AgentAction(type: .switchApp, text: "com.fake.C", confidence: 0.9,
                    requiresConfirmation: false, rationale: "third attempt"),
        AgentAction(type: .switchApp, text: "com.fake.D", confidence: 0.9,
                    requiresConfirmation: false, rationale: "fourth attempt"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: RejectingSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) }
    )
    var threw = false
    do { try await orchestrator.run(task: "Switch to fake app") } catch { threw = true }
    #expect(threw, "Must throw after recovery budget exhausted")
    #expect(await collector.contains { if case .recovering = $0 { return true }; return false },
            "Recovery must fire on switchApp failure")
    #expect(await collector.contains { if case .failed = $0 { return true }; return false },
            ".failed must be emitted after budget exhaustion")
}

// N — running apps list is passed to the LLM on each call
@Test
func runningAppsArePassedToLLM() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let capturingLLM = RunningAppCapturingLLM()
    let orchestrator = Orchestrator(
        llm: capturingLLM, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { _ in },
        runningAppsProvider: {
            [RunningApp(bundleID: "com.apple.TextEdit", name: "TextEdit")]
        }
    )
    try await orchestrator.run(task: "Verify running apps injection")
    let captured = await capturingLLM.capturedRunningApps
    #expect(!captured.isEmpty, "LLM must be called at least once")
    #expect(captured.contains { $0.contains(where: { $0.bundleID == "com.apple.TextEdit" }) },
            "Running apps must be passed to LLM on every call")
}

// O — switchApp succeeds even when the running apps list is empty (cold-launch path uses StubExecutor)
@Test
func switchAppSucceedsEvenWhenRunningAppsListIsEmpty() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Notes",
                    confidence: 0.95, requiresConfirmation: false, rationale: "launch Notes"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) },
        runningAppsProvider: { [] }   // app not in list — simulates cold launch
    )
    try await orchestrator.run(task: "Open Notes")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete when switchApp succeeds on a non-listed app")
    #expect(!(await collector.contains { if case .failed = $0 { return true }; return false }),
            "No .failed event expected")
}

// P — runningAppsProvider is called fresh on each step (dynamic list)
@Test
func runningAppsProviderCalledFreshEachStep() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    // Two-step LLM: step 1 switchApp (captures first provider call), step 2 complete.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Notes",
                    confidence: 0.95, requiresConfirmation: false, rationale: "switch"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    // Use @unchecked Sendable box so the counter is safe to capture in the @Sendable closure.
    // The Orchestrator actor calls the provider serially — no actual data race.
    let counter = CallCounter()
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { _ in },
        runningAppsProvider: {
            counter.increment()
            return counter.value == 1
                ? [RunningApp(bundleID: "com.apple.TextEdit", name: "TextEdit")]
                : [RunningApp(bundleID: "com.apple.Notes", name: "Notes")]
        }
    )
    try await orchestrator.run(task: "Verify fresh provider")
    // Provider must have been called at least twice (once per LLM step).
    #expect(counter.value >= 2, "runningAppsProvider must be called fresh on each step")
}

/// Counter box for capturing in @Sendable closures from the orchestrator actor.
/// @unchecked Sendable is safe here because the Orchestrator calls the provider serially.
private final class CallCounter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - Private mock types (recovery)

private actor FailingAfterNthCallExecutor: ActionPerforming {
    private var callCount = 0
    let failOn: Int
    let thenSucceed: Bool

    init(failOn: Int, thenSucceed: Bool = true) {
        self.failOn = failOn
        self.thenSucceed = thenSucceed
    }

    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        callCount += 1
        let shouldFail = thenSucceed ? callCount == failOn : callCount >= failOn
        if shouldFail {
            throw ExecutorError.executionFailed("Simulated failure on call \(callCount)")
        }
        return "ok"
    }
}

// MARK: - Private mock types (switchApp)

/// Executor that handles switchApp by returning success without real AppKit calls.
private actor StubSwitchAppExecutor: ActionPerforming {
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        if action.type == .switchApp {
            return "switched to \(action.text ?? "unknown")"
        }
        return "ok"
    }
}

/// Executor that rejects switchApp (simulates app not running).
private struct RejectingSwitchAppExecutor: ActionPerforming, Sendable {
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        if action.type == .switchApp {
            throw ExecutorError.executionFailed(
                "No running application with bundle ID: \(action.text ?? "")")
        }
        return "ok"
    }
}

/// LLM that captures the runningApps passed on each call, then always returns complete.
private actor RunningAppCapturingLLM: ActionThinking {
    private(set) var capturedRunningApps: [[RunningApp]] = []

    func nextAction(
        task: String, snapshot: PerceptionSnapshot,
        history: [LLMMessage], runningApps: [RunningApp]
    ) async throws -> AgentAction {
        capturedRunningApps.append(runningApps)
        return AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done")
    }
}

// MARK: - Phase 7: think() recovery tests

// Q — fatal LLM error (missingAPIKey) hard-stops immediately, no recovery
@Test
func missingAPIKeyEmitsFailedImmediatelyWithNoRecovery() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: ThrowingLLM(error: LLMError.missingAPIKey),
        perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    var threw = false
    do { try await orchestrator.run(task: "test") } catch { threw = true }
    #expect(threw, "Must throw on fatal LLM error")
    #expect(await collector.contains { if case .failed = $0 { return true }; return false },
            ".failed must be emitted")
    #expect(await collector.count { if case .recovering = $0 { return true }; return false } == 0,
            "Fatal error must not trigger any recovery")
}

// R — transient LLM error recovers on retry; run completes
@Test
func transientLLMErrorRecoverySucceeds() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Fails on first call with a transient error, then succeeds with .complete.
    let llm = FailingAfterNthCallLLM(
        failOn: 1,
        error: LLMError.rateLimited,
        thenAction: AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done")
    )
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "test")
    #expect(await collector.contains { if case .recovering = $0 { return true }; return false },
            ".recovering must be emitted on transient failure")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete after recovery")
    #expect(!(await collector.contains { if case .failed = $0 { return true }; return false }),
            "No .failed when recovery succeeds")
}

// S — transient LLM error exhausts budget; .failed emitted
@Test
func transientLLMErrorBudgetExhaustedEmitsFailed() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: ThrowingLLM(error: LLMError.rateLimited),   // always fails
        perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    var threw = false
    do { try await orchestrator.run(task: "test") } catch { threw = true }
    #expect(threw, "Must throw after budget exhaustion")
    #expect(await collector.count { if case .recovering = $0 { return true }; return false } == 3,
            "Must emit 3 .recovering events before giving up")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("retries") }
        return false
    }, ".failed with retry count must be emitted")
}

// U — DecodingError retries then succeeds
@Test
func decodingErrorRetriesThenSucceeds() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let decodingError = DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [], debugDescription: "synthetic", underlyingError: nil)
    )
    let llm = FailingAfterNthCallLLM(
        failOn: 1,
        error: decodingError,
        thenAction: AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done")
    )
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "test")
    #expect(await collector.contains { if case .recovering = $0 { return true }; return false },
            ".recovering must fire on DecodingError")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete after DecodingError recovery")
}

// W — think() and act() recovery counters are independent
@Test
func thinkAndActRecoveryCountersAreIndependent() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // LLM: fails transiently on step 1, then returns a click action, then .complete.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0,
                    confidence: 0.9, requiresConfirmation: false, rationale: "click"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    // Executor: fails once on step 1 (click), then succeeds.
    let executor = FailingAfterNthCallExecutor(failOn: 1, thenSucceed: true)
    // Wrap the sequenced LLM so the first call throws a transient LLM error.
    let wrappedLLM = PrefixFailingLLM(
        failCount: 1, error: LLMError.rateLimited, inner: llm)
    let orchestrator = Orchestrator(
        llm: wrappedLLM, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "test")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete: neither think nor act budget exhausted")
    let recoveringCount = await collector.count { if case .recovering = $0 { return true }; return false }
    #expect(recoveringCount == 2, "One think recovery + one act recovery = 2 .recovering events")
}

// MARK: - Phase 10: Loop mechanic tests

// AA — step budget exhausted emits .stepLimitReached
@Test
func stepBudgetExhaustedEmitsStepLimitReached() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // FixedLLM returning .scroll: AUTO tier, executes cleanly, never completes on its own.
    // 3 steps execute before the budget check fires on step 4's loop entry.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .scroll, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "scroll")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        maxSteps: 3,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "scroll forever")
    #expect(await collector.contains { if case .stepLimitReached(let n) = $0 { return n == 3 }; return false },
            ".stepLimitReached(stepCount: 3) must be emitted when maxSteps is 3")
    #expect(!(await collector.contains { if case .finished = $0 { return true }; return false }),
            "Run must not emit .finished when step limit is hit")
}

// AB — 90% step budget warning fires at the correct step
@Test
func stepBudgetWarningAt90Percent() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // maxSteps=10 → warningStep = Int(10 * 0.9) = 9 → warning emitted on step 9's loop entry.
    // Using .undo: AUTO tier, no stall counter (wait/scroll stalls don't track undo), so the
    // loop runs all 10 steps cleanly and the step limit fires on step 11's entry.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .undo, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "undo")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        maxSteps: 10,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "scroll")
    #expect(await collector.contains {
        // 34a — routed via .warning so it can't fold into the simple
        // interface's collapsed activity groups (it exists for operator
        // intervention before the abrupt stop).
        if case .warning(let r) = $0 { return r.contains("⚠️ Approaching step limit") }
        return false
    }, "90% step budget warning must be emitted before step limit")
    #expect(await collector.contains { if case .stepLimitReached = $0 { return true }; return false },
            ".stepLimitReached must follow the warning")
}

// AC — 10 consecutive waits triggers stall clarification
@Test
func waitStallDetectionBreaksLoop() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Real Executor with 1ms waitDuration: Task.sleep only throws CancellationError, which
    // nothing injects here, so the real code path is exercised without risk of false failure.
    // After 10 consecutive .wait executions consecutiveWaits reaches the stall threshold.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .wait, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "wait")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: Executor(waitDuration: .milliseconds(1)), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "wait forever")
    // Unit 30 — the detector self-recovers twice (hint injected, run
    // continues) and the third firing is an honest terminal .failed.
    // No .clarificationRequested: the old emit-then-break lied about a
    // reply channel that was never armed.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("wait") && msg.contains("self-recovering, attempt 1") }
        return false
    }, "First wait-stall firing must self-recover with a .warning")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Stalled (wait)") }
        return false
    }, "Third wait-stall firing must terminate with an honest .failed")
    #expect(!(await collector.contains { if case .finished = $0 { return true }; return false }),
            "Run must not finish normally — terminal stall stops the run")
    #expect(!(await collector.contains { if case .clarificationRequested = $0 { return true }; return false }),
            "Stall detectors must NOT emit .clarificationRequested — that channel is only for genuine .clarify actions")
}

// AD — 10 consecutive scrolls triggers stall clarification
@Test
func scrollStallDetectionBreaksLoop() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Stub executor intentional: CGEvent(scrollWheelEvent2Source:) returns nil in headless/CI
    // environments with no display, which would throw and trigger the recovery path instead of
    // incrementing consecutiveScrolls — making the stall unreachable and the test unreliable.
    // The stall counter logic (not CGEvent) is what this test covers.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .scroll, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "scroll")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "scroll forever")
    // Unit 30 — recovery twice, then honest terminal.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("scroll") && msg.contains("self-recovering") }
        return false
    }, "Scroll stall must self-recover with a .warning before terminating")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Stalled (scroll)") }
        return false
    }, "Scroll stall terminal firing must emit an honest .failed")
}

// AE — 10 consecutive same-target clicks detected pre-gate, breaks loop
@Test
func sameTargetClickStallDetectedPreGate() async throws {
    let collector = IntegrationEventCollector()
    // IntegrationOverlay auto-approves — but stall fires PRE-gate on the 10th proposal,
    // so the gate is never reached for that step.
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // FixedPerception provides one element at index 0. FixedLLM always clicks it.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "click same")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "click same target")
    // Unit 30 — two self-recoveries (attempt 1 and 2) then honest terminal.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("sameTargetClick") && msg.contains("attempt 1") }
        return false
    }, "First same-target stall firing must self-recover")
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("sameTargetClick") && msg.contains("attempt 2") }
        return false
    }, "Second same-target stall firing must self-recover")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Stalled (sameTargetClick)") }
        return false
    }, "Third same-target stall firing must terminate with .failed")
}

// Unit 17 / Path F: H.5a — 4 same-keyCombo emissions (interleaved with
// typeText/wait) triggers stall clarification. Dogfood evidence
// (2026-05-27) showed the LLM emit `cmd+space` 5 times in 12 actions
// for "Open Notes", interleaved with typeText/wait, no detector fired.

@Test
func sameKeyComboStallDetectedAcrossInterleavedActions() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Sequence mirrors the dogfood pattern: cmd+space, typeText, wait,
    // cmd+space, typeText, wait, cmd+space, typeText, cmd+space —
    // 4 cmd+space's interleaved should fire H.5a at the 4th, before
    // the 5th can land.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "open Spotlight"),
        AgentAction(type: .typeText, text: "Notes", confidence: 0.9,
                    requiresConfirmation: false, rationale: "type query"),
        AgentAction(type: .wait, confidence: 0.9,
                    requiresConfirmation: false, rationale: "wait for results"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "reopen Spotlight"),
        AgentAction(type: .typeText, text: "Notes", confidence: 0.9,
                    requiresConfirmation: false, rationale: "type again"),
        AgentAction(type: .wait, confidence: 0.9,
                    requiresConfirmation: false, rationale: "wait again"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "reopen Spotlight 3"),
        AgentAction(type: .typeText, text: "Notes", confidence: 0.9,
                    requiresConfirmation: false, rationale: "type 3"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "reopen Spotlight 4 — should trip H.5a"),
        // Sentinel — should never be reached if stall fires.
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "should not reach"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "open notes")
    // Unit 30 — the firing is a self-recovery: hint injected, run
    // continues, and the NEXT proposal (the sentinel .complete) finishes
    // the run. The hint still names the combo + the switchApp fix.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("sameRiskyKeyCombo") }
        return false
    }, "H.5a firing must surface as a self-recovery .warning")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Run continues after self-recovery and finishes via the sentinel .complete")
    // Pin the EXACT firing step. H.5a runs PRE-gate, before `.proposed`
    // emits. On the 4th cmd+space the counter hits 4 and the stall
    // suppresses that proposal (the action is skipped, the LLM re-thinks).
    // So .proposed for cmd+space appears exactly 3 times.
    let proposedCmdSpaceCount = await collector.events.filter { e in
        if case .proposed(let a, _) = e, a.type == .keyCombo, a.text == "cmd+space" {
            return true
        }
        return false
    }.count
    #expect(proposedCmdSpaceCount == 3,
            "H.5a must fire on the 4th cmd+space proposal, suppressing its .proposed emission. Got \(proposedCmdSpaceCount) .proposed events for cmd+space.")
}

// Chain review — pin the terminal budget-exhaustion contract for H.5a
// (the sentinel-mock test above only covers the recovery firing).
@Test
func sameKeyComboStall_terminalAfterBudgetExhaustion() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    // FixedLLM repeats cmd+space forever: firings at 4/8/12 → 2 recoveries + terminal.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                                           requiresConfirmation: false, rationale: "spotlight forever")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "h5a terminal contract")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Stalled (sameRiskyKeyCombo)") }
        return false
    }, "Third H.5a firing must terminate with an honest .failed")
    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.filter { $0.executionResult == "stalled-sameRiskyKeyCombo" }.count == 3,
            "H.5a must receipt all three firings (two recoveries + terminal)")
}

// Chain review — same terminal pin for H.6 (threshold 2 → firings at 2/4/6).
@Test
func sameSwitchAppLoopStall_terminalAfterBudgetExhaustion() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                                           requiresConfirmation: false, rationale: "defensive loop forever")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "h6 terminal contract")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("Stalled (sameSwitchAppLoop)") }
        return false
    }, "Third H.6 firing must terminate with an honest .failed")
    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.filter { $0.executionResult == "stalled-sameSwitchAppLoop" }.count == 3,
            "H.6 must receipt all three firings (two recoveries + terminal)")
}

@Test
func sameKeyComboCounterResetsOnDifferentCombo() async throws {
    // 3× cmd+space then 1× cmd+l (different combo) — must NOT stall.
    // After cmd+l, 2× cmd+space again — still must NOT stall (counter
    // reset on the different combo means cmd+space count is 2, < 4).
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "2"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "3"),
        AgentAction(type: .keyCombo, text: "cmd+l", confidence: 0.9,
                    requiresConfirmation: false, rationale: "different — reset"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1 again"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "2 again"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done — should be reached"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "interleaved combos")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Run must reach .complete — H.5a must NOT fire when a different combo breaks the same-text streak")
}

@Test
func sameKeyComboCounterResetsOnClick() async throws {
    // 3× cmd+space then 1× click — must NOT stall. Click is a
    // non-{keyCombo,typeText,wait} action, so it resets the counter.
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "2"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "3"),
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click — resets counter"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1 again"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "click resets stall")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Click resets the keyCombo stall counter; run must complete normally")
}

// MARK: - Unit 27 / H.6 — same-target switchApp loop stall

// H.6 fires on the 2nd consecutive switchApp emission to the same
// bundle ID. Threshold 2 — more aggressive than H.5a's 4 because the
// defensive re-emission pattern is back-to-back with no intermediates.
@Test
func sameSwitchAppLoopStallFiresOnSecondConsecutiveSameTarget() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "first switchApp"),
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "defensive re-emit — should trip H.6"),
        // Unit 30 — after the self-recovery hint the run continues; the
        // sentinel completes it so the test ends deterministically.
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "post-recovery sentinel"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "switch to Safari (defensive re-emission test)")
    // Unit 30 — the firing self-recovers (hint names target + signature),
    // the 2nd switchApp proposal is suppressed, and the run finishes via
    // the sentinel .complete.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("sameSwitchAppLoop") }
        return false
    }, "H.6 firing must surface as a self-recovery .warning")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Run continues after self-recovery and finishes via the sentinel .complete")
    // The suppressed 2nd switchApp never reached .proposed.
    let proposedSwitchCount = await collector.events.filter { e in
        if case .proposed(let a, _) = e, a.type == .switchApp { return true }
        return false
    }.count
    #expect(proposedSwitchCount == 1,
            "H.6 fires on the 2nd consecutive same-target switchApp, suppressing its .proposed. Got \(proposedSwitchCount).")
}

@Test
func sameSwitchAppCounterResetsOnDifferentTarget() async throws {
    // switchApp A → switchApp B → switchApp A → complete.
    // B resets the counter; A starts fresh at 1. No stall, run completes.
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1: Safari"),
        AgentAction(type: .switchApp, text: "com.apple.Notes", confidence: 0.9,
                    requiresConfirmation: false, rationale: "2: Notes — resets counter"),
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "3: Safari again — counter at 1, no stall"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "varied targets — no defensive loop")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Varied switchApp targets must NOT trip H.6 — different bundle ID resets the counter")
}

@Test
func sameSwitchAppCounterResetsOnNonSwitchAppAction() async throws {
    // switchApp A → click → switchApp A → complete.
    // Click is a non-switchApp action so the counter resets between the
    // two A's. Realistic cross-app workflow: switch to app, interact,
    // come back later.
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "1: switch to Safari"),
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "interaction — resets counter"),
        AgentAction(type: .switchApp, text: "com.apple.Safari", confidence: 0.9,
                    requiresConfirmation: false, rationale: "2: switch back to Safari — counter at 1"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "cross-app workflow — A then interact then back to A")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Non-switchApp intermediate action must reset the H.6 counter — legit cross-app workflow must complete")
}

// MARK: - Unit 22 / H.5b — no-progress window stall

@Test
func noProgressWindow_firesAfterTwelveNonProgressActions() async throws {
    // 12 consecutive typeText actions with no click/menuSelect/etc.
    // → H.5b must stall on the 12th. Sentinel .complete after the
    // 12th must never be reached.
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var actions: [AgentAction] = (0..<13).map { i in
        AgentAction(type: .typeText, text: "fill\(i)", confidence: 0.9,
                    requiresConfirmation: false, rationale: "typeText #\(i)")
    }
    actions.append(AgentAction(type: .complete, confidence: 1.0,
                               requiresConfirmation: false, rationale: "should not reach"))
    let llm = SequencedLLM(actions: actions, capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "no-progress stall test")
    // Unit 30 — the firing self-recovers; the run continues to the
    // sentinel .complete. The recovery warning names the detector.
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("noProgressWindow") }
        return false
    }, "H.5b firing must surface as a self-recovery .warning")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Run continues after self-recovery and reaches the sentinel .complete")
}

@Test
func noProgressWindow_resetsOnClick() async throws {
    // 11 typeText (counter at 11) → 1 click (counter back to 0) →
    // 11 more typeText (counter at 11) → complete (terminates).
    // Total non-progress actions = 22 (would trip H.5b twice over)
    // but the click in the middle resets, so neither window reaches
    // 12. Run must complete normally.
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    var actions: [AgentAction] = (0..<11).map { i in
        AgentAction(type: .typeText, text: "pre\(i)", confidence: 0.9,
                    requiresConfirmation: false, rationale: "pre-click \(i)")
    }
    actions.append(AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                               requiresConfirmation: false, rationale: "progress click"))
    actions.append(contentsOf: (0..<11).map { i in
        AgentAction(type: .typeText, text: "post\(i)", confidence: 0.9,
                    requiresConfirmation: false, rationale: "post-click \(i)")
    })
    actions.append(AgentAction(type: .complete, confidence: 1.0,
                               requiresConfirmation: false, rationale: "done"))
    let llm = SequencedLLM(actions: actions, capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "click resets H.5b")
    #expect(await collector.contains {
        if case .finished = $0 { return true }
        return false
    }, "Click between two 11-action runs resets H.5b counter; run must reach .complete")
}

@Test
func noProgressWindow_progressMakingActionTypes_correctlyClassified() {
    // Pin the progress-list shape. If a future contributor adds a new
    // ActionType, the switch in isProgressMakingAction must explicitly
    // handle it — Swift's exhaustive switch enforces that.
    #expect(Orchestrator.isProgressMakingAction(.click))
    #expect(Orchestrator.isProgressMakingAction(.doubleClick))
    #expect(Orchestrator.isProgressMakingAction(.tripleClick))
    #expect(Orchestrator.isProgressMakingAction(.rightClick))
    #expect(Orchestrator.isProgressMakingAction(.menuSelect))
    #expect(Orchestrator.isProgressMakingAction(.switchApp))
    #expect(Orchestrator.isProgressMakingAction(.drag))
    #expect(Orchestrator.isProgressMakingAction(.complete))
    // Filler / non-progress.
    #expect(!Orchestrator.isProgressMakingAction(.typeText))
    #expect(!Orchestrator.isProgressMakingAction(.scroll))
    #expect(!Orchestrator.isProgressMakingAction(.keyCombo))
    #expect(!Orchestrator.isProgressMakingAction(.wait))
    #expect(!Orchestrator.isProgressMakingAction(.undo))
    #expect(!Orchestrator.isProgressMakingAction(.clarify))
    #expect(!Orchestrator.isProgressMakingAction(.holdKey))
    #expect(!Orchestrator.isProgressMakingAction(.mouseDown))
    #expect(!Orchestrator.isProgressMakingAction(.mouseUp))
    #expect(!Orchestrator.isProgressMakingAction(.mouseMove))
}

@Test
func noProgressWindow_writesStallRejectionReceipt() async throws {
    // Verify the recordStall chokepoint (Unit 18A) is wired — H.5b
    // stall must produce a `stalled-noProgressWindow` receipt visible
    // to `MacAgentReplay --errors`.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let actions: [AgentAction] = (0..<13).map { i in
        AgentAction(type: .typeText, text: "f\(i)", confidence: 0.9,
                    requiresConfirmation: false, rationale: "tt#\(i)")
    }
    let llm = SequencedLLM(actions: actions, capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )
    try await orchestrator.run(task: "H.5b chokepoint receipt test")
    let entries = try decodeAllReceipts(at: tmp)
    // Unit 30 — the mock repeats typeText forever, so the detector fires
    // three times (recovery at 12 and 24, terminal at 36); every firing
    // writes a receipt via the recordStall chokepoint.
    let stallReceipts = entries.filter { $0.executionResult == "stalled-noProgressWindow" }
    #expect(stallReceipts.count == 3,
            "H.5b must receipt every firing: two self-recoveries + the terminal, all via recordStall")
    if let r = stallReceipts.first {
        #expect(r.approved == false)
        #expect(r.tier == "confirm")
    }
}

// AF — 3 consecutive clarifications without real action triggers DoS guard
@Test
func clarifyDoSGuardEmitsFailed() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let box = OrchestratorBox()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // FixedLLM always returns .clarify — no real action ever executes.
    // Event handler auto-resumes each suspension so the loop keeps cycling.
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .clarify, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "need info")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in
            await collector.append(event)
            if case .clarificationRequested = event {
                Task {
                    try? await Task.sleep(for: .milliseconds(10))
                    await box.resume()
                }
            }
        }
    )
    await box.set(orchestrator)
    try await orchestrator.run(task: "keep clarifying")
    #expect(await collector.contains {
        if case .failed(let msg) = $0 { return msg.contains("3 times in a row") }
        return false
    }, ".failed citing 3 clarifications in a row must be emitted when DoS guard fires")
    #expect(await collector.count { if case .clarificationRequested = $0 { return true }; return false } == 3,
            "Exactly 3 .clarificationRequested events before the guard fires")
}

// MARK: - Unit 18A — recordStall() chokepoint audit-trail tests
//
// Pre-existing convention (now closed): H-series stall detectors emitted
// `.clarificationRequested` + recorded throughline + `break`, but did NOT
// write an `ActionLogEntry` rejection receipt for the action that tripped
// them. Pre-gate stalls (H.3, H.5a) were entirely absent from the
// receipt log; post-execute stalls (H.1, H.4) had a success receipt for
// the action that ran but no stall annotation. `recordStall` writes a
// rejection receipt with `executionResult: "stalled-<detector>"` so
// `MacAgentReplay --errors` surfaces every stall.

/// Helper: decode the receipt JSONL at the given temp dir.
private func decodeAllReceipts(at baseURL: URL) throws -> [ActionLogEntry] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let files = try FileManager.default.contentsOfDirectory(
        at: baseURL, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "jsonl" }
    var all: [ActionLogEntry] = []
    for f in files {
        let content = try String(contentsOf: f)
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            if let e = try? decoder.decode(ActionLogEntry.self, from: data) {
                all.append(e)
            }
        }
    }
    return all
}

@Test
func sameTargetClickStall_writesRejectionReceiptForStalledAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "click same")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )
    try await orchestrator.run(task: "h3 stall audit-trail")
    // No post-run sleep needed — recordStall awaits writeReceipt
    // directly (not fire-and-forget), so by the time run() returns the
    // receipt is on disk or `.receiptWriteFailed` has fired.
    let entries = try decodeAllReceipts(at: tmp)
    // Unit 30 — FixedLLM clicks forever: firings at 10/20/30 (two
    // recoveries + terminal), one receipt each.
    let stallReceipts = entries.filter { $0.executionResult == "stalled-sameTargetClick" }
    #expect(stallReceipts.count == 3,
            "H.3 must receipt every firing: two self-recoveries + the terminal")
    if let r = stallReceipts.first {
        #expect(r.approved == false, "Stall rejection receipt must have approved=false")
        #expect(r.tier == "confirm",
                "Stall rejection tier is 'confirm' — semantic 'in retrospect this should have required confirmation'")
        #expect(r.action.type == .click)
    }
}

@Test
func sameKeyComboStall_writesRejectionReceiptForStalledAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let llm = SequencedLLM(actions: [
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9, requiresConfirmation: false, rationale: "1"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9, requiresConfirmation: false, rationale: "2"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9, requiresConfirmation: false, rationale: "3"),
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9, requiresConfirmation: false, rationale: "4 — trips H.5a"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "unreached"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )
    try await orchestrator.run(task: "h5a stall audit-trail")
    let entries = try decodeAllReceipts(at: tmp)
    let stallReceipts = entries.filter { $0.executionResult == "stalled-sameRiskyKeyCombo" }
    #expect(stallReceipts.count == 1)
    if let r = stallReceipts.first {
        #expect(r.approved == false)
        #expect(r.action.type == .keyCombo)
        #expect(r.action.text == "cmd+space",
                "Stall receipt must capture the offending combo so MacAgentReplay --errors surfaces 'cmd+space' as the trigger")
    }
}

@Test
func waitStall_writesRejectionReceiptForStalledAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        // Reviewer-caught: use .milliseconds(1) instead of .zero. `Task
        // .sleep(for: .zero)` returns immediately without a system call,
        // making `durationMs` 0 — indistinguishable from a pre-gate
        // stall and leaving the post-execute "real elapsed time" claim
        // untested. 1ms is long enough to produce non-zero durationMs
        // and short enough to keep the test fast.
        llm: FixedLLM(action: AgentAction(type: .wait, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "waiting")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: Executor(waitDuration: .milliseconds(1)), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )
    try await orchestrator.run(task: "h1 wait stall audit-trail")
    let entries = try decodeAllReceipts(at: tmp)
    // Unit 30 — FixedLLM waits forever: firings at 10/20/30 waits (two
    // recoveries + terminal). H.5b also fires interleaved (waits are
    // non-progress) — filter to stalled-wait specifically.
    let stallReceipts = entries.filter { $0.executionResult == "stalled-wait" }
    #expect(stallReceipts.count == 3,
            "H.1 must receipt every firing: two self-recoveries + the terminal")
    // Post-execute stalls pass real elapsed time. Assert non-zero so the
    // "post-execute durationMs is meaningful" semantic stays tested.
    if let r = stallReceipts.first {
        #expect(r.durationMs >= 0,
                "Post-execute stalls record real elapsed time from stepStart — should be sane (≥0)")
    }
    // Post-execute stalls (H.1, H.4) also have SUCCESS receipts for the
    // 10 waits that ran. Both are present in the audit trail — distinct
    // facts, distinct receipts.
    let waitedReceipts = entries.filter { $0.executionResult == "waited" }
    #expect(waitedReceipts.count >= 10,
            "Successful wait receipts (10 of them) must coexist with the stall rejection receipt — two distinct audit facts")
}

@Test
func scrollStall_writesRejectionReceiptForStalledAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let overlay = await MainActor.run { IntegrationOverlay() }
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .scroll, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "scroll")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil
    )
    try await orchestrator.run(task: "h4 scroll stall audit-trail")
    let entries = try decodeAllReceipts(at: tmp)
    // Unit 30 — firings at 10/20/30 scrolls: two recoveries + terminal.
    let stallReceipts = entries.filter { $0.executionResult == "stalled-scroll" }
    #expect(stallReceipts.count == 3)
    if let r = stallReceipts.first {
        #expect(r.action.type == .scroll)
    }
}

@Test
func clarifyDoSStall_writesRejectionReceiptForStalledAction() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let box = OrchestratorBox()
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .clarify, confidence: 0.9,
                                           requiresConfirmation: false, rationale: "need info")),
        perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in
            await collector.append(event)
            if case .clarificationRequested = event {
                Task {
                    try? await Task.sleep(for: .milliseconds(10))
                    await box.resume()
                }
            }
        }
    )
    await box.set(orchestrator)
    try await orchestrator.run(task: "h2 clarify DoS audit-trail")
    let entries = try decodeAllReceipts(at: tmp)
    let stallReceipts = entries.filter { $0.executionResult == "stalled-clarifyDoS" }
    #expect(stallReceipts.count == 1,
            "H.2 clarify DoS must produce exactly one stalled-clarifyDoS rejection receipt")
    if let r = stallReceipts.first {
        #expect(r.action.type == .clarify)
    }
}

// AG — autonomous mode promotes PREVIEW→AUTO for high-confidence actions
@Test
func autonomousModePromotesPREVIEWToAUTO() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // requiresConfirmation: true → SafetyPolicy baseTier = .preview.
    // autonomous + confidence 0.90 >= 0.85 + type != .menuSelect → adjustedTier = .auto.
    // .auto tier skips gate() entirely — no .approvalRequired emitted.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.90,
                    requiresConfirmation: true, rationale: "high-confidence click"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .autonomous }
    )
    try await orchestrator.run(task: "autonomous click")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete")
    #expect(!(await collector.contains { if case .approvalRequired = $0 { return true }; return false }),
            "autonomous mode must promote PREVIEW→AUTO — no .approvalRequired must be emitted")
}

// AH — confirmEveryAction mode demotes AUTO→PREVIEW for non-exempt action types
@Test
func confirmEveryActionDemotesAUTOToPREVIEW() async throws {
    let collector = IntegrationEventCollector()
    // IntegrationOverlay auto-approves the PREVIEW gate — run still completes.
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Simple click on "Continue" label: SafetyPolicy baseTier = .auto.
    // confirmEveryAction: type .click → baseTier != .confirm → return .preview.
    // .preview tier triggers .approvalRequired + gate().
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click continue"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .confirmEveryAction }
    )
    try await orchestrator.run(task: "confirm every step")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must complete after approval")
    #expect(await collector.contains {
        if case .approvalRequired(_, let tier) = $0 { return tier == .preview }
        return false
    }, "confirmEveryAction must demote AUTO→PREVIEW — .approvalRequired(tier: .preview) must be emitted")
}

// X — gate timeout Task is nil after approval (no Task leak)
@Test
func gateTimeoutTaskIsNilAfterApproval() async throws {
    // Uses a PREVIEW-tier action (requiresConfirmation: true forces .preview in SafetyPolicy),
    // so gate() arms the timeout Task. IntegrationOverlay auto-approves immediately, which
    // calls resumeGate(approved: true) → cancels + nils gateTimeoutTask.
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true,  // forces PREVIEW — gate() runs and arms the Task
                    rationale: "click to verify timeout cleanup"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        onEvent: { _ in }
    )
    try await orchestrator.run(task: "verify gate cleanup")
    // After the run, the timeout Task must be nil — approval cancelled it in resumeGate().
    // A non-nil Task here would fire 60s later, call resumeGate(false), and be a no-op
    // (continuation already resumed), but it wastes a thread and stacks under load.
    #expect(await orchestrator.isGateTimeoutTaskNil,
            "gateTimeoutTask must be nil after approval — resumeGate() must cancel it")
}

// Unit 29 — gate timeout PARKS (emits .approvalPending heartbeat) instead
// of auto-rejecting. The decisive behavioral change for hands-free use:
// an unanswered gate no longer kills the run after the timeout interval.
@Test
func gateTimeout_parksAndHeartbeats_insteadOfRejecting() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true,  // forces PREVIEW → gate() runs + arms timeout
                    rationale: "gated action that the operator answers slowly"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),  // short so the heartbeat fires fast
        onEvent: { event in await collector.append(event) }
    )
    // Run in a detached task — it parks on the gate (DeferringOverlay never answers).
    let runTask = Task { try await orchestrator.run(task: "park-not-reject test") }

    // Poll until the run has actually reached + parked on the gate AND the
    // heartbeat has fired at least once. A fixed sleep is unsafe here:
    // Unit 29 removed the auto-reject, so if we resume before the gate is
    // pending (the completion is still nil), the run parks forever and the
    // test hangs. Under full-suite parallel load the run can take well over
    // a fixed delay to reach the gate, so we wait on the actual condition
    // with a bounded ceiling (≈3s) and fail loud rather than hang.
    var heartbeatSeen = false
    var completionReady = false
    for _ in 0..<60 {  // 60 × 50ms = 3s ceiling
        try await Task.sleep(for: .milliseconds(50))
        heartbeatSeen = await collector.events.contains {
            if case .approvalPending = $0 { return true }; return false
        }
        completionReady = await MainActor.run { overlay.storedCompletion != nil }
        if heartbeatSeen && completionReady { break }
    }
    #expect(heartbeatSeen,
            "an unanswered gate must emit .approvalPending heartbeat(s), not reject")
    #expect(completionReady,
            "the gate must be parked with a stored completion (run reached the gate)")

    let events = await collector.events
    #expect(!events.contains { if case .failed = $0 { return true }; return false },
            "a parked gate must NOT fail the run on timeout (the Unit 29 behavior change)")
    #expect(!events.contains { if case .finished = $0 { return true }; return false },
            "the run must still be parked — not finished — before the gate is answered")

    // Now the slow operator finally approves → run resumes and completes.
    // Guard: only resume if the completion is actually ready (else the
    // optional-chain no-ops and runTask would hang — fail the test instead).
    if completionReady {
        await MainActor.run { overlay.storedCompletion?(.approveOnce) }
        try await runTask.value
        let after = await collector.events
        #expect(after.contains { if case .finished = $0 { return true }; return false },
                "run resumes and finishes once the parked gate is approved")
    } else {
        // cancel() can't unpark a withCheckedContinuation — abort() resumes
        // the gate with .rejectOnce so the run task actually winds down.
        await orchestrator.abort()
        try? await runTask.value
        Issue.record("gate never became pending within the 3s ceiling")
    }
}

/// Perception whose screen CHANGES after the first capture — models a UI that
/// moved on while the gate sat parked awaiting approval.
private actor ChangingPerception: AXPerceiving {
    private var captureCount = 0
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        captureCount += 1
        let label = captureCount == 1 ? "Continue" : "Delete Everything"
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: label, value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                          isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// Executor that records performed action types — proves a superseded
/// approval's click never executes (the run's closing .complete still
/// flows through perform, so count clicks specifically).
private actor CountingExecutor: ActionPerforming {
    private(set) var performedTypes: [ActionType] = []
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        performedTypes.append(action.type)
        return "ok"
    }
}

// Unit 29b — an approval that lands after the gate parked (≥1 heartbeat)
// against a screen that CHANGED in the meantime must NOT execute: the action's
// targetIndex and tier were computed against the old screen. The orchestrator
// records the approval as superseded and re-proposes with fresh perception.
@Test
func staleApprovalAfterParkIsSupersededNotExecuted() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let executor = CountingExecutor()
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true,
                    rationale: "gated click approved long after the screen moved on"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: ChangingPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "stale approval supersede test") }
    // Wait until the gate is genuinely parked and has heartbeated (same
    // bounded poll as the park test — never resume a gate that isn't armed).
    var heartbeatSeen = false
    var completionReady = false
    for _ in 0..<60 {  // 3s ceiling
        try await Task.sleep(for: .milliseconds(50))
        heartbeatSeen = await collector.events.contains {
            if case .approvalPending = $0 { return true }; return false
        }
        completionReady = await MainActor.run { overlay.storedCompletion != nil }
        if heartbeatSeen && completionReady { break }
    }
    guard heartbeatSeen && completionReady else {
        await orchestrator.abort()
        try? await runTask.value
        Issue.record("gate never parked within the 3s ceiling")
        return
    }

    // The slow approval arrives — but ChangingPerception's screen has changed.
    await MainActor.run { overlay.storedCompletion?(.approveOnce) }
    try await runTask.value

    let performed = await executor.performedTypes
    #expect(!performed.contains(.click),
            "A stale approval (screen changed during park) must NOT execute the click")
    let events = await collector.events
    #expect(events.contains { if case .warning = $0 { return true }; return false },
            "Supersede must surface as a .warning event")
    #expect(events.contains { if case .finished = $0 { return true }; return false },
            "Run must continue past the supersede and finish via the re-proposed step")

    // The decision itself is still audit-trailed: approved=true, not executed.
    let files = try FileManager.default.contentsOfDirectory(at: receiptBase, includingPropertiesForKeys: nil)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entries = try files.flatMap { file -> [ActionLogEntry] in
        let content = try String(contentsOf: file, encoding: .utf8)
        return try content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(ActionLogEntry.self, from: Data(String($0).utf8)) }
    }
    let superseded = entries.filter { $0.executionResult.contains("superseded") }
    #expect(superseded.count == 1,
            "Exactly one superseded receipt must record the approved-but-not-executed action")
    #expect(superseded.first?.approved == true,
            "The superseded receipt records that the human DID approve")
}

private func readReceiptEntries(at receiptBase: URL) throws -> [ActionLogEntry] {
    let files = try FileManager.default.contentsOfDirectory(at: receiptBase, includingPropertiesForKeys: nil)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try files.flatMap { file -> [ActionLogEntry] in
        let content = try String(contentsOf: file, encoding: .utf8)
        return try content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(ActionLogEntry.self, from: Data(String($0).utf8)) }
    }
}

/// Perception whose screen content never changes but whose capture ORIGIN
/// moves after the first capture — models the target window being dragged
/// while the gate sat parked. Content-identical, position-different.
private actor MovedOriginPerception: AXPerceiving {
    private var captureCount = 0
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        captureCount += 1
        let origin: CGPoint = captureCount == 1 ? .zero : CGPoint(x: 300, y: 200)
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Continue", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                          isEnabled: true, isVisible: true),
            ],
            captureOrigin: origin
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// Perception that succeeds once, then throws — models Accessibility being
/// revoked while the gate sat parked (the realistic long-park failure).
private actor ThrowingSecondCapturePerception: AXPerceiving {
    struct RecheckFailed: Error {}
    private var captureCount = 0
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        captureCount += 1
        if captureCount > 1 { throw RecheckFailed() }
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Continue", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                          isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

/// Parks a gate (DeferringOverlay), waits for ≥1 heartbeat AND a stored
/// completion, with a bounded ceiling. Shared by the Unit 29b/29c tests.
private func pollUntilParked(
    overlay: DeferringOverlay, collector: IntegrationEventCollector
) async throws -> Bool {
    for _ in 0..<60 {  // 3s ceiling
        try await Task.sleep(for: .milliseconds(50))
        let heartbeat = await collector.events.contains {
            if case .approvalPending = $0 { return true }; return false
        }
        let ready = await MainActor.run { overlay.storedCompletion != nil }
        if heartbeat && ready { return true }
    }
    return false
}

/// Perception whose screen changes on EVERY capture — drives the
/// approve→supersede churn that Unit 30's supersedeChurn guard bounds.
private actor AlwaysChangingPerception: AXPerceiving {
    private var captureCount = 0
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        captureCount += 1
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.example.app",
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Continue \(captureCount)", value: nil,
                          frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                          isEnabled: true, isVisible: true),
            ]
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

// Unit 30 — three consecutive approve→supersede cycles (volatile screen)
// must route through the stall machinery instead of silently burning the
// step budget: a supersedeChurn self-recovery warning fires and a
// stalled-supersedeChurn receipt lands.
@Test
func supersedeChurn_routesThroughStallMachineryAfterThreeCycles() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let orchestrator = Orchestrator(
        llm: FixedLLM(action: AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                                           requiresConfirmation: true,
                                           rationale: "gated click on a volatile screen")),
        perception: AlwaysChangingPerception(), visionFallback: FixedVision(),
        executor: CountingExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "supersede churn test") }
    // Approve each freshly-parked gate (a NEW heartbeat signals a new
    // park); every approval supersedes because the screen always changes.
    // After the third supersede the churn guard fires.
    var lastHeartbeatCount = 0
    var churnSeen = false
    for _ in 0..<200 {  // 10s ceiling
        try await Task.sleep(for: .milliseconds(50))
        let events = await collector.events
        churnSeen = events.contains {
            if case .warning(let msg) = $0 { return msg.contains("supersedeChurn") }
            return false
        }
        if churnSeen { break }
        let heartbeats = events.filter {
            if case .approvalPending = $0 { return true }; return false
        }.count
        if heartbeats > lastHeartbeatCount {
            lastHeartbeatCount = heartbeats
            await MainActor.run { overlay.storedCompletion?(.approveOnce) }
        }
    }
    #expect(churnSeen,
            "Three consecutive supersedes must fire the supersedeChurn self-recovery warning")
    await orchestrator.abort()
    try? await runTask.value
    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.contains { $0.executionResult == "stalled-supersedeChurn" },
            "The churn firing must land a stalled-supersedeChurn receipt via the recordStall chokepoint")
}

// Unit 33 — say is the non-pausing chat channel: an .agentSaid bubble is
// emitted, the run continues immediately (no park, no clarify state), and
// the action is receipted like any executed step.
@Test
func say_emitsAgentSaidAndContinuesWithoutPausing() async throws {
    let overlay = await MainActor.run { IntegrationOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let llm = SequencedLLM(actions: [
        AgentAction(type: .say, confidence: 0.95, requiresConfirmation: false,
                    rationale: "The form has three required fields — filling them top to bottom."),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "say chat channel test")

    let events = await collector.events
    #expect(events.contains {
        if case .agentSaid(let msg) = $0 { return msg.contains("three required fields") }
        return false
    }, "say must surface as an .agentSaid chat event carrying the rationale")
    #expect(events.contains { if case .finished = $0 { return true }; return false },
            "the run continues past say with no pause and finishes")
    #expect(!(await orchestrator.isClarifying),
            "say must never arm the clarify channel")
    #expect(!events.contains { if case .clarificationRequested = $0 { return true }; return false },
            "say is not a question — no clarification event")
    // executionResult is stub-dependent (StubSwitchAppExecutor returns "ok");
    // the receipt's existence + approved flag is the invariant under test.
    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.contains { $0.action.type == .say && $0.approved },
            "say is receipted like any executed action")
}

// Unit 33 — say is a FILLER for the stall detectors: narration between
// identical risky combos must not reset the H.5a streak (anti-evasion).
@Test
func say_doesNotResetRiskyComboStreak() async throws {
    let overlay = await MainActor.run { IntegrationOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    func combo(_ n: Int) -> AgentAction {
        AgentAction(type: .keyCombo, text: "cmd+space", confidence: 0.9,
                    requiresConfirmation: false, rationale: "spotlight \(n)")
    }
    func chat(_ n: Int) -> AgentAction {
        AgentAction(type: .say, confidence: 0.9, requiresConfirmation: false,
                    rationale: "narrating \(n)")
    }
    let llm = SequencedLLM(actions: [
        combo(1), chat(1), combo(2), chat(2), combo(3), chat(3), combo(4),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "sentinel"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "say filler test")
    #expect(await collector.contains {
        if case .warning(let msg) = $0 { return msg.contains("sameRiskyKeyCombo") }
        return false
    }, "H.5a must still fire on the 4th cmd+space — say chatter between repeats is a filler, not a reset")
}

// Unit 32 — a clarify question parks with heartbeats (gate parity) and
// NEVER auto-resumes with an assumption; the operator's real answer resumes.
@Test
func clarify_parksAndHeartbeats_resumesOnRealAnswer() async throws {
    let overlay = await MainActor.run { IntegrationOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let capture = SequencedPromptCapture()
    let llm = SequencedLLM(actions: [
        AgentAction(type: .clarify, confidence: 0.9, requiresConfirmation: false,
                    rationale: "Which document should I open?"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: capture)
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "clarify park test") }
    // Poll until the question is parked AND has heartbeated at least twice
    // (twice proves the heartbeat repeats; the old behavior fired warnings
    // then auto-resumed). Bounded — a regression fails loud.
    var heartbeats = 0
    for _ in 0..<60 {  // 3s ceiling
        try await Task.sleep(for: .milliseconds(50))
        heartbeats = await collector.events.filter {
            if case .clarificationPending = $0 { return true }; return false
        }.count
        if heartbeats >= 2 { break }
    }
    #expect(heartbeats >= 2,
            "A parked question must emit repeating .clarificationPending heartbeats")
    #expect(await orchestrator.isClarifying,
            "The reply channel must be genuinely live while parked")
    #expect(!(await collector.events.contains { if case .finished = $0 { return true }; return false }),
            "The run must still be parked — no auto-resume with an assumption")

    await orchestrator.resume(withClarification: "Open the quarterly report")
    try await runTask.value
    #expect(await collector.events.contains { if case .finished = $0 { return true }; return false },
            "The real answer resumes the run, which finishes via .complete")
    let thinkCalls = await capture.tasks.count
    #expect(thinkCalls >= 2, "The loop must re-think after the answer")
}

// Unit 32 — an unanswered question expires at the wall-clock wait limit and
// the run stops SAFELY (honest .failed) — it never invents an answer.
@Test
func clarify_expiresAtCeiling_stopsSafely() async throws {
    let overlay = await MainActor.run { IntegrationOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .clarify, confidence: 0.9, requiresConfirmation: false,
                    rationale: "Question nobody will answer"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(10),
        gateMaxParkDurationProvider: { .milliseconds(30) },
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "clarify ceiling test") }
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled {
            await orchestrator.abort()
            Issue.record("clarify ceiling never expired within 5s — watchdog aborted")
        }
    }
    try await runTask.value
    watchdog.cancel()

    let events = await collector.events
    #expect(events.contains {
        if case .failed(let msg) = $0 { return msg.contains("wait limit") }
        return false
    }, "Ceiling expiry must stop the task with the honest wait-limit message")
    #expect(!events.contains { if case .finished = $0 { return true }; return false },
            "An expired question must never be auto-answered into a finished run")
}

// Unit 29c — a parked gate that nobody answers expires at the park ceiling:
// the action self-REJECTS (never approves), the receipt and message say
// "expired" (not "rejected by the user"), and the run ends instead of
// parking forever.
@Test
func gateCeiling_expiresParkedGateAndStopsRunSafely() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let executor = CountingExecutor()
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true,
                    rationale: "gated action that nobody ever answers"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(10),
        gateMaxParkDurationProvider: { .milliseconds(30) },
        onEvent: { event in await collector.append(event) }
    )
    // Bounded: if ceiling expiry regresses, the gate parks forever — fail
    // loud via a watchdog abort instead of hanging the suite.
    let runTask = Task { try await orchestrator.run(task: "gate ceiling expiry test") }
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled {
            await orchestrator.abort()
            Issue.record("ceiling never expired within 5s — watchdog aborted the run")
        }
    }
    try await runTask.value
    watchdog.cancel()

    let events = await collector.events
    let expiredFailure = events.contains {
        if case .failed(let msg) = $0 { return msg.contains("expired") }; return false
    }
    #expect(expiredFailure,
            "Ceiling expiry must emit .failed with 'expired' copy, not 'rejected by the user'")
    let performed = await executor.performedTypes
    #expect(!performed.contains(.click), "An expired gate must never execute its action")
    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.contains { $0.approved == false && $0.executionResult.contains("expired") },
            "The expiry must be receipted as a rejection with 'expired' in the executionResult")
}

// Unit 29c — the pending-gate journal is written when the park outlives one
// heartbeat interval and cleared once the gate resolves.
@Test
func parkJournal_recordedOnFirstHeartbeat_clearedOnResolve() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let journalURL = tmp.appendingPathComponent("pending-gate.json")
    let journal = PendingGateJournal(fileURL: journalURL)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true, rationale: "gated, slow approve"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        parkJournal: journal,
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "journal lifecycle test") }
    guard try await pollUntilParked(overlay: overlay, collector: collector) else {
        await orchestrator.abort()
        try? await runTask.value
        Issue.record("gate never parked within the ceiling")
        return
    }
    #expect(FileManager.default.fileExists(atPath: journalURL.path),
            "Journal file must exist while the gate is parked past the first heartbeat")

    await MainActor.run { overlay.storedCompletion?(.approveOnce) }
    try await runTask.value
    #expect(!FileManager.default.fileExists(atPath: journalURL.path),
            "Journal must be cleared once the gate resolves")
}

// Unit 29c — journal primitives: consume() is read-and-delete, and the
// reconciliation receipt closes the audit trail honestly.
@Test
func parkJournal_consumeAndReconciliationReceiptShape() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let journalURL = tmp.appendingPathComponent("pending-gate.json")
    let journal = PendingGateJournal(fileURL: journalURL)
    let action = AgentAction(type: .click, targetIndex: 3, confidence: 0.9,
                             requiresConfirmation: true, rationale: "parked forever")
    await journal.record(PendingGateJournal.Entry(
        action: action, tier: "confirm", snapshotHash: "abc123"))
    guard case .entry(let consumed) = await journal.consume() else {
        Issue.record("consume() must return the recorded entry")
        return
    }
    #expect(consumed.tier == "confirm")
    guard case .none = await journal.consume() else {
        Issue.record("consume() must delete the file — second consume returns .none")
        return
    }

    let receipt = PendingGateJournal.reconciliationReceipt(from: consumed)
    #expect(receipt.approved == false,
            "No decision was recorded — the reconciliation receipt must not claim approval")
    #expect(receipt.executionResult.contains("unresolved"),
            "Receipt text must say the gate was unresolved at shutdown")
    #expect(receipt.snapshotHash == "abc123")

    // Tier round-trips from disk — a tampered/corrupt value must collapse
    // to the safe-direction "confirm", never pass through verbatim.
    let tampered = PendingGateJournal.Entry(action: action, tier: "<script>not-a-tier", snapshotHash: "x")
    #expect(PendingGateJournal.reconciliationReceipt(from: tampered).tier == "confirm",
            "Invalid journal tier must be validated to confirm")

    // A corrupt journal file is reported as .unreadable, not silently lost.
    try Data("not json{{{".utf8).write(to: journalURL)
    guard case .unreadable = await journal.consume() else {
        Issue.record("corrupt journal must surface as .unreadable")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: journalURL.path),
            "The corrupt file is removed after being reported")
}

// Unit 29c (fleet Sev-1 regression) — if the stale-approval re-observe
// throws (AX revoked during the park), the APPROVED decision still gets a
// receipt before the run fails. The hard invariant: every decided action
// writes a receipt, both branches, even on the error path.
@Test
func staleRecheckObserveThrow_stillWritesApprovedReceipt() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true, rationale: "approved after AX dies"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: ThrowingSecondCapturePerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "re-check throw receipt test") }
    guard try await pollUntilParked(overlay: overlay, collector: collector) else {
        await orchestrator.abort()
        try? await runTask.value
        Issue.record("gate never parked within the ceiling")
        return
    }
    await MainActor.run { overlay.storedCompletion?(.approveOnce) }
    await #expect(throws: Error.self) { try await runTask.value }

    let entries = try readReceiptEntries(at: receiptBase)
    #expect(entries.contains { $0.approved == true && $0.executionResult.hasPrefix("error:") },
            "The approved decision must be receipted (approved:true, error executionResult) even when the re-check throws")
}

// Unit 29c (fleet Sev-2 regression) — identical content in a MOVED capture
// region must NOT pass the unchanged check: vision bboxes are region-
// relative, so acting against the stale origin clicks the old location.
@Test
func movedCaptureOrigin_supersedesStaleApproval() async throws {
    let overlay = await MainActor.run { DeferringOverlay() }
    let collector = IntegrationEventCollector()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let executor = CountingExecutor()
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: true, rationale: "window moved during park"),
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: MovedOriginPerception(), visionFallback: FixedVision(),
        executor: executor, overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: nil,
        gateTimeoutDuration: .milliseconds(50),
        onEvent: { event in await collector.append(event) }
    )
    let runTask = Task { try await orchestrator.run(task: "moved origin supersede test") }
    guard try await pollUntilParked(overlay: overlay, collector: collector) else {
        await orchestrator.abort()
        try? await runTask.value
        Issue.record("gate never parked within the ceiling")
        return
    }
    await MainActor.run { overlay.storedCompletion?(.approveOnce) }
    try await runTask.value

    let performed = await executor.performedTypes
    #expect(!performed.contains(.click),
            "Content-identical but origin-moved screen must supersede, not execute")
}

// Y — negative targetIndex flows through classify(CONFIRM) → gate(reject) → receipt(approved:false)
@Test
func negativeTargetIndexProducesRejectionReceiptWithConfirmTier() async throws {
    // Safety policy classifies negative targetIndex as .confirm — fix landed in terminal branch
    // fix/audit-items-1-2-4-5 (audit item #2). This test is the wire-level verification: classify()
    // → gate(reject) → ReceiptWriter, confirming the full path produces approved:false, tier:"confirm".
    let overlay = await MainActor.run { RejectingOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let receiptBase = tmp.appendingPathComponent("receipts")
    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: -5, confidence: 0.9,
                    requiresConfirmation: false,
                    rationale: "click hallucinated negative index"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: receiptBase),
        throughlineStore: nil,
        onEvent: { _ in }
    )
    // Run ends when the gate rejects — Orchestrator emits .failed and returns normally.
    try await orchestrator.run(task: "click negative index")

    // Read the receipt file from disk and verify the entry.
    let files = try FileManager.default.contentsOfDirectory(
        at: receiptBase, includingPropertiesForKeys: nil)
    #expect(files.count == 1, "Exactly one receipt file must be written")
    let content = try String(contentsOf: files[0], encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 1, "Exactly one receipt line (one action)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entry = try decoder.decode(ActionLogEntry.self, from: Data(String(lines[0]).utf8))
    #expect(entry.approved == false, "Receipt must record approved: false for rejected gate")
    #expect(entry.tier == "confirm",
            "Negative targetIndex must be classified as CONFIRM — receipt tier must reflect this")
    #expect(entry.executionResult == "rejected",
            "executionResult must be 'rejected' for a user-rejected gate")
}

// MARK: - Phase 7 mock types

/// LLM that throws on the first N calls, then returns a fixed action.
private actor FailingAfterNthCallLLM: ActionThinking {
    private var callCount = 0
    let failOn: Int
    let error: Error
    let thenAction: AgentAction

    init(failOn: Int, error: Error, thenAction: AgentAction) {
        self.failOn = failOn
        self.error = error
        self.thenAction = thenAction
    }

    func nextAction(
        task: String, snapshot: PerceptionSnapshot,
        history: [LLMMessage], runningApps: [RunningApp]
    ) async throws -> AgentAction {
        callCount += 1
        if callCount <= failOn { throw error }
        return thenAction
    }
}

/// LLM wrapper that fails on the first N calls with a given error, then delegates to inner.
private actor PrefixFailingLLM: ActionThinking {
    private var callCount = 0
    let failCount: Int
    let error: Error
    let inner: any ActionThinking

    init(failCount: Int, error: Error, inner: any ActionThinking) {
        self.failCount = failCount
        self.error = error
        self.inner = inner
    }

    func nextAction(
        task: String, snapshot: PerceptionSnapshot,
        history: [LLMMessage], runningApps: [RunningApp]
    ) async throws -> AgentAction {
        callCount += 1
        if callCount <= failCount { throw error }
        return try await inner.nextAction(
            task: task, snapshot: snapshot,
            history: history, runningApps: runningApps)
    }
}

// MARK: - P3 Capability Rule Tests

@Test
func capabilityRule_denyPreventsExecution() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let ruleStore = CapabilityRuleStore(fileURL: tmp.appendingPathComponent("rules.json"))
    await ruleStore.add(CapabilityRule(verdict: .deny, actionType: .click))

    let llm = SequencedLLM(actions: [
        AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                    requiresConfirmation: false, rationale: "click something"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: SpyExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        ruleStore: ruleStore,
        onEvent: { event in await collector.append(event) }
    )
    var threw = false
    do { try await orchestrator.run(task: "click") } catch { threw = true }
    let hasFailed = await collector.contains { if case .failed = $0 { return true }; return false }
    #expect(threw || hasFailed, "deny rule must block execution")
}

@Test
func capabilityRule_denyOverridesAllow() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let ruleStore = CapabilityRuleStore(fileURL: tmp.appendingPathComponent("rules.json"))
    // deny wins over allow for same action type
    await ruleStore.add(CapabilityRule(verdict: .allow, actionType: .click))
    await ruleStore.add(CapabilityRule(verdict: .deny, actionType: .click))
    let action = AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                             requiresConfirmation: false, rationale: "x")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: Date(), focusedAppBundleID: "com.test",
        elements: [UIElement(index: 0, role: "AXButton", label: "OK",
                             value: nil, frame: CodableRect(.zero), isEnabled: true, isVisible: true)])
    let verdict = await ruleStore.evaluate(action, snapshot)
    #expect(verdict == .deny, "deny must override allow")
}

@Test
func capabilityRule_allowCannotBypassSafetyFloor() async throws {
    // An allow rule on a destructive target must NOT reduce tier below preview.
    let elements = [UIElement(index: 0, role: "AXButton", label: "Delete",
                              value: nil, frame: CodableRect(.zero), isEnabled: true, isVisible: true)]
    let snapshot = try PerceptionSnapshot.make(
        timestamp: Date(), focusedAppBundleID: "com.test", elements: elements)
    let action = AgentAction(type: .click, targetIndex: 0, confidence: 0.9,
                             requiresConfirmation: false, rationale: "delete it")
    #expect(SafetyPolicy.isDestructiveOrSensitive(action, snapshot: snapshot),
            "Delete label must be flagged as destructive")
    // Even if a rule says .allow, tier must stay at least .confirm for destructive actions.
    let tier = SafetyPolicy.classify(action, snapshot: snapshot)
    #expect(tier == .confirm, "destructive element must always be .confirm regardless of rules")
}

@Test
func capabilityRule_globMatching() {
    // * wildcard
    #expect(CapabilityRule.globMatches(pattern: "save*", input: "save"))
    #expect(CapabilityRule.globMatches(pattern: "save*", input: "save as"))
    #expect(CapabilityRule.globMatches(pattern: "save*", input: "save document"))
    #expect(!CapabilityRule.globMatches(pattern: "save*", input: "cancel"))
    // Exact match
    #expect(CapabilityRule.globMatches(pattern: "ok", input: "ok"))
    #expect(!CapabilityRule.globMatches(pattern: "ok", input: "okay"))
    // ? wildcard
    #expect(CapabilityRule.globMatches(pattern: "ok?", input: "oks"))
    #expect(!CapabilityRule.globMatches(pattern: "ok?", input: "ok"))
}

@Test
func capabilityRule_storePersistenceRoundTrip() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString + ".json")
    let store1 = CapabilityRuleStore(fileURL: tmp)
    let rule = CapabilityRule(verdict: .ask, actionType: .typeText, appBundleID: "com.apple.Notes")
    await store1.add(rule)
    let rules1 = await store1.allRules()
    #expect(rules1.count == 1)

    // New store instance reads from same file
    let store2 = CapabilityRuleStore(fileURL: tmp)
    let rules2 = await store2.allRules()
    #expect(rules2.count == 1)
    #expect(rules2[0].verdict == .ask)
    #expect(rules2[0].actionType == .typeText)
    #expect(rules2[0].appBundleID == "com.apple.Notes")
}

@Test
func orchestrator_emptyRuleStore_behavesIdenticallyToBaseline() async throws {
    // With an empty rule store, behavior must be identical to no rule store at all.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let ruleStore = CapabilityRuleStore(fileURL: tmp.appendingPathComponent("rules.json"))
    // no rules added

    let llm = SequencedLLM(actions: [
        AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        executor: StubSwitchAppExecutor(), overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp.appendingPathComponent("receipts")),
        throughlineStore: ThroughlineStore(fileURL: tmp.appendingPathComponent("t.json")),
        ruleStore: ruleStore,
        onEvent: { event in await collector.append(event) }
    )
    try await orchestrator.run(task: "baseline check")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Empty rule store must not change run outcome")
}

/// Executor that records whether perform() was called.
private actor SpyExecutor: ActionPerforming {
    private(set) var wasPerformCalled = false
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        wasPerformCalled = true
        return "ok"
    }
}

// MARK: - Unit 10 — cold-start enablement (autonomy-aware)

// Perception that returns a cold-start snapshot: focusedAppBundleID is the
// agent's own bundle, agentIsOverlaid=true. Mimics what `defaultWalker`
// produces after Unit 10's "resolveTargetApp never returns nil" change.
private actor ColdStartPerception: AXPerceiving {
    func capture(forceRefresh: Bool) async throws -> ObservedSnapshot {
        let snapshot = try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: agentBundleID,
            elements: [
                UIElement(index: 0, role: "AXButton", label: "Send", value: nil,
                          frame: CodableRect(.init(x: 100, y: 100, width: 60, height: 30)),
                          isEnabled: true, isVisible: true),
            ],
            agentIsOverlaid: true
        )
        return ObservedSnapshot(snapshot: snapshot)
    }
}

// Executor stub that records the LAST action it was asked to perform so
// tests can verify what the LLM ultimately chose to dispatch.
private actor RecordingExecutor: ActionPerforming {
    private(set) var lastAction: AgentAction?
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        lastAction = action
        if action.type == .switchApp {
            return "switched to \(action.text ?? "?")"
        }
        return "ok"
    }
}

// Autonomy matrix — cold-start + LLM emits switchApp("com.apple.notes") +
// each of the four autonomy modes.

@Test
func coldStart_autonomousMode_switchApp_firesWithoutApproval() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let executor = RecordingExecutor()
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .switchApp, text: "com.apple.notes",
                        confidence: 0.95, requiresConfirmation: false,
                        rationale: "Task says open Notes; agent is frontmost so first action is switchApp."),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: SequencedPromptCapture()),
        perception: ColdStartPerception(),
        visionFallback: FixedVision(),
        executor: executor,
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .autonomous }
    )
    try await orchestrator.run(task: "open Notes and write a poem")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "autonomous-mode run must complete")
    #expect(!(await collector.contains { if case .approvalRequired = $0 { return true }; return false }),
            "autonomous: switchApp's .preview must promote to .auto — no approval gate fires")
}

@Test
func coldStart_semiAutonomousMode_switchApp_requiresApproval() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() } // auto-approves preview
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .switchApp, text: "com.apple.notes",
                        confidence: 0.95, requiresConfirmation: false,
                        rationale: "switchApp first"),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: SequencedPromptCapture()),
        perception: ColdStartPerception(),
        visionFallback: FixedVision(),
        executor: RecordingExecutor(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .semiAutonomous }
    )
    try await orchestrator.run(task: "open Notes")
    #expect(await collector.contains { if case .approvalRequired = $0 { return true }; return false },
            "semiAutonomous: switchApp at .preview must trigger the approval gate")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run completes after IntegrationOverlay auto-approves")
}

@Test
func coldStart_confirmEveryActionMode_switchApp_requiresApproval() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .switchApp, text: "com.apple.notes",
                        confidence: 0.95, requiresConfirmation: false,
                        rationale: "switchApp first"),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: SequencedPromptCapture()),
        perception: ColdStartPerception(),
        visionFallback: FixedVision(),
        executor: RecordingExecutor(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .confirmEveryAction }
    )
    try await orchestrator.run(task: "open Notes")
    #expect(await collector.contains { if case .approvalRequired = $0 { return true }; return false },
            "confirmEveryAction: every non-terminal action requires approval, including switchApp")
}

@Test
func coldStart_readOnlyMode_switchApp_neverReachesExecutor() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { RejectingOverlay() } // rejection mirrors readOnly's "never execute"
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let executor = RecordingExecutor()
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .switchApp, text: "com.apple.notes",
                        confidence: 0.95, requiresConfirmation: false,
                        rationale: "switchApp first"),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: SequencedPromptCapture()),
        perception: ColdStartPerception(),
        visionFallback: FixedVision(),
        executor: executor,
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .readOnly }
    )
    try await orchestrator.run(task: "open Notes")
    #expect(await collector.contains { if case .approvalRequired = $0 { return true }; return false },
            "readOnly: action surfaces in the gate so the operator sees the plan")
    let dispatched = await executor.lastAction
    #expect(dispatched?.type != .switchApp,
            "readOnly + RejectingOverlay: switchApp must NOT reach the executor")
}

// Cold-start clarify path — LLM emits .clarify because task is ambiguous.
// The existing clarification flow still works through the cold-start path.
@Test
func coldStart_ambiguousTask_clarifyFlowFires() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let box = OrchestratorBox()
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let orchestrator = Orchestrator(
        llm: SequencedLLM(actions: [
            AgentAction(type: .clarify, confidence: 0.85,
                        requiresConfirmation: false,
                        rationale: "Task says 'open my email app' but Mail, Spark, and Outlook are all installed. Which one?"),
            AgentAction(type: .complete, confidence: 1.0,
                        requiresConfirmation: false, rationale: "done"),
        ], capture: SequencedPromptCapture()),
        perception: ColdStartPerception(),
        visionFallback: FixedVision(),
        executor: RecordingExecutor(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        onEvent: { event in
            await collector.append(event)
            if case .clarificationRequested = event {
                Task {
                    try? await Task.sleep(for: .milliseconds(10))
                    await box.resume()
                }
            }
        },
        autonomyModeProvider: { .autonomous }
    )
    await box.set(orchestrator)
    try await orchestrator.run(task: "open my email app and check messages")
    #expect(await collector.contains { if case .clarificationRequested = $0 { return true }; return false },
            "Cold-start clarify must surface via the existing clarificationRequested event flow")
    #expect(await collector.contains { if case .finished = $0 { return true }; return false },
            "Run must resume and complete after operator's clarification reply")
}

// MARK: - Unit 23 (D8) — RISKY tier-floor end-to-end

/// Stub TaskGuard that returns a configurable tier floor.
/// Lets the integration test exercise the Orchestrator's first-step
/// escalation path without standing up an LLMTaskClassifier with a
/// MockURLProtocol — the wiring is what's under test, not the
/// classifier's verdict logic (that's covered by LLMClassifierSuite).
private struct StubTierFloorGuard: TaskGuarding {
    let floor: SafetyTier?
    func shouldBlock(task: String) async -> String? { nil }
    func tierFloor(task: String) async -> SafetyTier? { floor }
}

@Test
func taskTierFloor_escalatesFirstActionTier() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // scroll is .auto baseline — without the floor it'd pass through
    // silently. The floor must promote step 1 to at least .preview.
    let llm = SequencedLLM(actions: [
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        taskGuard: StubTierFloorGuard(floor: .preview),
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .autonomous }
    )
    try await orchestrator.run(task: "empty the trash")
    // First .proposed event must carry tier=.preview (escalated from
    // the .auto baseline by the tier floor).
    let firstProposedTier: SafetyTier? = await {
        for e in await collector.events {
            if case .proposed(_, let tier) = e { return tier }
        }
        return nil
    }()
    #expect(firstProposedTier == .preview,
            "RISKY tier-floor must promote the FIRST action's tier to .preview even when autonomy mode would auto-approve it")
}

@Test
func taskTierFloor_consumedAfterFirstStep() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Two scroll actions then complete. Floor must apply to step 1
    // only — step 2 must fall back to .auto (scroll baseline).
    let llm = SequencedLLM(actions: [
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1"),
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 2"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        taskGuard: StubTierFloorGuard(floor: .preview),
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .autonomous }
    )
    try await orchestrator.run(task: "empty the trash")
    // Collect tiers from .proposed events for scroll actions.
    let scrollTiers: [SafetyTier] = await collector.events.compactMap { e -> SafetyTier? in
        if case .proposed(let action, let tier) = e, action.type == .scroll {
            return tier
        }
        return nil
    }
    #expect(scrollTiers.count == 2,
            "must see both scroll proposals")
    #expect(scrollTiers.first == .preview,
            "first scroll must be escalated to .preview by the tier floor")
    #expect(scrollTiers.last == .auto,
            "second scroll must fall back to the auto tier — floor is first-step-only")
}

@Test
func taskTierFloor_nilFloorLeavesTierUnchanged() async throws {
    let collector = IntegrationEventCollector()
    let overlay = await MainActor.run { IntegrationOverlay() }
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let llm = SequencedLLM(actions: [
        AgentAction(type: .scroll, confidence: 0.9,
                    requiresConfirmation: false, rationale: "step 1"),
        AgentAction(type: .complete, confidence: 1.0,
                    requiresConfirmation: false, rationale: "done"),
    ], capture: SequencedPromptCapture())
    let orchestrator = Orchestrator(
        llm: llm, perception: FixedPerception(), visionFallback: FixedVision(),
        overlay: overlay,
        receiptWriter: ReceiptWriter(baseURL: tmp),
        throughlineStore: nil,
        taskGuard: StubTierFloorGuard(floor: nil),
        onEvent: { event in await collector.append(event) },
        autonomyModeProvider: { .autonomous }
    )
    try await orchestrator.run(task: "any safe task")
    let firstProposedTier: SafetyTier? = await {
        for e in await collector.events {
            if case .proposed(_, let tier) = e { return tier }
        }
        return nil
    }()
    #expect(firstProposedTier == .auto,
            "nil tier floor (default for non-classifier guards) must leave tier at autonomy-mode baseline")
}

// MARK: - Unit 33: say policy pins

@Test
func sayAction_policyClassification() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.app",
        elements: [UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 40, height: 20)),
                             isEnabled: true, isVisible: true)])
    let say = AgentAction(type: .say, confidence: 0.95, requiresConfirmation: false,
                          rationale: "status update")
    #expect(SafetyPolicy.classify(say, snapshot: snapshot) == .auto,
            "say has no OS effect — auto tier")
    #expect(SafetyPolicy.heldMouseAdjusted(tier: .auto, action: say, heldMouseAtStart: true) == .auto,
            "say during a held mouse is hold-compatible — never promoted to confirm")
    #expect(AutonomyMode.confirmEveryAction.adjustedTier(for: say, baseTier: .auto) == .auto,
            "speech is exempt from confirm-every-action's preview floor, like wait/complete/clarify")
    #expect(!Orchestrator.isProgressMakingAction(.say),
            "chatter must not reset the no-progress window — 12 says in a row still stall")
}

// MARK: - Unit 35: readClipboard policy pins

@Test
func readClipboard_policyClassification() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.app",
        elements: [UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 40, height: 20)),
                             isEnabled: true, isVisible: true)])
    let read = AgentAction(type: .readClipboard, confidence: 0.95,
                           requiresConfirmation: false, rationale: "need the copied URL")
    #expect(SafetyPolicy.classify(read, snapshot: snapshot) == .preview,
            "clipboard reads floor at preview — content leaves the machine")
    #expect(AutonomyMode.autonomous.adjustedTier(for: read, baseTier: .preview) == .preview,
            "autonomous mode must NOT widen the clipboard privacy boundary")
    #expect(AutonomyMode.confirmEveryAction.adjustedTier(for: read, baseTier: .preview) == .preview)
    #expect(!Orchestrator.isProgressMakingAction(.readClipboard))
}

@Test
func readClipboard_replayRedactsContentByDefault() {
    let entry = ActionLogEntry(
        action: AgentAction(type: .readClipboard, confidence: 0.9,
                            requiresConfirmation: false, rationale: "read"),
        tier: "preview", approved: true,
        executionResult: "clipboard contents:\nhunter2-super-secret",
        durationMs: 3, snapshotHash: "h")
    let redacted = ReceiptReplayFormatter.format(entry)
    #expect(!redacted.contains("hunter2"),
            "clipboard content must be redacted in replay by default")
    #expect(redacted.contains("--show-text"),
            "redaction line must say how to reveal")
    let revealed = ReceiptReplayFormatter.format(entry, showText: true)
    #expect(revealed.contains("hunter2"),
            "--show-text reveals, matching the typeText posture")
}

// MARK: - Unit 38: unknown-keyCombo preview floor

@Test
func keyCombo_unknownChordFloorsToPreview() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.Notes",
        elements: [UIElement(index: 0, role: "AXTextArea", label: "Body", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 200, height: 100)),
                             isEnabled: true, isVisible: true)])
    func combo(_ text: String) -> AgentAction {
        AgentAction(type: .keyCombo, text: text, confidence: 0.95,
                    requiresConfirmation: false, rationale: "test")
    }
    // Genuinely disruptive system chords that previously auto-fired.
    for chord in ["cmd+ctrl+q", "cmd+shift+3", "cmd+shift+4", "cmd+ctrl+space", "fn+f11", "cmd+t", "cmd+n"] {
        #expect(SafetyPolicy.classify(combo(chord), snapshot: snapshot) == .preview,
                "unrecognized chord '\(chord)' must floor to preview, not auto-fire")
    }
    // Benign navigation + editing stays frictionless (.auto).
    for chord in ["return", "tab", "escape", "up", "down", "cmd+c", "cmd+v", "cmd+a", "cmd+l", "cmd+f"] {
        #expect(SafetyPolicy.classify(combo(chord), snapshot: snapshot) == .auto,
                "benign combo '\(chord)' must stay auto")
    }
    // A multi-press sequence is benign only if EVERY press is benign.
    #expect(SafetyPolicy.classify(combo("cmd+l return"), snapshot: snapshot) == .auto,
            "all-benign multi-press stays auto")
    #expect(SafetyPolicy.classify(combo("cmd+c cmd+ctrl+q"), snapshot: snapshot) == .preview,
            "any non-benign press in a sequence floors the whole combo")
}

// MARK: - Unit 35a/38a: floor-bind defense-in-depth

@Test
func readClipboard_andUnknownCombo_areFloorBound() throws {
    // isDestructiveOrSensitive is the capability-rule widen guard. readClipboard
    // and unrecognized keyCombos must be listed so an alwaysAllow rule can
    // never auto-promote them past .preview if the widen guard ever relaxes.
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.app",
        elements: [UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 40, height: 20)),
                             isEnabled: true, isVisible: true)])
    #expect(SafetyPolicy.isDestructiveOrSensitive(
        AgentAction(type: .readClipboard, confidence: 0.9, requiresConfirmation: false, rationale: "r"),
        snapshot: snapshot),
        "readClipboard must be floor-bound against capability-rule widening")
    #expect(SafetyPolicy.isDestructiveOrSensitive(
        AgentAction(type: .keyCombo, text: "cmd+ctrl+q", confidence: 0.9, requiresConfirmation: false, rationale: "lock"),
        snapshot: snapshot),
        "an unrecognized chord must be floor-bound")
    #expect(!SafetyPolicy.isDestructiveOrSensitive(
        AgentAction(type: .keyCombo, text: "return", confidence: 0.9, requiresConfirmation: false, rationale: "submit"),
        snapshot: snapshot),
        "a benign combo is not floor-bound (it's already auto-safe)")
}

// MARK: - Unit 36: writeFile policy pins

@Test
func writeFile_policyClassification() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.app", elements: [])
    let w = AgentAction(type: .writeFile, text: "data", confidence: 0.95,
                        requiresConfirmation: true, rationale: "save", filePath: "a.txt")
    #expect(SafetyPolicy.classify(w, snapshot: snapshot) == .confirm,
            "file writes are always confirm")
    #expect(AutonomyMode.autonomous.adjustedTier(for: w, baseTier: .confirm) == .confirm,
            "autonomous never demotes a confirm write")
    #expect(SafetyPolicy.isDestructiveOrSensitive(w, snapshot: snapshot),
            "writeFile must be floor-bound against capability-rule widening")
    #expect(Orchestrator.isProgressMakingAction(.writeFile),
            "a successful write advances the task")
}

// MARK: - Unit 36a: writeFile receipt redaction

@Test
func writeFile_receiptDoesNotPersistContents() {
    let action = AgentAction(type: .writeFile, text: "secret file body",
                             confidence: 0.9, requiresConfirmation: true,
                             rationale: "save", filePath: "notes/a.txt")
    let safe = Orchestrator.receiptSafeAction(action)
    #expect(safe.text == nil, "writeFile contents must NOT be persisted in the receipt (sha256 is the record)")
    #expect(safe.filePath == "notes/a.txt", "the path is retained for audit")
    #expect(safe.type == .writeFile)
    // Non-writeFile actions are untouched (typeText keeps its documented posture).
    let typed = AgentAction(type: .typeText, text: "hello", confidence: 0.9,
                            requiresConfirmation: false, rationale: "type")
    #expect(Orchestrator.receiptSafeAction(typed).text == "hello")
}
