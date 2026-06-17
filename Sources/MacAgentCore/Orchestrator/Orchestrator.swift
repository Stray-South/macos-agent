import AppKit
import Foundation

public enum OrchestratorError: Error, LocalizedError, Sendable, Equatable {
    case permissionsRevoked
    /// Thrown by think() when the Anthropic API key is absent. Always fatal — the user
    /// must add the key in Settings before retrying; no amount of automatic retrying helps.
    case apiKeyMissing
    /// Thrown by think() for retryable LLM failures (rate limits, transient API errors,
    /// bad JSON from Claude). The outer run() loop catches this and retries up to
    /// maxThinkRecoverySteps times before emitting .failed and rethrowing.
    case transientLLMFailure(String)

    public var errorDescription: String? {
        switch self {
        case .permissionsRevoked:
            return "Accessibility permission was revoked. Re-grant it in System Settings > Privacy & Security > Accessibility."
        case .apiKeyMissing:
            return "Anthropic API key not found. Add it in Settings or set the ANTHROPIC_API_KEY environment variable."
        case .transientLLMFailure(let message):
            return message
        }
    }
}

public actor Orchestrator {
    private let llm: ActionThinking
    private let perception: AXPerceiving
    private let visionFallback: VisionPerceiving
    private let executor: any ActionPerforming
    private let overlay: any OverlayControlling
    private let receiptWriter: ReceiptWriter
    private let onEvent: (@Sendable (OrchestratorEvent) async -> Void)?
    private let autonomyModeProvider: @Sendable () -> AutonomyMode
    private let runningAppsProvider: @Sendable () -> [RunningApp]
    private let throughlineStore: ThroughlineStore?
    /// Unit 19 — opt-in snapshot persistence. When non-nil, every
    /// successful `observe()` triggers a fire-and-forget Task to
    /// persist the snapshot sidecar. Default nil (feature off). When
    /// enabled, AppModel constructs the writer per the operator's
    /// `UserDefaults.agentSuite.persistSnapshots` toggle.
    private let snapshotWriter: SnapshotWriter?
    /// Optional capability rule store. When nil, rule evaluation is skipped and
    /// SafetyPolicy/AutonomyMode govern everything (identical to prior behavior).
    private let ruleStore: CapabilityRuleStore?
    private let taskGuard: any TaskGuarding
    /// Read-only accessor for the configured task guard. `internal` so
    /// `AppModelTaskGuardTests` can verify production wiring without exposing
    /// `taskGuard` as part of the public API.
    var taskGuardForTesting: any TaskGuarding { taskGuard }
    private let planner: TaskPlanning

    private var running = false
    private var shouldForceVisualCheck = false
    private var conversationHistory: [LLMMessage] = []
    /// Messages sent by the user while the agent is running. Drained into
    /// conversationHistory at the top of each loop iteration before think().
    private var pendingUserMessages: [String] = []
    private var currentTask = ""
    private var pendingGateContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var gateTimeoutTask: Task<Void, Never>?
    /// Unit 29b — number of .approvalPending heartbeats emitted for the
    /// currently/last parked gate. Reset when a gate arms; read after the
    /// gate resolves to decide whether the approval is stale enough to
    /// require a fresh-perception re-check before acting.
    private var gateHeartbeatCount = 0
    /// Unit 29c — set by the heartbeat loop when the park ceiling expires
    /// (the gate self-rejects); read by the rejection branch to write a
    /// distinct receipt + message instead of "rejected by the user".
    private var gateExpired = false
    /// Snapshot hash of the screen the currently-gated action was proposed
    /// against — stamped by the run loop before gate(), read by the journal.
    private var lastGateSnapshotHash = ""
    /// Chain fix — true while pending-gate.json holds an entry for the
    /// current parked step. Replaces keying the journal-clear on
    /// gateHeartbeatCount, which stayed >0 until the NEXT gate() and let an
    /// unrelated later receipt write (pre-gate stall, capability deny — in
    /// this run or the next on the reused orchestrator) clear a journal that
    /// was intentionally KEPT to compensate for a failed receipt write.
    private var parkJournalPending = false
    /// Unit 29d — wall-clock park start, stamped when a gate arms. The
    /// ceiling expires on ELAPSED time (ContinuousClock advances across
    /// machine sleep), not heartbeat count — a lid-closed overnight park
    /// must not extend the approval window past the configured limit.
    private var gateParkStart: ContinuousClock.Instant?
    /// Unit 32 — same stamp for a parked clarification question.
    private var clarifyParkStart: ContinuousClock.Instant?
    /// Unit 29d — provider, not a frozen value: the operator can tighten
    /// the ceiling from Settings while a gate is already parked, and the
    /// next heartbeat must honor the new value.
    private let gateMaxParkDurationProvider: @Sendable () -> Duration?
    private let parkJournal: PendingGateJournal?
    private let maxSteps: Int
    // Injected for testability — production default is 60 s.
    private let gateTimeoutDuration: Duration
    private var consecutiveWaits = 0
    private var needsFreshPerception = false
    private var pendingClarification: CheckedContinuation<String, Never>?
    // Timeout Task for the active clarification wait. Cancelled immediately when the user
    // replies so background sleep Tasks don't linger for the full 300s (240+60) in tests.
    private var clarificationTimeoutTask: Task<Void, Never>?
    // Unit 30 — per-detector self-recovery budget. Each H-series detector
    // may fire `stallRecoveryBudget` times per run as a SELF-RECOVERY
    // (hint injected into conversation history, loop continues); the
    // firing after that is terminal. Keyed by detector tag.
    /// Unit 30a — see run(): lets a wedged stale loop detect that a newer
    /// run() superseded it and exit instead of resuming concurrently.
    private var runGeneration = 0
    // Track A live-found 2026-06-15: vision-capture failure degrades to AX-only
    // (see observe()). Warn the operator ONCE per run, not on every loop
    // iteration — an AX-poor app with Screen Recording denied would otherwise
    // flood the conversation with one identical warning per step. Reset in run().
    private var visionUnavailableWarned = false
    private var stallRecoveryAttempts: [String: Int] = [:]
    static let stallRecoveryBudget = 2
    // Unit 30 — supersede-churn guard (29c fleet deferral): consecutive
    // approved-but-superseded actions. A volatile screen (timer, badge,
    // animation) can supersede every approval that lands after one
    // heartbeat; without this counter the churn silently burns the step
    // budget while RESETTING H.5b (the superseded click counted as
    // progress at propose time).
    private var consecutiveSupersedes = 0
    // H.2 — clarify DoS guard: abort after 3 consecutive clarifications with no real action.
    private var consecutiveClarifications = 0
    // H.3 — same-target click stall: clarify after 10 clicks on the same targetIndex.
    private var consecutiveSameTargetClicks = 0
    private var lastClickTargetIndex: Int? = nil
    // H.4 — scroll stall: clarify after 10 consecutive scroll actions with no other action.
    private var consecutiveScrolls = 0
    // H.5a — same-keyCombo loop detector (Unit 17 / Path F). Counts how
    // many times the same RISKY-LOOP keyCombo text fired since the last
    // different action. Analogous to H.3 same-target clicks: dogfood
    // evidence (2026-05-27) showed the LLM emit `cmd+space` 5 times in
    // 12 actions (interleaved with typeText / wait) and no existing
    // stall detector fired because H.1/H.2/H.3/H.4 are single-action
    // consecutive counters.
    //
    // Reviewer-caught Sev-2 (scope): legitimate workflows like form-fill
    // (`typeText "Alice" → keyCombo tab → typeText "Smith" → keyCombo
    // tab → ...`) would trip a generic "same-keyCombo across the run"
    // counter at the 4th tab. To avoid this false-positive class, H.5a
    // ONLY counts keyCombos in `riskyLoopCombos` — Spotlight cycling
    // (`cmd+space`) and app-switch cycling (`cmd+tab`) are the
    // dogfood-evidenced anti-patterns. Tab navigation, paste cycles
    // (`cmd+v`), return key, etc. don't count.
    //
    // Threshold 4 — narrower than H.3's 10 because riskyLoopCombos
    // are typically used at most once per task; repeating them is
    // strong loop evidence.
    private var consecutiveSameKeyCombo = 0
    private var lastKeyComboText: String? = nil
    // H.6 — same-target switchApp loop detector (Unit 27). The Unit 25
    // audit surfaced a defensive re-emission pattern: the LLM emits
    // switchApp to a target, then on the very next step emits switchApp
    // to the SAME target — "to ensure it is the active application"
    // before interacting. Same failure CLASS as H.5a's Spotlight loop,
    // just routed through switchApp instead of keyCombo, so neither
    // H.5a (keyCombo-scoped) nor H.3 (click-scoped) catches it.
    //
    // Strict-consecutive — no fillers. The dogfood pattern is back-to-
    // back switchApps with no intermediate action. Allowing typeText/
    // wait as fillers (H.5a's pattern) would weaken the signal without
    // buying any legitimate workflow: there's no natural reason to
    // re-emit switchApp to the same bundle ID after an intermediate
    // step. Any non-switchApp action (or a switchApp to a DIFFERENT
    // bundle ID) resets the counter.
    //
    // Threshold 2 — more aggressive than H.5a's 4. switchApp's
    // "make sure it's frontmost" idiom is more contained than keyCombo's
    // (Spotlight has natural typing-between-opens). Threshold-2 catches
    // the failure on the second emission, before it cascades.
    private var consecutiveSameSwitchApp = 0
    private var lastSwitchAppTarget: String? = nil
    // H.5b — no-progress window detector (Unit 22 / Path D2). Counts
    // consecutive actions that produce no user-visible UI mutation.
    // Complements H.5a (specific risky-combo loop) with general
    // "stuck" coverage: a hypothetical "typeText × 12 in a row with
    // no click" pattern wouldn't trip H.5a but would trip H.5b.
    //
    // Progress-making actions (counter resets to 0):
    //   click, doubleClick, tripleClick, rightClick, menuSelect,
    //   switchApp, drag, complete.
    // Everything else increments: typeText, scroll, keyCombo, wait,
    // undo, clarify, holdKey, mouseDown/Up/Move.
    //
    // Threshold 12 — conservative. Form-fill workflows that tab
    // through many fields will push toward stall but rarely reach 12
    // without a click/submit. If dogfood evidence shows real false
    // positives, raise the threshold or expand the progress-list.
    private var actionsSinceProgress = 0
    private static let noProgressWindow = 12

    // Unit 23 (D8) — RISKY tier-floor from `TaskGuarding.tierFloor`.
    // Populated once at the start of `run()` from the task guard
    // (LLMTaskClassifier sets `.preview` when its Haiku call returns
    // RISKY for borderline-destructive tasks like "empty trash").
    // Consumed on step 1 only — `tier = max(tier, floor)` then cleared
    // to nil so subsequent steps follow the normal SafetyPolicy /
    // AutonomyMode / capability-rule chain. First-step-only is by
    // design: the operator confirms once, sees what the agent's about
    // to do, then runs free for the rest of the task.
    private var taskTierFloor: SafetyTier? = nil

    /// H.5b — true when the action type advances the UI in a way the
    /// operator would see. Click variants commit decisions, menuSelect
    /// navigates, switchApp changes focus, drag moves state, complete
    /// terminates. Everything else (typeText, scroll, keyCombo, wait,
    /// undo, clarify, holdKey, mouseDown/Up/Move) can be filler in a
    /// stall pattern — typing into a field that never gets submitted,
    /// scrolling that never finds the target, key combos that don't
    /// trigger anything.
    ///
    /// `internal` for testability — pinning the progress-list shape
    /// matters for the false-positive rate, and a future contributor
    /// adding an action type needs the test to fail-loud if they
    /// don't update this set.
    internal static func isProgressMakingAction(_ type: ActionType) -> Bool {
        switch type {
        case .click, .doubleClick, .tripleClick, .rightClick,
             .menuSelect, .switchApp, .drag, .complete, .writeFile:
            return true
        case .typeText, .scroll, .keyCombo, .wait, .undo,
             .clarify, .holdKey, .mouseDown, .mouseUp, .mouseMove, .say,
             .readClipboard:
            return false
        }
    }

    /// Combos H.5a counts as loop signals. Other keyCombos (tab,
    /// return, cmd+v, cmd+c, cmd+z, etc.) are legitimate to repeat
    /// and don't increment the counter.
    private static let riskyLoopCombos: Set<String> = [
        "cmd+space",            // Spotlight cycling — the dogfood-evidenced anti-pattern
        "cmd+tab",              // App-switch cycling — adjacent anti-pattern
        "cmd+option+escape",    // Force Quit dialog — irreversible system disruptor; repeated invocation is loop evidence
    ]
    /// Last bundle ID seen by `observe()`. Updated as soon as AX capture
    /// succeeds (before the vision-merge branch that might throw), so
    /// Unit 7's perception-throw catch can record the correct app in the
    /// throughline TaskRecord rather than "unknown". Reset to "unknown"
    /// at the start of every `run()` so a stale value from a prior run
    /// (when reusing an Orchestrator instance — tests do this) doesn't
    /// leak into the next run's audit trail. Promoted to actor instance
    /// state in the final-pass-review patch — previously local to run().
    private var lastObservedBundleID: String = "unknown"
    /// Unit 13b — true iff this Orchestrator instance has issued a
    /// `.mouseDown` and not yet observed the matching `.mouseUp` /
    /// terminal cleanup. Gates two things:
    ///   1. `heldMouseAtStart = await MouseHoldState.shared.isHeld()` —
    ///      only consulted when this run actually initiated a hold, so
    ///      a parallel-test Orchestrator that never touches the mouse
    ///      observes `false` regardless of what other tests have done
    ///      with the singleton.
    ///   2. `defer { … release() … }` — only fires the release Task
    ///      when this run initiated a hold, so non-mouse Orchestrator
    ///      runs don't race against parallel held-mouse tests.
    ///
    /// Flipped `true` after a successful `.mouseDown` act() call,
    /// `false` after a successful `.mouseUp`. Reset to `false` at the
    /// start of every `run()`.
    private var didInitiateMouseHold = false
    // Executor-error recovery budget — counts how many recovery passes have been attempted for the current run.
    // NOTE: the orchestrator is REUSED across runs (AppModel rebuilds it only
    // on settings/permission changes) — per-run state must be reset in
    // run()'s start block, never assumed fresh.
    private var recoveryStepsUsed = 0
    // Unit 40a — consecutive operator-drift yields; resets on any executed
    // action. After maxConsecutiveFrontmostDrifts the run pauses for the
    // operator instead of re-prompting the LLM every step (transcript + API
    // churn during a sustained takeover).
    private var consecutiveFrontmostDrifts = 0
    static let maxConsecutiveFrontmostDrifts = 5
    private let maxRecoverySteps = 3
    // LLM-error recovery budget — separate counter for think() failures (rate limits, transient
    // API errors, Claude hallucinations). Independent of the executor recovery budget so a single
    // transient LLM blip doesn't consume the executor recovery budget.
    private var thinkRecoveryStepsUsed = 0
    private let maxThinkRecoverySteps = 3
    // Plan step tracking — populated when the planner returns a multi-step plan.
    // currentPlanStep advances after each meaningful action: click, doubleClick,
    // tripleClick, rightClick, typeText, keyCombo, menuSelect, drag. Excluded:
    // scroll (positional), wait/complete/clarify (terminal/no-op), undo
    // (reverts; would double-advance), switchApp (setup not progress).
    private var planSteps: [String] = []
    private var currentPlanStep = 0

    // Tasks matching these prefixes are single-action by nature; skip the planner.
    private static let singleActionPrefixes = ["quit ", "close ", "open ", "click ", "press ", "scroll "]

    public init(
        llm: ActionThinking,
        perception: AXPerceiving,
        visionFallback: VisionPerceiving,
        executor: any ActionPerforming = Executor(),
        overlay: any OverlayControlling,
        // No defaults: both `ReceiptWriter()` and `ThroughlineStore()` no-arg
        // inits resolve to `~/Library/Application Support/MacAgent/`. Defaults
        // here let tests silently pollute the operator's prod files. Callers
        // pick the destination explicitly — Swift's type checker is the gate.
        receiptWriter: ReceiptWriter,
        throughlineStore: ThroughlineStore?,
        snapshotWriter: SnapshotWriter? = nil,
        ruleStore: CapabilityRuleStore? = nil,
        // Default is PermissiveTaskGuard to keep test injection ergonomic. Production
        // construction in AppModel.makeOrchestrator MUST override with KeywordTaskGuard
        // per MANIFEST.md §Phase Status F.6. Verified by AppModelTaskGuardTests.
        taskGuard: any TaskGuarding = PermissiveTaskGuard(),
        planner: TaskPlanning = NoOpPlanner(),
        maxSteps: Int = 50,
        gateTimeoutDuration: Duration = .seconds(60),
        // Unit 29c/29d — hard ceiling on how long a gate may stay parked
        // before it self-rejects (NEVER self-approves). nil = unbounded
        // park; the production default is 60 minutes, Settings-tunable. A
        // provider (autonomyModeProvider pattern) so mid-park Settings
        // changes apply at the next heartbeat. Bounds the synthetic-
        // keystroke approval window, the stale-approve window, and the
        // undecided-receipt gap that Unit 29's unbounded park opened.
        gateMaxParkDurationProvider: @escaping @Sendable () -> Duration? = { .seconds(3600) },
        parkJournal: PendingGateJournal? = nil,
        onEvent: (@Sendable (OrchestratorEvent) async -> Void)? = nil,
        autonomyModeProvider: @escaping @Sendable () -> AutonomyMode = { .semiAutonomous },
        runningAppsProvider: @escaping @Sendable () -> [RunningApp] = { [] }
    ) {
        self.llm = llm
        self.perception = perception
        self.visionFallback = visionFallback
        self.executor = executor
        self.overlay = overlay
        self.receiptWriter = receiptWriter
        self.throughlineStore = throughlineStore
        self.snapshotWriter = snapshotWriter
        self.ruleStore = ruleStore
        self.taskGuard = taskGuard
        self.planner = planner
        self.maxSteps = maxSteps
        self.gateTimeoutDuration = gateTimeoutDuration
        self.gateMaxParkDurationProvider = gateMaxParkDurationProvider
        self.parkJournal = parkJournal
        self.onEvent = onEvent
        self.autonomyModeProvider = autonomyModeProvider
        self.runningAppsProvider = runningAppsProvider
    }

    /// Inject a user message into the running agent's conversation. Safe to call at any time —
    /// the message is queued and consumed before the next think() call.
    public func sendMessage(_ text: String) {
        pendingUserMessages.append(text)
    }

    /// Reset conversation history and plan state. Only valid when not running.
    public func clearContext() async {
        guard !running else { return }
        conversationHistory.removeAll()
        pendingUserMessages.removeAll()
        planSteps = []
        currentPlanStep = 0
        await emit(.contextCleared)
    }

    public func run(task: String) async throws {
        guard !running else { return }
        running = true
        // Unit 30a — generation guard. AppModel's abort() drain is bounded
        // (5s): a run task wedged in a non-cancellable call can outlive the
        // abort, and a NEW run() may start before it un-wedges. The old
        // loop must then see a stale generation and exit at its next
        // loop-top check instead of resuming alongside the new loop (two
        // concurrent loops driving one executor was the failure mode).
        runGeneration += 1
        let myGeneration = runGeneration
        conversationHistory.removeAll()
        consecutiveWaits = 0
        needsFreshPerception = false
        consecutiveClarifications = 0
        consecutiveSameTargetClicks = 0
        lastClickTargetIndex = nil
        consecutiveScrolls = 0
        stallRecoveryAttempts = [:]
        visionUnavailableWarned = false
        consecutiveSupersedes = 0
        consecutiveFrontmostDrifts = 0
        gateHeartbeatCount = 0
        gateExpired = false
        parkJournalPending = false
        consecutiveSameKeyCombo = 0
        lastKeyComboText = nil
        consecutiveSameSwitchApp = 0
        lastSwitchAppTarget = nil
        actionsSinceProgress = 0
        taskTierFloor = nil
        planSteps = []
        currentPlanStep = 0
        // Defensive reset — AppModel creates a fresh Orchestrator per run so these counters
        // are already 0 at call time, but an explicit reset prevents surprise if the instance
        // is ever reused across sequential run() calls.
        recoveryStepsUsed = 0
        thinkRecoveryStepsUsed = 0
        didInitiateMouseHold = false

        // Load throughline and prepend any persistent context to the task prompt.
        let throughline = await throughlineStore?.load() ?? AgentThroughline()
        let context = throughline.promptBlock()
        // Sanitise the operator-typed task before it enters the prompt-bound copy.
        // The raw `task` parameter is preserved for UI surfaces (emit(.started),
        // overlay status, TaskRecord, taskGuard.shouldBlock) — only the LLM-facing
        // currentTask gets the newline / Unicode-separator strip.
        let safeTask = ClaudeLLMClient.sanitizeForPrompt(task)
        currentTask = context.isEmpty ? safeTask : "\(context)\n\nOperator task: \(safeTask)"

        // Task-level safety gate — runs before any LLM call or action.
        if let reason = await taskGuard.shouldBlock(task: task) {
            running = false
            await emit(.failed(message: "Task blocked by safety guard: \(reason)"))
            return
        }

        // Unit 23 — RISKY tier-floor. Same task guard, second method:
        // if the task is borderline (allowed but warrants first-step
        // operator confirmation), the guard returns `.preview`. The
        // default-extension implementation on `TaskGuarding` returns
        // nil, so `PermissiveTaskGuard` / `KeywordTaskGuard` are
        // unaffected; only `LLMTaskClassifier` (which has the semantic
        // judgment from its Haiku call) populates this. Cached read,
        // so no extra LLM call — `shouldBlock` already populated the
        // classifier's verdict cache for this task wording.
        taskTierFloor = await taskGuard.tierFloor(task: task)

        await emit(.started(task: task))
        await MainActor.run {
            overlay.setAbortHandler { [weak self] in
                Task { await self?.abort() }
            }
            overlay.updateStatus(task: task, tier: .preview, isRunning: true)
        }

        // Track run outcome for throughline update.
        var runOutcome = "aborted"
        // Chain fix — set by break paths that already recorded an "aborted"
        // outcome, so the post-loop catch-all below doesn't double-record.
        var recordedTerminalOutcome = false
        var stepCount = 0
        // Reset the actor-state bundle-ID tracker for this run — see the
        // property declaration above for rationale.
        lastObservedBundleID = "unknown"

        defer {
            // Chain fix (Sev-2) — a STALE run (superseded by a newer
            // generation after a wedged abort) must not tear down state the
            // new run owns: `running = false` would kill the new loop, and
            // updateStatus(isRunning: false) calls OverlayModel.reject(),
            // which would fire the NEW run's live gate callback — a phantom
            // resolution the operator never made. The stale run reaps
            // silently; only the mouse-hold release below stays
            // unconditional (gated on this run's own didInitiateMouseHold).
            if runGeneration == myGeneration {
                running = false
                Task { @MainActor in
                    overlay.updateStatus(task: "", tier: .auto, isRunning: false)
                }
                // Unit 13b — terminal-event cleanup chokepoint. Every exit
                // path from `run()` (success, failure, abort, cancellation,
                // step limit, stall, capability-deny return) funnels through
                // this defer, so a held mouse button cannot outlive the run.
                // `release()` is idempotent — the watchdog and the LLM's own
                // `.mouseUp` may have fired first, in which case this is a
                // no-op. Fire-and-forget Task is consistent with the
                // overlay-status update above.
                //
                // Gated on `didInitiateMouseHold` so non-mouse Orchestrator
                // runs (the overwhelming majority, especially in test
                // parallelism) NEVER touch the singleton. Production: gate
                // is true iff this run actually held a button. Tests:
                // parallel suites that don't drive mouseDown stay isolated
                // from suites that do. Inside the generation guard because
                // the flag is actor-shared: a STALE run reading it would see
                // the NEW run's live hold and release it out from under it;
                // a stale run's own orphaned hold falls to the 30s watchdog.
                let needsRelease = didInitiateMouseHold
                if needsRelease {
                    Task {
                        _ = await MouseHoldState.shared.release()
                    }
                }
            }
        }

        while running, runGeneration == myGeneration {
            stepCount += 1
            guard stepCount <= maxSteps else {
                runOutcome = "step_limit"
                await emit(.stepLimitReached(stepCount: maxSteps))
                await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                break
            }

            // Warn the user when 90% of the step budget has been spent so they
            // can intervene before the run terminates abruptly at maxSteps.
            let warningStep = Int(Double(maxSteps) * 0.9)
            if stepCount == warningStep {
                // 34a — .warning, not .executionFinished: this exists so the
                // operator can intervene BEFORE the abrupt stop; routed as
                // .executionFinished it folded into the simple mode's
                // collapsed activity groups.
                await emit(.warning(message: "⚠️ Approaching step limit (\(stepCount)/\(maxSteps)). The agent will stop after \(maxSteps - stepCount) more steps unless the task completes first."))
            }

            await MainActor.run { overlay.updatePhase("Observing…") }
            // Unit 7 — chokepoint cleanup for perception throws (AX permissions
            // revoked, agent-frontmost guard from Unit 5, snapshot-creation
            // failure, vision-fallback errors). Pre-Unit-7, an observe() throw
            // bypassed all 18 throughline-record sites because each lived in a
            // different code branch INSIDE the loop; the run died without an
            // operator-telemetry entry. This catch records once + emits .failed
            // before rethrowing. CancellationError is rethrown without recording
            // (operator-initiated abort is not a "failure" in the throughline
            // sense, per the existing convention at think()/act() catches).
            // Capture the prior bundleID BEFORE observe() — observe() now
            // updates `lastObservedBundleID` itself as soon as the AX walk
            // succeeds (final-pass-review patch, so Unit 7's catch can
            // record the correct app on a vision-merge throw).
            let prevBundleID = lastObservedBundleID
            let observed: ObservedSnapshot
            do {
                observed = try await observe()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                runOutcome = "error"
                await emit(.failed(message: error.localizedDescription))
                await throughlineStore?.record(TaskRecord(
                    task: task, outcome: runOutcome,
                    stepCount: stepCount, appBundleID: lastObservedBundleID
                ))
                throw error
            }
            // Emit appSwitched on any bundle-ID change so the conversation panel always
            // reflects where the agent's focus is, regardless of how the switch occurred.
            if prevBundleID != "unknown", prevBundleID != lastObservedBundleID {
                await emit(.appSwitched(from: prevBundleID, to: lastObservedBundleID))
            }
            await emit(.observed(appBundleID: observed.snapshot.focusedAppBundleID, elementCount: observed.snapshot.elements.count))

            // Unit 19 — snapshot sidecar persistence (opt-in). Fire-
            // and-forget so the snapshot write never blocks the loop.
            // Dedupe-by-hash inside SnapshotWriter means same UI state
            // across multiple receipts in a run is one file, not N.
            // nil writer = feature off; no Task spawned. Snapshot is
            // immutable + Sendable → safe to capture.
            if let snapshotWriter {
                let snapshotForPersist = observed.snapshot
                Task {
                    await snapshotWriter.persist(snapshotForPersist)
                }
            }

            // On the first step, ask the planner to decompose the task — but skip for
            // trivially short tasks or single-action prefixes to avoid a wasted Haiku call.
            if stepCount == 1 {
                let wordCount = task.split(separator: " ").count
                let isSimple = wordCount <= 6
                    || Self.singleActionPrefixes.contains(where: { task.lowercased().hasPrefix($0) })
                if !isSimple, let plan = await planner.plan(task: task, snapshot: observed.snapshot) {
                    let base = currentTask
                    // The planner is itself an LLM call — its output is model-controlled
                    // untrusted text. Preserve '\n' (the numbered-list separator the LLM
                    // expects) but strip Unicode line separators U+2028/U+2029, NEL, etc.
                    // that would forge prompt sections inside step bodies.
                    let safePlan = plan.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { ClaudeLLMClient.sanitizeForPrompt(String($0)) }
                        .joined(separator: "\n")
                    currentTask = "\(base)\n\n\(safePlan)"
                    planSteps = Self.parsePlanSteps(from: safePlan)
                    currentPlanStep = 0
                    if planSteps.count > 1 {
                        await emit(.planProgress(steps: planSteps, currentStep: 0))
                    } else {
                        // Single-step or parse failure — fall back to old conversation message.
                        // Use safePlan so raw planner newlines / U+2028 don't reach the UI panel.
                        await emit(.executionFinished(result: "📋 Plan: \(safePlan.split(separator: "\n").dropFirst().prefix(3).joined(separator: " | "))"))
                    }
                }
            }

            // Drain any messages the user sent mid-run into conversation history so
            // the next think() call sees them. Emits .userMessageQueued for each.
            let queued = pendingUserMessages
            pendingUserMessages.removeAll()
            for msg in queued {
                conversationHistory.append(LLMMessage(role: "user", content: msg))
                await emit(.userMessageQueued(text: msg))
            }

            // Wrap think() separately from act() so transient LLM errors can retry
            // without consuming the executor recovery budget and without emitting .failed
            // prematurely.
            await MainActor.run { overlay.updatePhase("Thinking…") }
            let action: AgentAction
            do {
                action = try await think(snapshot: observed.snapshot)
            } catch let orcError as OrchestratorError {
                switch orcError {
                case .transientLLMFailure(let message):
                    // Retryable — inject a recovery note and continue the loop.
                    needsFreshPerception = true
                    guard thinkRecoveryStepsUsed < maxThinkRecoverySteps else {
                        runOutcome = "error"
                        await emit(.failed(
                            message: "LLM failed after \(maxThinkRecoverySteps) retries: \(message)"))
                        await throughlineStore?.record(TaskRecord(
                            task: task, outcome: runOutcome,
                            stepCount: stepCount, appBundleID: lastObservedBundleID))
                        throw orcError
                    }
                    thinkRecoveryStepsUsed += 1
                    conversationHistory.append(LLMMessage(
                        role: "user",
                        content: "The LLM call failed transiently: \(message). Retry \(thinkRecoveryStepsUsed)/\(maxThinkRecoverySteps)."))
                    await emit(.recovering(
                        message: "LLM call failed — retrying (\(thinkRecoveryStepsUsed)/\(maxThinkRecoverySteps)): \(message)"))
                    continue
                case .permissionsRevoked, .apiKeyMissing:
                    // Fatal — .failed already emitted inside think() or upstream. Hard stop.
                    runOutcome = "error"
                    await throughlineStore?.record(TaskRecord(
                        task: task, outcome: runOutcome,
                        stepCount: stepCount, appBundleID: lastObservedBundleID))
                    throw orcError
                }
            } catch let e as CancellationError {
                throw e
            }

            // H.3 — same-target click stall (pre-gate, pre-execution).
            // Detecting repeated click PROPOSALS avoids needing a successful executor call,
            // which isn't guaranteed in all environments (e.g. headless CI).
            let isClickType = action.type == .click || action.type == .rightClick
                || action.type == .doubleClick || action.type == .tripleClick
            if isClickType, let idx = action.targetIndex {
                if lastClickTargetIndex == idx {
                    consecutiveSameTargetClicks += 1
                } else {
                    consecutiveSameTargetClicks = 1
                    lastClickTargetIndex = idx
                }
            } else if isClickType {
                // Click with no targetIndex — treat as a distinct action, reset same-target counter.
                consecutiveSameTargetClicks = 0
                lastClickTargetIndex = nil
            } else if action.type != .say {
                // Unit 33 — say is a FILLER for this detector: chatter
                // between identical clicks must not reset the streak, or
                // the LLM could defeat H.3 by narrating between retries.
                consecutiveSameTargetClicks = 0
                lastClickTargetIndex = nil
            }
            if consecutiveSameTargetClicks >= 10 {
                consecutiveSameTargetClicks = 0
                lastClickTargetIndex = nil
                if await handleStall(detector: "sameTargetClick",
                                     hint: "You have clicked the same element 10 times without progress. The element is not responding to clicks — try a different element, a menu path, or a keyboard route.",
                                     action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount) {
                    continue
                }
                runOutcome = "stalled"
                break
            }

            // H.5a — same-keyCombo loop detector (Unit 17 / Path F).
            // Dogfood evidence (2026-05-27): the LLM emitted `cmd+space`
            // 5 times in 12 actions for an "Open Notes" task, interleaved
            // with `typeText` and `wait`. None of H.1–H.4 fired because
            // they're single-action consecutive counters. H.5a counts
            // RISKY-LOOP keyCombo occurrences across the run (analogous to
            // H.3 same-target clicks): the lastKeyComboText threading
            // means "5 cmd+space's across 12 actions" still counts
            // because the counter only resets on a DIFFERENT risky combo
            // OR a non-keyCombo action that isn't wait/typeText.
            //
            // Scoped to `riskyLoopCombos` (cmd+space, cmd+tab) so
            // legitimate workflows that repeat tab / cmd+v / return /
            // etc. don't trip. Pre-gate, pre-execution — same rationale
            // as H.3. Threshold 4.
            if action.type == .keyCombo, let combo = action.text?.lowercased() {
                if Self.riskyLoopCombos.contains(combo) {
                    // Risky combo — increment if same-text, restart at 1 if different risky combo.
                    if lastKeyComboText == combo {
                        consecutiveSameKeyCombo += 1
                    } else {
                        consecutiveSameKeyCombo = 1
                        lastKeyComboText = combo
                    }
                } else {
                    // Non-risky keyCombo (tab, cmd+v, return, cmd+l, ...) —
                    // RESET. A legitimate intervening keyCombo signals the
                    // agent is making varied progress, not looping. Example:
                    // `cmd+space cmd+space tab cmd+space cmd+space` is NOT
                    // a Spotlight loop because tab broke the streak with
                    // intentional input.
                    consecutiveSameKeyCombo = 0
                    lastKeyComboText = nil
                }
            } else if action.type != .typeText && action.type != .wait && action.type != .say {
                // typeText/wait are filler between risky-combo repeats
                // in the dogfood pattern (cmd+space → typeText → wait →
                // cmd+space → ...) — they neither increment nor reset.
                // Anything else (click, switchApp, menuSelect, ...)
                // resets — those are user-visible progress signals.
                consecutiveSameKeyCombo = 0
                lastKeyComboText = nil
            }
            if consecutiveSameKeyCombo >= 4 {
                let comboName = lastKeyComboText ?? "(unknown)"
                consecutiveSameKeyCombo = 0
                lastKeyComboText = nil
                if await handleStall(detector: "sameRiskyKeyCombo",
                                     hint: "You have emitted '\(comboName)' 4 times without it producing progress. If you are trying to open or switch apps, use the `switchApp` action with a bundle ID instead of Spotlight/cmd+tab cycling.",
                                     action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount) {
                    continue
                }
                runOutcome = "stalled"
                break
            }

            // H.6 — same-target switchApp loop detector (Unit 27).
            // Live T2 audit surfaced defensive re-emission: the LLM
            // emits switchApp to a target, then on the next step emits
            // switchApp to the same target "to ensure it is the active
            // application" before interacting. Same failure class as
            // H.5a's Spotlight loop, routed through switchApp.
            //
            // Strict-consecutive matching — no fillers. Any non-switchApp
            // action (or switchApp to a different bundle ID) resets.
            // Bundle IDs are case-insensitive: "com.apple.Notes" and
            // "com.apple.notes" match. nil text on switchApp resets
            // (malformed emission — not a valid same-target signal).
            //
            // Pre-gate, pre-execution. Threshold 2 — fires on the
            // second consecutive same-target switchApp.
            if action.type == .switchApp, let target = action.text?.lowercased() {
                if lastSwitchAppTarget == target {
                    consecutiveSameSwitchApp += 1
                } else {
                    consecutiveSameSwitchApp = 1
                    lastSwitchAppTarget = target
                }
            } else if action.type != .say {
                // Any non-switchApp action (or malformed switchApp with
                // nil text) breaks the streak. Unlike H.5a, no OS-action
                // fillers: defensive switchApp is back-to-back, so even
                // typeText/wait reset. 33a: say is the exception — it is a
                // strict no-op (nothing on screen can change during it), so
                // switchApp→say→switchApp alternation must not evade H.6;
                // switchApp itself resets the H.5b backstop, making this
                // the one full-evasion pair the fleet found.
                consecutiveSameSwitchApp = 0
                lastSwitchAppTarget = nil
            }
            if consecutiveSameSwitchApp >= 2 {
                let target = lastSwitchAppTarget ?? "(unknown)"
                consecutiveSameSwitchApp = 0
                lastSwitchAppTarget = nil
                if await handleStall(detector: "sameSwitchAppLoop",
                                     hint: "You have emitted switchApp to '\(ClaudeLLMClient.sanitizeForPrompt(target))' twice in a row. The target app is already frontmost — interact with it now (click, typeText, keyCombo, menuSelect), do not emit another switchApp.",
                                     action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount) {
                    continue
                }
                runOutcome = "stalled"
                break
            }

            // H.5b — no-progress window detector (Unit 22 / Path D2).
            // Complements H.5a's specific risky-combo detection with
            // general "stuck" coverage. A user-visible-progress action
            // resets the counter; everything else increments. When the
            // counter hits noProgressWindow (12), the run has burned
            // 12 actions in a row without advancing the UI — that's
            // a stall regardless of which actions filled the window.
            //
            // Pre-gate, parallel to H.3 + H.5a. The detector that
            // fires first wins; H.5a's narrower threshold (4 vs 12)
            // means it catches Spotlight-loop variants before H.5b's
            // window expires — both detectors are correct, both add
            // distinct coverage.
            // Unit 30 — stash the pre-update value: a click that is later
            // SUPERSEDED (29b stale-approval guard) never executed, so it
            // must not have counted as progress; the supersede branch
            // restores from this stash.
            let actionsSinceProgressBefore = actionsSinceProgress
            if Self.isProgressMakingAction(action.type) {
                actionsSinceProgress = 0
            } else {
                actionsSinceProgress += 1
            }
            if actionsSinceProgress >= Self.noProgressWindow {
                actionsSinceProgress = 0
                if await handleStall(detector: "noProgressWindow",
                                     hint: "You have taken \(Self.noProgressWindow) actions without any user-visible progress (no clicks, menu selections, app switches, drags, or completion). The current approach is not moving the UI forward — switch to a different strategy.",
                                     action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount) {
                    continue
                }
                runOutcome = "stalled"
                break
            }

            let baseTier = SafetyPolicy.classify(action, snapshot: observed.snapshot)
            let mode = autonomyModeProvider()
            var tier = mode.adjustedTier(for: action, baseTier: baseTier)

            // Unit 23 (D8) — RISKY tier-floor from LLMTaskClassifier.
            // First-step-only: an operator who confirms the FIRST
            // action of a borderline-destructive task (e.g. "empty
            // trash") has signed off on the trajectory; subsequent
            // steps follow the normal SafetyPolicy + AutonomyMode +
            // capability chain. Clearing the floor immediately after
            // applying it makes the consumption explicit — a future
            // contributor who moves the apply-site won't accidentally
            // double-apply or forget to clear. Promote-only via
            // `max(tier, floor)`; never lowers tier.
            var appliedTierFloor: SafetyTier? = nil
            if let floor = taskTierFloor {
                tier = max(tier, floor)
                taskTierFloor = nil
                appliedTierFloor = floor
            }

            // Unit 13b — capture the held-mouse state ONCE before any
            // tier branching. Used by (1) `SafetyPolicy.heldMouseAdjusted`
            // below to promote cross-cutting actions to `.confirm` while
            // a button is held, and (2) every ActionLogEntry receipt so
            // the post-hoc audit can correlate tier elevations with the
            // OS-state at classification time. Snapshot semantics: a
            // `.mouseDown` that starts the hold sees `false` here (the
            // tracker is updated by the executor only AFTER post); the
            // subsequent actions during the hold see `true`.
            //
            // The `didInitiateMouseHold` gate prevents a parallel-test
            // Orchestrator from observing another suite's held state
            // through the singleton. In production exactly one
            // Orchestrator runs at a time per AppModel; the gate is a
            // no-op there. In test parallelism it isolates suites that
            // never touch the mouse from suites that do.
            let heldMouseAtStart: Bool = didInitiateMouseHold
                ? await MouseHoldState.shared.isHeld()
                : false

            // Capability rule evaluation — Option C placement: between AutonomyMode and gate.
            // SafetyPolicy is the hard floor: allow rules can't widen destructive/sensitive actions.
            if let verdict = await ruleStore?.evaluate(action, observed.snapshot) {
                switch verdict {
                case .deny:
                    // Hard block — write a rejection receipt and exit the run loop.
                    await emit(.proposed(action: action, tier: .confirm))
                    await MainActor.run { overlay.updatePhase(nil); overlay.updateStatus(task: task, tier: .confirm, isRunning: true) }
                    let stepStart = ContinuousClock.now
                    await writeRejectionReceipt(action: action, tier: .confirm, stepStart: stepStart, snapshotHash: observed.snapshot.hash, heldMouseAtStart: heldMouseAtStart)
                    runOutcome = "rejected"
                    await emit(.failed(message: "Action blocked by capability rule: \(action.type.rawValue)"))
                    await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                    running = false
                    return  // jump past all remaining loop body; defer handles overlay cleanup
                case .allow:
                    // Widen `.confirm` → `.preview` only. Previously this branch
                    // also widened `.preview` → `.auto`, which silently auto-promoted
                    // intrinsically-preview actions (typeText, menuSelect, switchApp,
                    // risky combos like cmd+w) once the user clicked "Always". That's
                    // a behavioral surprise — the HUD copy "Always allow this action
                    // type" doesn't convey that the tier widens. Narrowed here so
                    // `allow` rules only reduce friction on actions that would
                    // otherwise have demanded explicit confirmation.
                    if !SafetyPolicy.isDestructiveOrSensitive(action, snapshot: observed.snapshot),
                       tier == .confirm {
                        tier = .preview
                    }
                case .ask:
                    // Force at least preview.
                    if tier == .auto { tier = .preview }
                }
            }

            // Unit 13b — held-mouse invariant has the FINAL word on tier.
            // Applied after capability-rule evaluation so an `allow` rule
            // can never widen a cross-cutting action below `.confirm`
            // while a button is held. Only promotes (auto/preview → confirm);
            // never downgrades.
            tier = SafetyPolicy.heldMouseAdjusted(tier: tier, action: action, heldMouseAtStart: heldMouseAtStart)

            await emit(.proposed(action: action, tier: tier))
            await MainActor.run {
                overlay.updatePhase(nil)   // action is known — clear observe/think phase label
                overlay.updateStatus(task: task, tier: tier, isRunning: true)
            }

            let stepStart = ContinuousClock.now
            if tier != .auto {
                await emit(.approvalRequired(action: action, tier: tier))
            }
            lastGateSnapshotHash = observed.snapshot.hash
            let decision = await gate(action, tier: tier)
            // Unit 29d — the journal is deliberately NOT cleared here. It
            // clears at the writeReceipt() chokepoint, i.e. only once a
            // receipt for this gated step is durably on disk. Clearing at
            // decision time left a crash window spanning the supersede
            // re-observe plus the whole act() execution in which a DECIDED
            // action had neither receipt nor journal entry — zero trace.
            // The cost is the safe direction: a crash after the receipt but
            // before the clear yields one extra reconciliation entry whose
            // wording accounts for a possibly-also-receipted decision.

            // Persist never-allow immediately — it's a rejection-side decision
            // and the loop breaks below before the supersede check could run.
            // The ALLOW rule is persisted later, after the 29b stale-approval
            // re-check passes: an "always allow" granted against a screen the
            // supersede guard rules too stale to act on must not outlive that
            // superseded approval (fleet finding — the re-proposed gate
            // re-offers alwaysAllow against fresh state).
            if decision == .neverAllow {
                let rule = CapabilityRule(
                    verdict: .deny, actionType: action.type,
                    appBundleID: observed.snapshot.focusedAppBundleID)
                await ruleStore?.add(rule)
            }

            let approved = decision == .approveOnce || decision == .alwaysAllow
            if !approved {
                // Unit 29c — three distinct non-approval causes, three honest
                // records: ceiling expiry (self-reject after the park window),
                // abort (operator kill or dead-run guard — NOT a "user
                // rejected this action" event; convention matches the act()
                // catch, which records "aborted" and emits no .failed), and
                // a real human reject.
                let expired = gateExpired
                gateExpired = false
                let aborted = !expired && (!running || Task.isCancelled)
                await writeRejectionReceipt(
                    action: action, tier: tier, stepStart: stepStart,
                    snapshotHash: observed.snapshot.hash,
                    heldMouseAtStart: heldMouseAtStart,
                    executionResult: expired
                        ? "rejected — approval window expired with no decision"
                        : aborted ? "rejected — run aborted before a decision"
                                  : "rejected")
                runOutcome = expired ? "expired" : aborted ? "aborted" : "rejected"
                if !aborted {
                    await emit(.failed(message: expired
                        ? "Approval window expired with no decision — task stopped safely. Dictate the task again, then press Send to retry."
                        : "Action was rejected by the user."))
                }
                await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                recordedTerminalOutcome = true
                break
            }

            // In read-only mode show the proposed action in the HUD but skip execution.
            // 33a — say has no execution to skip: speak normally and continue
            // (the contentless "[Watch] Would have: say" bubble carried no
            // message, since say's message lives in rationale, not text).
            if mode == .readOnly, action.type == .say {
                await emit(.agentSaid(message: action.rationale))
                needsFreshPerception = false
                continue
            }
            if mode == .readOnly {
                // Nothing executes in watch mode, so the stale-approval
                // supersede check below never runs — persist the allow rule
                // here to preserve pre-relocation behavior for this path.
                // Chain fix: EXCEPT when the gate parked (>=1 heartbeat) —
                // an "always" granted against an hours-old screen must not
                // become a standing rule that widens future EXECUTING runs
                // (the pre-relocation baseline assumed the old 60s park
                // bound, which Unit 29 removed). The re-proposed gate in a
                // live run re-offers Always against fresh state.
                // Unit 36 — never persist a standing allow rule for writeFile:
                // a confirm-tier disk write must be approved every time, or
                // an "always allow" would auto-write to the workspace on
                // future runs. (neverAllow/deny is still fine — denying is safe.)
                if decision == .alwaysAllow, gateHeartbeatCount == 0, action.type != .writeFile {
                    let label = action.targetIndex.flatMap { idx -> String? in
                        guard idx < observed.snapshot.visionIndexOffset, idx < observed.snapshot.elements.count else { return nil }
                        return observed.snapshot.elements[idx].label
                    }
                    let rule = CapabilityRule(
                        verdict: .allow, actionType: action.type,
                        appBundleID: observed.snapshot.focusedAppBundleID,
                        labelPattern: label.map { "\($0)*" })
                    await ruleStore?.add(rule)
                }
                await emit(.executionFinished(result: "[Watch] Would have: \(action.type.rawValue)\(action.text.map { " — \"\($0)\"" } ?? "")"))
                // Watch mode writes no execution receipt, so the receipt
                // chokepoint can't clear a parked-gate journal entry — do
                // it here or the next launch reconciles a resolved gate.
                if parkJournalPending {
                    await parkJournal?.clear()
                    parkJournalPending = false
                }
                needsFreshPerception = false
                continue
            }

            // Unit 29b — stale-snapshot guard on approve-after-park. With no
            // auto-reject (Unit 29), an approval can arrive hours after the
            // action was proposed; the action's targetIndex and SafetyPolicy
            // tier were computed against the screen as it was THEN, and the
            // executor's CGEvent fallback would click those coordinates
            // blind. If the gate heartbeated at least once (the run sat
            // parked past a full timeout interval), re-observe and act only
            // if the screen is structurally identical; otherwise record the
            // approval as superseded and let the LLM re-propose against
            // fresh state. Structural comparison, NOT snapshot.hash — the
            // hash payload includes the capture timestamp, so hash equality
            // would spuriously flag every unchanged screen as changed.
            if gateHeartbeatCount > 0 {
                needsFreshPerception = true
                let prevBundleID = lastObservedBundleID
                let fresh: ObservedSnapshot
                do {
                    fresh = try await observe()
                } catch {
                    // The decision WAS made — the receipt must exist even
                    // when the re-check observe() throws (AX revoked during
                    // a long park is the realistic case; cancellation if
                    // abort races the approve). Mirror the act() catch:
                    // receipt first, then the cancellation rethrow, then
                    // the Unit-7-style failure record for everything else.
                    let duration = Int(stepStart.duration(to: .now).milliseconds)
                    let receipt = ActionLogEntry(
                        action: action,
                        tier: tier.rawValue,
                        approved: true,
                        executionResult: "error: stale-approval re-check failed before acting — \(error.localizedDescription)",
                        durationMs: duration,
                        snapshotHash: observed.snapshot.hash,
                        heldMouseAtStart: heldMouseAtStart
                    )
                    do {
                        try await writeReceipt(receipt)
                    } catch {
                        await emit(.receiptWriteFailed(message: error.localizedDescription))
                    }
                    if error is CancellationError {
                        // Match the act() catch: an abort racing the approve
                        // still records a throughline entry for the run.
                        runOutcome = "aborted"
                        await throughlineStore?.record(TaskRecord(
                            task: task, outcome: runOutcome,
                            stepCount: stepCount, appBundleID: lastObservedBundleID))
                        throw error
                    }
                    runOutcome = "error"
                    let allowNote = decision == .alwaysAllow
                        ? " (your \"always allow\" choice was not saved — re-approve when the action is re-proposed)" : ""
                    await emit(.failed(message: error.localizedDescription + allowNote))
                    await throughlineStore?.record(TaskRecord(
                        task: task, outcome: runOutcome,
                        stepCount: stepCount, appBundleID: lastObservedBundleID))
                    throw error
                }
                // The re-observe stamps lastObservedBundleID, which would
                // suppress the loop-top .appSwitched emit on the next
                // iteration — surface a park-time app switch here instead.
                if prevBundleID != "unknown", prevBundleID != lastObservedBundleID {
                    await emit(.appSwitched(from: prevBundleID, to: lastObservedBundleID))
                }
                // captureOrigin included: vision bboxes are capture-region-
                // relative, so identical content in a MOVED window must NOT
                // compare "unchanged" (the executor would offset by the
                // stale origin and click the old screen location).
                let unchanged = fresh.snapshot.focusedAppBundleID == observed.snapshot.focusedAppBundleID
                    && fresh.snapshot.elements == observed.snapshot.elements
                    && fresh.snapshot.visionObservations == observed.snapshot.visionObservations
                    && fresh.snapshot.captureOrigin == observed.snapshot.captureOrigin
                if !unchanged {
                    let duration = Int(stepStart.duration(to: .now).milliseconds)
                    let receipt = ActionLogEntry(
                        action: action,
                        tier: tier.rawValue,
                        approved: true,
                        executionResult: "superseded — screen changed while parked awaiting approval; action re-proposed against fresh perception",
                        durationMs: duration,
                        snapshotHash: observed.snapshot.hash,
                        heldMouseAtStart: heldMouseAtStart
                    )
                    do {
                        try await writeReceipt(receipt)
                    } catch {
                        await emit(.receiptWriteFailed(message: error.localizedDescription))
                    }
                    await emit(.warning(message: "Screen changed while waiting for approval — re-checking before acting."))
                    conversationHistory.append(LLMMessage(role: "user", content: "The approved \(action.type.rawValue) action was NOT executed: the screen changed while waiting for approval. Re-evaluate against the current UI snapshot and propose the next action."))
                    needsFreshPerception = true
                    // Unit 30 — a superseded action never executed, so it
                    // must not have reset the H.5b progress window (the
                    // reset happened pre-gate, at propose time). Restore,
                    // counting this step as a non-progress action.
                    actionsSinceProgress = actionsSinceProgressBefore + 1
                    // Unit 30a — symmetric restore: a superseded step-1
                    // action never executed, so the Unit-23 RISKY tier
                    // floor it consumed must re-apply to the next proposal.
                    if let floor = appliedTierFloor {
                        taskTierFloor = floor
                    }
                    // Unit 30 — supersede-churn guard (29c fleet deferral).
                    // A volatile screen (timer, badge, animation) can
                    // supersede every post-park approval; route the churn
                    // through the stall machinery so it self-recovers
                    // twice (hint: the LLM may pick a stabler target) and
                    // then stops honestly instead of silently burning the
                    // step budget on approve-supersede cycles.
                    consecutiveSupersedes += 1
                    if consecutiveSupersedes >= 3 {
                        consecutiveSupersedes = 0
                        if await handleStall(detector: "supersedeChurn",
                                             hint: "Three approved actions in a row were superseded because the screen kept changing between approval and execution. The target UI appears volatile — pick a target that does not change (a stable button or menu path), or the task may not be completable while this screen keeps updating.",
                                             action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount, heldMouseAtStart: heldMouseAtStart) {
                            continue
                        }
                        runOutcome = "stalled"
                        break
                    }
                    continue
                }
            }

            // Unit 30a — the supersede re-check passed (or never applied):
            // this is a genuine, non-superseded execution attempt, so the
            // approve-supersede churn streak is broken HERE, before act().
            // Resetting only on act() success undercounted: an approved
            // action that threw in act() still interrupted the churn.
            // 33a — except say: a no-op cannot break the churn streak.
            if action.type != .say {
                consecutiveSupersedes = 0
            }

            // Persist the always-allow rule only now — past the supersede
            // check — so an "always" granted against a screen ruled too
            // stale to act on never becomes a standing rule. Unit 36 —
            // writeFile is excluded: confirm-tier disk writes get no standing
            // allow rule.
            if decision == .alwaysAllow, action.type != .writeFile {
                let label = action.targetIndex.flatMap { idx -> String? in
                    guard idx < observed.snapshot.visionIndexOffset, idx < observed.snapshot.elements.count else { return nil }
                    return observed.snapshot.elements[idx].label
                }
                let rule = CapabilityRule(
                    verdict: .allow, actionType: action.type,
                    appBundleID: observed.snapshot.focusedAppBundleID,
                    labelPattern: label.map { "\($0)*" })
                await ruleStore?.add(rule)
            }

            do {
                let result = try await act(action, snapshot: observed)
                consecutiveFrontmostDrifts = 0  // 40a — an action executed; drift streak broken.
                // Chain fix (Sev-2) — act() is where a non-cancellable
                // executor/AX call can wedge past the abort drain. If a
                // newer run started while we were wedged, everything past
                // this point (journal clear, events, history, counters)
                // belongs to that run. Record the executed action honestly
                // via the writer directly — NOT writeReceipt, whose
                // journal-clear would destroy the new run's parked-gate
                // entry — then reap.
                guard runGeneration == myGeneration else {
                    let staleReceipt = ActionLogEntry(
                        action: action, tier: tier.rawValue, approved: true,
                        executionResult: result,
                        durationMs: Int(stepStart.duration(to: .now).milliseconds),
                        snapshotHash: observed.snapshot.hash,
                        heldMouseAtStart: heldMouseAtStart)
                    try? await receiptWriter.write(staleReceipt)
                    return
                }
                // Unit 13b — track hold ownership at this Orchestrator
                // instance. A successful mouseDown means *this run* now
                // owns a live hold; a successful mouseUp means we don't.
                // The flag gates `heldMouseAtStart` capture and the
                // defer release so parallel-test isolation holds.
                if action.type == .mouseDown {
                    didInitiateMouseHold = true
                } else if action.type == .mouseUp {
                    didInitiateMouseHold = false
                }
                let duration = Int(stepStart.duration(to: .now).milliseconds)
                let receipt = ActionLogEntry(
                    action: Self.receiptSafeAction(action),
                    tier: tier.rawValue,
                    approved: true,
                    executionResult: result,
                    durationMs: duration,
                    snapshotHash: observed.snapshot.hash,
                    heldMouseAtStart: heldMouseAtStart
                )
                do {
                    try await writeReceipt(receipt)
                } catch {
                    await emit(.receiptWriteFailed(message: error.localizedDescription))
                }
                if action.type == .say {
                    await emit(.agentSaid(message: action.rationale))
                } else {
                    await emit(.executionFinished(result: result))
                }

                // Unit 25e — conversation grounding. The next think() call
                // will see this user turn before the LLM's prior assistant
                // rationale. Without it the history accumulates consecutive
                // assistant turns (one per action) which the model reasons
                // through as "unconfirmed prior intent" — surfacing as
                // defensive re-actions on long trajectories. The audit-mode
                // T2 smoke at 9/10 reproduced this with the Notes 3-step
                // scenario; adding the observation closes the gap.
                // Wording stays neutral ("observed") so the LLM isn't
                // primed toward premature .complete.
                // PARITY-ANCHOR: history-append — ActionRegressionScenarios
                // and MultiStepHarnessTests mirror this exact append; grep
                // the anchor name when re-verifying parity (line numbers
                // drift, the anchor does not).
                conversationHistory.append(LLMMessage(role: "user", content: "Previous action observed: \(result)"))

                // Advance the plan step pointer after each meaningful action.
                // Meaningful = actions that make real UI progress (not wait/scroll/complete/clarify).
                let isMeaningfulAction: Bool
                switch action.type {
                case .click, .doubleClick, .tripleClick, .rightClick, .typeText,
                     .keyCombo, .menuSelect, .drag, .holdKey:
                    isMeaningfulAction = true
                default:
                    isMeaningfulAction = false
                }
                if isMeaningfulAction, !planSteps.isEmpty, currentPlanStep < planSteps.count - 1 {
                    currentPlanStep += 1
                    await emit(.planProgress(steps: planSteps, currentStep: currentPlanStep))
                }

                if action.type == .wait {
                    consecutiveWaits += 1
                    // Force a fresh perception pass every 3 waits so the agent
                    // doesn't loop forever on a stale snapshot.
                    if consecutiveWaits % 3 == 0 {
                        needsFreshPerception = true
                    }
                } else if action.type != .say {
                    // 33a — say is a filler here too (wait+say alternation
                    // must not slip H.1 onto the slower H.5b backstop).
                    consecutiveWaits = 0
                    needsFreshPerception = true
                }

                if consecutiveWaits >= 10 {
                    consecutiveWaits = 0
                    if await handleStall(detector: "wait",
                                         hint: "You have waited 10 times without progress. Waiting is not advancing the task — act on the current UI state or change strategy.",
                                         action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount, durationMs: Int(stepStart.duration(to: .now).milliseconds), heldMouseAtStart: heldMouseAtStart) {
                        continue
                    }
                    runOutcome = "stalled"
                    break
                }

                // H.4 — scroll stall: 10 consecutive scrolls with no other action.
                if action.type == .scroll {
                    consecutiveScrolls += 1
                } else if action.type != .say {
                    // 33a — say filler, same rationale as H.1.
                    consecutiveScrolls = 0
                }
                if consecutiveScrolls >= 10 {
                    consecutiveScrolls = 0
                    if await handleStall(detector: "scroll",
                                         hint: "You have scrolled 10 times without finding the target. It is probably not on this page — try a search field, a menu path, or a different container instead of more scrolling.",
                                         action: action, snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount, durationMs: Int(stepStart.duration(to: .now).milliseconds), heldMouseAtStart: heldMouseAtStart) {
                        continue
                    }
                    runOutcome = "stalled"
                    break
                }

            } catch let driftError as ExecutorError where {
                if case .frontmostDrifted = driftError { return true }; return false
            }() {
                // Unit 40/40a — operator-drift YIELD. NOT an agent failure:
                // the operator took over the frontmost app. Record a NEUTRAL
                // receipt (not "error:"), don't burn recovery budget, don't
                // scold. Re-observe against the new reality (which follows the
                // operator's app via Unit 8 tracking); never re-assert focus.
                guard runGeneration == myGeneration else { return }
                guard case let .frontmostDrifted(_, expectedApp, liveApp) = driftError else { break }
                let duration = Int(stepStart.duration(to: .now).milliseconds)
                let receipt = ActionLogEntry(
                    action: action, tier: tier.rawValue, approved: false,
                    executionResult: "yielded — user switched frontmost app to \(liveApp); action not executed",
                    durationMs: duration, snapshotHash: observed.snapshot.hash,
                    heldMouseAtStart: heldMouseAtStart)
                do { try await writeReceipt(receipt) }
                catch { await emit(.receiptWriteFailed(message: error.localizedDescription)) }

                consecutiveFrontmostDrifts += 1
                needsFreshPerception = true
                let expName = expectedApp.split(separator: ".").last.map(String.init) ?? expectedApp
                let liveName = liveApp.split(separator: ".").last.map(String.init) ?? liveApp
                // After a sustained takeover, stop re-prompting the LLM every
                // step (transcript + API churn) — pause for the operator.
                if consecutiveFrontmostDrifts >= Self.maxConsecutiveFrontmostDrifts {
                    runOutcome = "yielded"
                    await emit(.failed(message: "You've been working in \(liveName) — I've paused. Send a message or bring \(expName) forward when you want me to continue."))
                    await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                    recordedTerminalOutcome = true
                    break
                }
                await emit(.warning(message: "You switched from \(expName) to \(liveName) — pausing that action and re-checking the screen."))
                conversationHistory.append(LLMMessage(role: "user", content: "The user switched the frontmost app from \(expectedApp) to \(liveApp) before your last \(action.type.rawValue) ran, so it was NOT executed. A fresh snapshot follows. If your task still needs \(expectedApp), switchApp back to it; otherwise continue with the current app. Do not repeat the action until the right app is frontmost."))
                continue
            } catch {
                consecutiveFrontmostDrifts = 0
                let duration = Int(stepStart.duration(to: .now).milliseconds)
                let receipt = ActionLogEntry(
                    action: action,
                    tier: tier.rawValue,
                    approved: true,
                    executionResult: "error: \(error.localizedDescription)",
                    durationMs: duration,
                    snapshotHash: observed.snapshot.hash,
                    heldMouseAtStart: heldMouseAtStart
                )
                // Chain fix (Sev-2) — same wedge re-entry as the success
                // path: a stale generation records its receipt directly and
                // reaps without touching the new run's state.
                guard runGeneration == myGeneration else {
                    try? await receiptWriter.write(receipt)
                    return
                }
                do {
                    try await writeReceipt(receipt)
                } catch {
                    await emit(.receiptWriteFailed(message: error.localizedDescription))
                }
                // Force fresh perception on next step so the agent sees post-failure state.
                needsFreshPerception = true

                // CancellationError means the user aborted — no autonomous recovery.
                // (Task.sleep in .wait can throw CancellationError on abort.)
                guard !(error is CancellationError) else {
                    runOutcome = "aborted"
                    await emit(.failed(message: "Task was cancelled."))
                    await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                    throw error
                }

                // Attempt a recovery pass — inject failure context and re-enter the loop.
                // `running` is still true here; `continue` re-enters `while running { }`.
                if recoveryStepsUsed < maxRecoverySteps {
                    recoveryStepsUsed += 1
                    // Unit 14 — when the error carries stale-index context,
                    // use a specific recovery prompt that names the dead
                    // index + label + current element count. Receipt
                    // evidence (2026-05-23) shows the LLM re-picks the same
                    // dead index across multiple fresh snapshots when given
                    // only the generic recovery prompt — `needsFreshPerception
                    // = true` happens (already set above) but the LLM
                    // doesn't see the specific hint in conversation history.
                    let recoveryContent: String
                    if case let ExecutorError.targetStale(actionType, idx, count, label) = error {
                        let labelHint = label.map { " (the element previously labelled '\($0)' is gone or has reflowed)" } ?? ""
                        // The "Do NOT retry index N" instruction is scoped
                        // to the NEXT snapshot only — on dynamic UIs (web
                        // pages, animated state) the same index N can be
                        // reassigned to a different element after reflow.
                        // Tell the LLM the instruction is one-shot so it
                        // doesn't over-correct and permanently avoid the
                        // index for the rest of the run.
                        recoveryContent = "The last action (\(actionType.rawValue)) targeted index \(idx) but that index is no longer in the current snapshot (snapshot now has \(count) elements)\(labelHint). Recovery attempt \(recoveryStepsUsed)/\(maxRecoverySteps). A fresh snapshot will be taken on the next step — pick a NEW targetIndex from the fresh perception. Do NOT retry index \(idx) against the upcoming snapshot. (If a later snapshot reassigns index \(idx) to a different element, you may use it then — this prohibition applies only to the immediately following observation.)"
                    } else if case let ExecutorError.targetDisabled(actionType, idx, label) = error {
                        // Unit 18B — element exists but is disabled.
                        // Different recovery hint than .targetStale: the
                        // LLM needs to either pick a different element
                        // OR satisfy the enabling condition (fill a
                        // required field, dismiss a modal, wait for
                        // loading state). "Re-observe" alone isn't
                        // sufficient — the element will still be
                        // disabled until the precondition is met.
                        let labelPart = label.map { "'\($0)'" } ?? "(unlabelled)"
                        let target: String
                        if let idx {
                            target = "the element at index \(idx) labelled \(labelPart)"
                        } else {
                            target = "menu item \(labelPart)"
                        }
                        recoveryContent = "The last action (\(actionType.rawValue)) targeted \(target), but that element is in the snapshot YET DISABLED (greyed out, not yet interactable). Recovery attempt \(recoveryStepsUsed)/\(maxRecoverySteps). Re-observing alone won't help — the element stays disabled until its enabling condition is satisfied. Either (a) pick a DIFFERENT element to act on, OR (b) satisfy the precondition first (e.g. fill required fields before pressing Submit, dismiss a modal blocking interaction, wait for a loading state to finish). Do NOT retry the same disabled target without changing the surrounding state first."
                    } else {
                        recoveryContent = "The last action (\(action.type.rawValue)) failed: \(error.localizedDescription). Recovery attempt \(recoveryStepsUsed)/\(maxRecoverySteps). Use 'undo' to reverse any partial change, or try a different approach. Do not repeat the action that just failed."
                    }
                    conversationHistory.append(LLMMessage(role: "user", content: recoveryContent))
                    await emit(.recovering(message: "Step \(stepCount) failed — attempting recovery (\(recoveryStepsUsed)/\(maxRecoverySteps))"))
                    continue
                }

                // Recovery budget exhausted — declare failure.
                runOutcome = "error"
                await emit(.failed(message: "Recovery failed after \(maxRecoverySteps) attempts: \(error.localizedDescription)"))
                await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                throw error
            }

            let visionOffset = observed.snapshot.visionIndexOffset
            if let idx = action.targetIndex, idx >= 0, idx < visionOffset {
                // AX element — highlight using the stored frame (screen points).
                let rect = observed.snapshot.elements[idx].frame.cgRect
                await MainActor.run { overlay.highlight(frame: rect) }
            } else if let idx = action.targetIndex, idx >= visionOffset {
                // Vision element — convert pixel bbox to screen points for the highlight.
                let visionIdx = idx - visionOffset
                let observations = observed.snapshot.visionObservations
                if visionIdx < observations.count {
                    let box = observations[visionIdx].boundingBox
                    let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
                    let origin = observed.snapshot.captureOrigin.cgPoint
                    let rect = CGRect(
                        x: origin.x + box.x / scale,
                        y: origin.y + box.y / scale,
                        width: box.width / scale,
                        height: box.height / scale
                    )
                    await MainActor.run { overlay.highlight(frame: rect) }
                } else {
                    await MainActor.run { overlay.clearHighlight() }
                }
            } else {
                await MainActor.run { overlay.clearHighlight() }
            }

            if action.type == .complete {
                // If the agent signals complete on step 1 it has done zero real work —
                // escalate to confirm so the user can verify the task is actually done.
                if stepCount == 1 {
                    lastGateSnapshotHash = observed.snapshot.hash
                    await emit(.approvalRequired(action: action, tier: .confirm))
                    let confirmDecision = await gate(action, tier: .confirm)
                    // No rule persistence here — this is an internal safety escalation
                    // for step-1 .complete, not a user-driven allow/deny for a real action.
                    // Persisting .alwaysAllow/.neverAllow here would be far too broad
                    // (scoped to .complete in any app, permanently bypassing the step-1 gate).
                    let confirmApproved = confirmDecision == .approveOnce || confirmDecision == .alwaysAllow
                    if !confirmApproved {
                        // Chain fix — mirror the main gate's three-way
                        // attribution (29c): ceiling expiry and abort are
                        // not operator rejections, and abort emits no
                        // .failed per the act()-catch convention.
                        let expired = gateExpired
                        gateExpired = false
                        let aborted = !expired && (!running || Task.isCancelled)
                        await writeRejectionReceipt(
                            action: action, tier: .confirm, stepStart: stepStart,
                            snapshotHash: observed.snapshot.hash,
                            heldMouseAtStart: heldMouseAtStart,
                            executionResult: expired
                                ? "rejected-immediate-complete — approval window expired with no decision"
                                : aborted ? "rejected-immediate-complete — run aborted before a decision"
                                          : "rejected-immediate-complete")
                        runOutcome = expired ? "expired" : aborted ? "aborted" : "rejected"
                        if !aborted {
                            await emit(.failed(message: expired
                                ? "Approval window expired with no decision — task stopped safely. Dictate the task again, then press Send to retry."
                                : "Immediate completion signal rejected. The agent declared done without taking any action."))
                        }
                        await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                        recordedTerminalOutcome = true
                        break
                    }
                    // Chain fix — an APPROVED parked gate must not leave its
                    // crash journal behind (the writeReceipt chokepoint never
                    // runs on this break path); a stale entry becomes a false
                    // "unresolved at shutdown" reconciliation at next launch.
                    if parkJournalPending {
                        await parkJournal?.clear()
                        parkJournalPending = false
                    }
                }
                runOutcome = "success"
                await emit(.finished)
                await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                break
            }

            if action.type == .clarify {
                await emit(.clarificationRequested(message: action.rationale))
                // Unit 32 — gate parity. Suspend until the operator answers
                // (resume(withClarification:)), aborts, or the wall-clock
                // approval wait limit expires. The old 240+60s timeout
                // auto-resumed with "(no reply — timed out)" — answering the
                // agent's question FOR the operator with a fabricated
                // assumption, exactly the slow-voice-operator failure class
                // Unit 29 removed from gates. A heartbeat (same cadence and
                // ceiling as .approvalPending) beeps each interval instead.
                // 32a (fleet Sev-2) — mirror the gate's 29a dead-run guard:
                // abort() interleaving during the emit suspension above finds
                // pendingClarification still nil, so its deliverClarification
                // no-ops; parking now would strand a DEAD run until the
                // ceiling fires a phantom .failed into a possibly-newer run
                // (the orchestrator is REUSED across runs).
                guard running, !Task.isCancelled else { break }
                clarifyParkStart = .now
                let question = action.rationale
                let userReply = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    pendingClarification = continuation
                    let interval = gateTimeoutDuration
                    clarificationTimeoutTask = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: interval)
                            if Task.isCancelled { return }
                            guard let self else { return }
                            await self.emitClarificationHeartbeat(message: question)
                        }
                    }
                }
                // 32a — post-suspension reaping guard (parity with the
                // post-act re-entry points): a stale generation must not
                // emit terminals or touch shared history/counters.
                guard runGeneration == myGeneration else { break }
                if userReply == Self.clarifyExpiredSentinel {
                    runOutcome = "expired"
                    await emit(.failed(message: "No answer arrived within the approval wait limit — task stopped safely. Dictate the task again, then press Send to retry."))
                    await throughlineStore?.record(TaskRecord(task: task, outcome: runOutcome, stepCount: stepCount, appBundleID: lastObservedBundleID))
                    recordedTerminalOutcome = true
                    break
                }
                // 32a — an abort resumes the park with "(aborted)"; it must
                // exit via the loop condition (post-loop "aborted" record),
                // not fall into the H.2 branch and mislabel the run as a
                // clarify-DoS stall with a post-abort .failed.
                if !running { continue }
                // Inject the clarification as context and keep the loop running.
                conversationHistory.append(LLMMessage(role: "user", content: userReply))
                needsFreshPerception = true
                consecutiveWaits = 0
                consecutiveScrolls = 0  // reset scroll stall counter alongside waits on clarify
                // H.2 — consecutive clarification DoS guard.
                consecutiveClarifications += 1
                if consecutiveClarifications >= 3 {
                    runOutcome = "stalled"
                    await recordStall(action: action, detector: "clarifyDoS", snapshotHash: observed.snapshot.hash, task: task, stepCount: stepCount, heldMouseAtStart: heldMouseAtStart)
                    await emit(.failed(message: "Agent asked for clarification 3 times in a row without making progress. Task stopped. Dictate the task again with more detail, then press Send to retry."))
                    break
                }
                continue
            }
            // Non-clarify action reached — reset the clarification stall
            // counter. Unit 33: say is a filler here too, or alternating
            // clarify/say would bypass the H.2 DoS guard.
            if action.type != .say {
                consecutiveClarifications = 0
            }

            shouldForceVisualCheck = action.type == .wait
        }

        // Chain fix — an abort that lands during a clarify suspension or a
        // stall self-recovery `continue` exits via the loop CONDITION, not a
        // recording break: without this, those aborted runs left no
        // throughline entry (unlike aborts at a parked gate or inside act()).
        // Stale-generation exits skip: telemetry belongs to the newer run.
        if runGeneration == myGeneration, !running,
           runOutcome == "aborted", !recordedTerminalOutcome {
            await throughlineStore?.record(TaskRecord(
                task: task, outcome: "aborted",
                stepCount: stepCount, appBundleID: lastObservedBundleID))
        }
    }

    public func abort() {
        running = false
        resumeGate(decision: .rejectOnce)
        deliverClarification("(aborted)")
    }

    /// Called by the UI when the user answers a clarification question.
    /// The orchestrator loop is suspended waiting for this; calling it resumes the run.
    public func resume(withClarification text: String) {
        deliverClarification(text)
    }

    public var isClarifying: Bool {
        pendingClarification != nil
    }

    private func deliverClarification(_ text: String) {
        // Cancel the background timeout Task so it doesn't linger for the full 300s (240+60)
        // after the user has already replied. This matters most in tests where replies are
        // immediate, but also reclaims resources in production when users reply quickly.
        clarificationTimeoutTask?.cancel()
        clarificationTimeoutTask = nil
        guard let continuation = pendingClarification else { return }
        pendingClarification = nil
        continuation.resume(returning: text)
    }

    /// Unit 32 — internal sentinel: the clarify ceiling delivers this as the
    /// "reply" so the clarify branch can distinguish expiry from a real
    /// answer (the continuation type is String; a side-channel flag would
    /// race a genuine concurrent resume). Exposed internally for tests.
    static let clarifyExpiredSentinel = "\u{0}clarify-expired\u{0}"

    /// Unit 32 — heartbeat for a parked clarification, actor-isolated and
    /// re-checked after every suspension point (same races as the gate
    /// heartbeat: a stale iteration must not beep after resolution, and a
    /// human answer landing during the emit must keep its own attribution).
    /// The wall-clock ceiling reuses the gate's provider — one operator
    /// setting bounds both kinds of park — and EXPIRES the question (the
    /// run stops safely; it never auto-answers with an assumption).
    private func emitClarificationHeartbeat(message: String) async {
        guard pendingClarification != nil else { return }
        await emit(.clarificationPending(message: message))
        guard pendingClarification != nil else { return }
        if let maxPark = gateMaxParkDurationProvider(),
           let parkStart = clarifyParkStart,
           parkStart.duration(to: .now) >= maxPark {
            deliverClarification(Self.clarifyExpiredSentinel)
        }
    }

    private func observe() async throws -> ObservedSnapshot {
        // Abort sets running=false and cancels the outer Task. Check here so perception
        // and vision capture are skipped immediately rather than waiting to complete.
        try Task.checkCancellation()
        let forceRefresh = needsFreshPerception
        needsFreshPerception = false
        var observed: ObservedSnapshot
        do {
            observed = try await perception.capture(forceRefresh: forceRefresh)
        } catch AXPerceptionError.permissionsRevoked {
            // Re-map so callers see a single OrchestratorError type.
            throw OrchestratorError.permissionsRevoked
        }
        // Final-pass-review patch: stamp the AX walk's bundleID into
        // `lastObservedBundleID` as soon as AX capture succeeds — BEFORE
        // any vision-merge attempt that might throw. Pre-fix, if Unit 8's
        // fallback walked Notes' AX tree successfully but then the vision
        // merge threw, Unit 7's catch wrote `appBundleID: "unknown"` to
        // the throughline because the bundleID was only set after observe()
        // returned. The throughline audit entry now correctly names the
        // app that was actually walked.
        lastObservedBundleID = observed.snapshot.focusedAppBundleID
        if observed.snapshot.elements.isEmpty || shouldForceVisualCheck {
            do {
                let capture = try await visionFallback.captureVisualContext()
                if capture.usedFullScreenFallback {
                    await emit(.warning(message: "⚠️ Vision fallback: capturing the full display. Text from background apps may be included — agent will try to focus on the target app."))
                }
                let merged = try PerceptionSnapshot.make(
                    timestamp: observed.snapshot.timestamp,
                    focusedAppBundleID: observed.snapshot.focusedAppBundleID,
                    elements: observed.snapshot.elements,
                    visionObservations: capture.observations,
                    visionUsedFullScreenFallback: capture.usedFullScreenFallback,
                    captureOrigin: capture.captureOrigin,
                    // Forward screenshot + capture-time logical size from the source
                    // snapshot. Cluster E added these fields; the vision-merge path
                    // pre-followup dropped them on the floor, so ComputerUseClient
                    // running on a hybrid AX+vision merged snapshot fell through to
                    // the live-screen fallback and silently broke descale math when
                    // the display geometry had changed since capture.
                    screenshotPNG: observed.snapshot.screenshotPNG,
                    screenshotLogicalSize: observed.snapshot.screenshotLogicalSize,
                    // Unit 9 — preserve fallback-overlay flag across the vision
                    // merge. Pre-fix, a snapshot from AXPerception's fallback
                    // path that subsequently hit the vision-merge branch would
                    // drop the flag and the LLM prompt would lose its switchApp
                    // warning. Same forwarding rationale as screenshotPNG above.
                    agentIsOverlaid: observed.snapshot.agentIsOverlaid
                )
                observed = ObservedSnapshot(snapshot: merged, lookup: observed.lookup)
            } catch is CancellationError {
                // Abort during capture must propagate — never swallowed.
                throw CancellationError()
            } catch {
                // Screen Recording is OPTIONAL (vision fallback only, per the
                // permissions banner). A capture failure — TCC declined, display
                // asleep, transient ScreenCaptureKit error after the in-capture
                // retries — must NOT kill the run. Degrade to the AX-only snapshot
                // and surface one clear, actionable warning instead of the cryptic
                // TCC crash. Safety is unaffected: every proposed action still runs
                // through SafetyPolicy + the gate regardless of perception quality,
                // so reduced perception only narrows what the agent can DO, never
                // what it can do WITHOUT approval. Live-found 2026-06-15: an
                // AX-empty screen + ungranted Screen Recording hard-failed the run
                // with "declined TCCs for ... display capture", contradicting the
                // banner's "Screen Recording optional" promise.
                if !visionUnavailableWarned {
                    visionUnavailableWarned = true
                    await emit(.warning(message: "⚠️ Vision unavailable (\(error.localizedDescription)). Proceeding with accessibility data only — grant Screen Recording in Settings for vision fallback on apps with little accessibility data."))
                }
            }
        }
        shouldForceVisualCheck = false
        return observed
    }

    private func think(snapshot: PerceptionSnapshot) async throws -> AgentAction {
        // Check before the LLM call so a cancelled Task aborts immediately rather than
        // waiting up to 30s for the URLSession timeout.
        try Task.checkCancellation()
        // Append current plan position so the LLM knows which step is active on every call.
        // currentTask already contains the full plan block (injected on step 1); this adds a
        // per-call marker without mutating currentTask or changing the ActionThinking protocol.
        // planSteps is empty when the planner was skipped (simple task) — no injection in that case.
        let taskWithProgress: String
        if !planSteps.isEmpty {
            // Plan-step labels come from the planner's text output via parsePlanSteps,
            // which splits on '\n' only. Unicode line separators (U+2028, U+2029, NEL,
            // etc.) can survive into the label and forge prompt sections downstream of
            // the PLAN PROGRESS marker on every think() call. Sanitise before injection.
            let label = ClaudeLLMClient.sanitizeForPrompt(planSteps[currentPlanStep])
            taskWithProgress = "\(currentTask)\n\n[PLAN PROGRESS: step \(currentPlanStep + 1) of \(planSteps.count) — \"\(label)\"]"
        } else {
            taskWithProgress = currentTask
        }
        do {
            let action = try await llm.nextAction(
                task: taskWithProgress,
                snapshot: snapshot,
                history: conversationHistory,
                runningApps: runningAppsProvider()
            )
            conversationHistory.append(LLMMessage(role: "assistant", content: action.rationale))
            // Unit 25e — cap bumped 6 → 12. Each completed action now
            // contributes TWO messages (assistant rationale + user
            // observation injected after successful act()). 12 preserves
            // the prior effective 6-action history depth under the new
            // pairing. Worst-case impact: 6 extra short messages per
            // long-trajectory call; negligible vs system prompt size.
            // PARITY-ANCHOR: history-cap — mirrored by the T2 harness.
            if conversationHistory.count > 12 {
                conversationHistory.removeFirst(conversationHistory.count - 12)
            }
            return action
        } catch let error as LLMError {
            switch error {
            case .missingAPIKey:
                // Fatal — user must add their API key. Emit .failed immediately; no retry.
                await emit(.failed(message: error.localizedDescription))
                throw OrchestratorError.apiKeyMissing
            case .rateLimited, .api, .malformedResponse:
                // Transient — outer loop will retry. Don't emit .failed yet.
                throw OrchestratorError.transientLLMFailure(
                    "LLM error: \(error.localizedDescription)")
            }
        } catch let error as DecodingError {
            // Claude hallucinated invalid JSON — transient, outer loop will retry.
            // Include decoding context so the recovery message is actionable.
            let context: String
            switch error {
            case .keyNotFound(let key, _):
                context = "missing field '\(key.stringValue)'"
            case .typeMismatch(_, let ctx):
                context = "type mismatch at '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'"
            case .valueNotFound(_, let ctx):
                context = "null value at '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'"
            case .dataCorrupted(let ctx):
                context = ctx.debugDescription
            @unknown default:
                context = String(describing: error)
            }
            throw OrchestratorError.transientLLMFailure(
                "Claude returned an unparseable action (\(context)). Retrying.")
        }
    }

    /// Parses a planner output string into individual step labels.
    /// Filters to numbered lines (e.g. "1. Click X") and strips the numeric prefix.
    /// Returns empty array if the plan has fewer than 2 parseable steps.
    public static func parsePlanSteps(from plan: String) -> [String] {
        let steps = plan
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let first = line.first else { return false }
                return first.isNumber
            }
            .compactMap { line -> String? in
                // Strip "1. " or "1) " prefix.
                if let dotIdx = line.firstIndex(where: { $0 == "." || $0 == ")" }),
                   line.index(after: dotIdx) < line.endIndex {
                    let after = line.index(after: dotIdx)
                    return line[after...].trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
        return steps.count >= 2 ? steps : []
    }

    private func gate(_ action: AgentAction, tier: SafetyTier) async -> ApprovalDecision {
        // Reset BEFORE the .auto early return — an auto-tier action that
        // follows a parked gate must not inherit the previous gate's
        // heartbeat count and trigger a spurious stale-approval re-check.
        gateHeartbeatCount = 0
        gateExpired = false
        guard tier != .auto else { return .approveOnce }
        // Unit 29a — abort() can interleave between the loop's `running`
        // check and the park below (e.g. during the .approvalRequired emit
        // suspension). Its resumeGate(.rejectOnce) no-ops on the still-nil
        // continuation, and with no auto-reject the gate would park forever.
        // Refuse to park on a dead run: the caller's rejection path still
        // writes the receipt and breaks the loop.
        guard running, !Task.isCancelled else { return .rejectOnce }
        gateParkStart = .now
        return await withCheckedContinuation { continuation in
            pendingGateContinuation = continuation
            Task { @MainActor in
                overlay.setPendingAction(action) { [weak self] decision in
                    Task { await self?.resumeGate(decision: decision) }
                }
            }
            // Unit 29 — park-and-pause instead of auto-reject. Previously
            // the timeout fired `resumeGate(.rejectOnce)`, which killed the
            // whole run after `gateTimeoutDuration` (default 60s) if the
            // operator didn't answer in time. For a hands-free operator,
            // whose approval latency is inherently higher (notice the HUD,
            // invoke Voice Control, speak the command), that made every
            // gate a 60s run-death window. Now the timeout NEVER resolves
            // the continuation — the run stays parked on the gate — and
            // instead emits `.approvalPending` as a recurring heartbeat so
            // the operator gets an audible cue each interval. The gate
            // resolves ONLY on an explicit decision (HUD / launcher /
            // Unit-28 hotkey); the Abort hotkey is the escape. No
            // auto-reject means the `.confirm`-never-auto invariant is
            // strengthened, not weakened: the action still never fires
            // without explicit approval, and now it also never gets
            // auto-rejected out from under a slow operator.
            //
            // Capture by value before the closure so a nil [weak self]
            // can't change the heartbeat interval.
            let duration = gateTimeoutDuration
            gateTimeoutTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: duration)
                    if Task.isCancelled { return }
                    guard let self else { return }
                    await self.emitApprovalHeartbeat(action: action, tier: tier)
                }
            }
        }
    }

    /// Unit 29a — heartbeat emission is actor-isolated and re-checks that the
    /// gate is still parked. Cancellation of the heartbeat task is cooperative,
    /// so an iteration already past its isCancelled check could otherwise
    /// deliver one stale .approvalPending after resumeGate resolved the gate
    /// (overwriting "Aborted" status with "Paused", carrying the old action).
    private func emitApprovalHeartbeat(action: AgentAction, tier: SafetyTier) async {
        guard pendingGateContinuation != nil else { return }
        gateHeartbeatCount += 1
        // Unit 29c — crash-safe audit trail. A gate that lingers past one
        // full timeout interval gets journaled so a quit/crash during the
        // park still leaves evidence the action was proposed. Cleared at
        // the receipt-write chokepoint once a receipt for the gated step
        // is durably on disk; consumed by AppModel at next launch into a
        // reconciliation receipt if it was never cleared.
        if gateHeartbeatCount == 1, let journal = parkJournal {
            await journal.record(PendingGateJournal.Entry(
                action: action, tier: tier.rawValue,
                snapshotHash: lastGateSnapshotHash))
            parkJournalPending = true
            // The file write suspended us — the gate may have resolved in
            // the meantime. Emitting then would replay the 29a stale-beep
            // bug for heartbeat 1.
            guard pendingGateContinuation != nil else { return }
        }
        await emit(.approvalPending(action: action, tier: tier))
        // Unit 29c/29d — park ceiling on ELAPSED wall-clock time (survives
        // machine sleep: ContinuousClock advances while the lid is closed,
        // so an overnight park expires on the first post-wake heartbeat).
        // The gate self-REJECTS (never approves — .confirm-never-auto is
        // preserved; expiry is the safe direction). Bounds the window in
        // which a synthetic F13 from a rogue AX-granted process could
        // approve an unattended gate, and the stale-approve window.
        // Re-check parked-ness first: the emit above suspended, and a human
        // decision landing in that window must keep its own attribution —
        // setting gateExpired after resolution would mislabel it "expired".
        guard pendingGateContinuation != nil else { return }
        if let maxPark = gateMaxParkDurationProvider(),
           let parkStart = gateParkStart,
           parkStart.duration(to: .now) >= maxPark {
            gateExpired = true
            resumeGate(decision: .rejectOnce)
        }
    }

    private func resumeGate(decision: ApprovalDecision) {
        guard let continuation = pendingGateContinuation else { return }
        pendingGateContinuation = nil
        gateTimeoutTask?.cancel()
        gateTimeoutTask = nil
        continuation.resume(returning: decision)
    }

    private func act(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        try await executor.perform(action, snapshot: snapshot)
    }

    /// 36a — the persisted receipt for a writeFile must not store the file
    /// CONTENTS in cleartext: the executionResult already carries the path +
    /// a sha256 (the integrity record), and the contents are off-screen file
    /// data, more sensitive than typed UI text. Null the `text` so the
    /// on-disk JSONL holds the hash, not the bytes. (typeText keeps its
    /// documented cleartext-by-design posture, redacted only at display.)
    static func receiptSafeAction(_ action: AgentAction) -> AgentAction {
        guard action.type == .writeFile else { return action }
        return AgentAction(
            type: action.type, targetIndex: action.targetIndex, text: nil,
            scrollDelta: action.scrollDelta, confidence: action.confidence,
            requiresConfirmation: action.requiresConfirmation, rationale: action.rationale,
            coordinate: action.coordinate, modifiers: action.modifiers,
            startCoordinate: action.startCoordinate, durationMs: action.durationMs,
            filePath: action.filePath)
    }

    private func writeReceipt(_ entry: ActionLogEntry) async throws {
        try await receiptWriter.write(entry)
        // Unit 29d — clear the pending-gate journal only AFTER a receipt
        // for the parked step landed on disk (write failure keeps the
        // journal, so launch reconciliation compensates for the missing
        // receipt). gateHeartbeatCount > 0 scopes this to the step whose
        // gate actually parked; clear() is idempotent.
        if parkJournalPending {
            await parkJournal?.clear()
            parkJournalPending = false
        }
    }

    /// Builds and writes a rejection receipt (approved: false) for the given action.
    /// Swallows write errors via an in-conversation warning so a receipt failure never
    /// terminates the loop — the caller decides how to handle the rejection itself.
    private func writeRejectionReceipt(
        action: AgentAction,
        tier: SafetyTier,
        stepStart: ContinuousClock.Instant,
        snapshotHash: String,
        heldMouseAtStart: Bool = false,
        executionResult: String = "rejected"
    ) async {
        let receipt = ActionLogEntry(
            action: action,
            tier: tier.rawValue,
            approved: false,
            executionResult: executionResult,
            durationMs: Int(stepStart.duration(to: .now).milliseconds),
            snapshotHash: snapshotHash,
            heldMouseAtStart: heldMouseAtStart
        )
        do {
            try await writeReceipt(receipt)
        } catch {
            await emit(.receiptWriteFailed(message: error.localizedDescription))
        }
    }

    /// Unit 18A — chokepoint for the H-series stall detectors.
    /// Writes a rejection receipt + records throughline so the stalled
    /// action lands in the audit trail. Caller still handles the
    /// detector-specific `emit(...)` (since events differ — most stalls
    /// emit `.clarificationRequested` but H.2 emits `.failed`) and the
    /// `break` out of the run loop.
    ///
    /// Receipt semantics:
    ///   - `tier: "confirm"` — "in retrospect, this should have required
    ///     confirmation." The action may have been classified `.auto` at
    ///     emit time, but a rejection-class receipt warrants the
    ///     escalated tier label.
    ///   - `approved: false` — the action did not (or, for post-execute
    ///     stalls, will no longer) be permitted to proceed.
    ///   - `executionResult: "stalled-\(detector)"` — single tag that
    ///     `MacAgentReplay --errors` can grep for to surface every stall
    ///     class.
    ///
    /// Pre-existing convention before this unit: NO stall site wrote a
    /// receipt for the action that tripped it. Post-execute stalls
    /// (H.1, H.4) had a SUCCESS receipt for the action that ran; this
    /// adds a SECOND receipt that records the stall fired. Two distinct
    /// facts deserve two distinct receipts.
    /// Unit 30 — stall self-recovery chokepoint for the H-series detectors
    /// (except H.2 clarifyDoS, which is already an honest terminal). The
    /// first `stallRecoveryBudget` firings of a detector inject the
    /// detector's hint into conversation history as a corrective user turn
    /// and keep the run alive — the LLM usually CAN change strategy once
    /// told exactly what loop it is in, and killing the run on first
    /// detection forced a hands-free operator to re-dictate the whole task.
    /// The firing after the budget is terminal — and HONESTLY terminal:
    /// `.failed`, not the old `.clarificationRequested`-then-break, which
    /// told the operator to answer a question whose reply channel was
    /// already dead (pendingClarification was never armed; the reply went
    /// nowhere). Every firing writes a `stalled-<detector>` receipt;
    /// only the terminal firing records a throughline outcome, because a
    /// recovered stall is a step-level event, not a run outcome.
    ///
    /// Pre-act sites (H.3/H.5a/H.6/H.5b, supersedeChurn) SUPPRESS the
    /// offending proposal — it never reaches classify()/gate/act. The
    /// post-act sites (H.1 wait, H.4 scroll) fire after the action already
    /// executed (its success receipt stands); their recovery only redirects
    /// the NEXT proposal.
    ///
    /// Returns true to continue the run (self-recovery), false to break.
    /// Callers reset their detector's own counter so the detector re-arms
    /// from zero rather than re-firing on the next action.
    private func handleStall(
        detector: String,
        hint: String,
        action: AgentAction,
        snapshotHash: String,
        task: String,
        stepCount: Int,
        durationMs: Int = 0,
        heldMouseAtStart: Bool? = nil
    ) async -> Bool {
        let attempts = stallRecoveryAttempts[detector, default: 0] + 1
        stallRecoveryAttempts[detector] = attempts
        if attempts <= Self.stallRecoveryBudget {
            await recordStall(action: action, detector: detector, snapshotHash: snapshotHash, task: task, stepCount: stepCount, durationMs: durationMs, heldMouseAtStart: heldMouseAtStart, recordThroughline: false)
            await emit(.warning(message: "Stall detected (\(detector)) — self-recovering, attempt \(attempts) of \(Self.stallRecoveryBudget)."))
            // Drain queued operator messages FIRST so the corrective hint
            // stays the most recent turn — the prompt windows history by
            // recency (suffix 6 Claude / 4 CU) and a burst of dictated
            // notes landing after the hint could evict it unseen.
            let queued = pendingUserMessages
            pendingUserMessages.removeAll()
            for msg in queued {
                conversationHistory.append(LLMMessage(role: "user", content: msg))
                await emit(.userMessageQueued(text: msg))
            }
            conversationHistory.append(LLMMessage(role: "user", content: "STALL DETECTED: \(hint) Change strategy now — do not repeat the previous action pattern."))
            needsFreshPerception = true
            return true
        }
        await recordStall(action: action, detector: detector, snapshotHash: snapshotHash, task: task, stepCount: stepCount, durationMs: durationMs, heldMouseAtStart: heldMouseAtStart)
        await emit(.failed(message: "Stalled (\(detector)) — task stopped after \(Self.stallRecoveryBudget) self-recovery attempts. \(hint) Dictate the task again, then press Send to retry."))
        return false
    }

    private func recordStall(
        action: AgentAction,
        detector: String,
        snapshotHash: String,
        task: String,
        stepCount: Int,
        durationMs: Int = 0,
        heldMouseAtStart: Bool? = nil,
        recordThroughline: Bool = true
    ) async {
        // Reviewer-caught Sev-2 (ordering): throughline FIRST, then
        // receipt. Pre-Unit-18A there was no receipt write — throughline
        // was the only audit artifact. If we write receipt first and the
        // receipt write throws, we lose the receipt AND the throughline
        // wouldn't have been written yet — net-worse audit state than
        // pre-18A. Ordering throughline first preserves the "throughline
        // always records the stall" invariant; the receipt is the new
        // augmentation. If receipt write fails, throughline still has
        // the stalled outcome; `MacAgentReplay --errors` would miss it
        // but the throughline does not.
        // Unit 30 — throughline records run OUTCOMES; a self-recovered
        // stall is a step-level event (its receipt below still lands), so
        // recovery firings pass recordThroughline: false. Terminal firings
        // and H.2 keep the original ordering invariant: throughline first.
        if recordThroughline {
            await throughlineStore?.record(TaskRecord(
                task: task, outcome: "stalled",
                stepCount: stepCount, appBundleID: lastObservedBundleID
            ))
        }
        // Reviewer-caught Sev-2 (heldMouse): thread the audit flag
        // through when available (H.1 wait, H.4 scroll, H.2 clarifyDoS
        // fire AFTER heldMouseAtStart is captured; H.3 sameTargetClick
        // and H.5a sameRiskyKeyCombo fire BEFORE capture — pass nil for
        // those, matching the schema's optional design from 13a).
        let receipt = ActionLogEntry(
            action: action,
            tier: "confirm",
            approved: false,
            executionResult: "stalled-\(detector)",
            durationMs: durationMs,
            snapshotHash: snapshotHash,
            heldMouseAtStart: heldMouseAtStart
        )
        do {
            try await writeReceipt(receipt)
        } catch {
            await emit(.receiptWriteFailed(message: error.localizedDescription))
        }
    }

    private func emit(_ event: OrchestratorEvent) async {
        await onEvent?(event)
    }

    /// Test-visible check that the gate timeout Task was properly cancelled after approval.
    /// `private` is relaxed to `internal` so `@testable` tests can assert no Task leak.
    var isGateTimeoutTaskNil: Bool { gateTimeoutTask == nil }
}
