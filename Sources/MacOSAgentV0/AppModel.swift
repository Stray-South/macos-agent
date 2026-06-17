import AppKit
import ApplicationServices
import MacAgentCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var permissions = PermissionState(accessibilityGranted: false, screenRecordingGranted: false, remoteDesktopGranted: false)
    @Published var task = ""
    @Published var status = "Waiting for permissions"
    @Published var isRunning = false
    @Published var lastError: String?
    @Published var modelReady = false
    @Published var messages: [ConversationMessage] = [
        ConversationMessage(
            role: .system,
            text: "Type any task in the box below, or pick a preset to target Notes, Finder, or Safari."
        ),
    ]
    @Published var selectedPreset: DemoPreset? = nil
    @Published var latestReceiptSummary: ReceiptSummary?
    @Published var lastRunOutcome: RunOutcome = .idle
    @Published var liveActivity: LiveActivityState = .idle
    @Published var autonomyMode: AutonomyMode = .semiAutonomous
    @Published var latestActionPreview: ActionPreview?
    /// Behavioral mirror of the action currently awaiting approval. `latestActionPreview`
    /// is a flat display projection; this is the full AgentAction the LauncherView
    /// approval card sends back to the gate. Set only when tier ≠ .auto. Cleared on
    /// every decision dispatch and on every loop-terminating event.
    @Published var pendingApprovalAction: AgentAction?
    /// Unit 7 — set to true when `handle(.failed)` runs for the current run.
    /// Read by runTask's outer catch to suppress its "Run failed: …" bubble
    /// when the orchestrator already emitted .failed (covers the perception-
    /// throw path: agentIsFrontmost, permissionsRevoked, snapshotCreationFailed).
    /// Reset to false at the start of each runTask. Not @Published — pure
    /// internal coordination, not surfaced to SwiftUI.
    private var didReceiveFailedEventForCurrentRun: Bool = false
    // Read welcome-seen flag at init so the welcome screen is skipped on repeat launches.
    // Uses a direct UserDefaults(suiteName:) call because agentSuite is @MainActor and
    // cannot be accessed during property initialization.
    @Published var showWelcome: Bool = !(UserDefaults(suiteName: "com.southernreach.agent.prefs") ?? .standard).bool(forKey: "hasSeenWelcome")
    /// Short bundle-ID suffix of the app the agent is currently observing.
    /// Updated on every .observed event; shown next to the pulsing dot.
    @Published var focusedAppName: String = ""
    /// True when a previously-granted permission transitions to denied in the same session.
    /// Signals that TCC was reset (re-signing, Sequoia monthly re-prompt, manual revoke).
    /// Cleared once the user re-grants the affected permission.
    @Published var tccResetDetected: Bool = false
    @Published var isClarifying: Bool = false
    @Published var planSteps: [String] = []
    @Published var currentPlanStep: Int = 0
    /// Regular-activation apps currently visible to the agent (updated at run start and on observe).
    @Published var visibleApps: [RunningApp] = []

    private let overlay: any OverlayControlling
    private let cursorFeedback = CursorFeedbackController()
    // KeystrokeOverlayController removed PR-4: its auto-dismiss floating
    // toast violated AGENTS.md §AuDHD-First Defaults. The typed-text
    // payload now renders in the conversation thread (see
    // `.proposed` case in handle(_:)).
    // Single shared store — passed to every Orchestrator instance so all load/save
    // operations are serialized through one actor, eliminating the TOCTOU window
    // that existed when makeOrchestrator() created a fresh ThroughlineStore() each call.
    private let throughlineStore = ThroughlineStore.production()
    /// Shared rule store — same instance across all orchestrator runs so rules persist
    /// in memory across task boundaries without a redundant disk read each time.
    let ruleStore = CapabilityRuleStore()
    private var orchestrator: Orchestrator?
    /// Read-only test accessor. Matches the visibility precedent of internal test helpers.
    var orchestratorForTesting: Orchestrator? { orchestrator }
    // Stored so abort() can cancel the Task and interrupt in-flight URLSession/AX calls.
    private var currentRunTask: Task<Void, Never>?
    // Unit 30a — bumped per run start and per abort; stale (wedged) run
    // tasks compare their captured generation before touching shared state.
    private var runGeneration = 0
    // Reflects UserDefaults.agentSuite.selectedModel — updated via Settings.
    private var currentModelID: String = UserDefaults.agentSuite.selectedModel

    /// Closure that returns the active API key. Production default reads env first,
    /// then keychain. Tests inject `{ "" }` to drive the missing-key failure path
    /// without touching the user's keychain.
    private let apiKeyProvider: @MainActor () -> String

    /// Strong reference to the activation observer so it can be removed in
    /// `deinit`. Block-based NotificationCenter observers don't auto-clean.
    /// `nonisolated(unsafe)` because deinit is nonisolated by default. Mutated
    /// only from `bootstrap()` (which guards against double-registration by
    /// removing the prior observer first) and `deinit`. The @MainActor outer
    /// class serialises both call sites in practice.
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    /// Unit 8 — observer for NSWorkspace.didActivateApplicationNotification.
    /// Tracks `lastNonAgentActivePID` so AXPerception can fall back to a
    /// non-agent app's AX tree when the agent itself is frontmost (see
    /// Unit 5 H3 + Unit 8 design notes in AXPerception.swift). Removed in
    /// `deinit`. Same `nonisolated(unsafe)` rationale as activationObserver.
    nonisolated(unsafe) private var workspaceActivationObserver: NSObjectProtocol?

    /// Unit 28 — voice-reachable global hotkeys (F13 approve / F14 reject /
    /// F15 abort). Owned for the app's lifetime; started once in bootstrap()
    /// and routed to the same approve()/reject()/abort() chokepoints the HUD
    /// and launcher card use. Held as a property so the monitors aren't
    /// deallocated immediately after start().
    private var hotkeyMonitor: GlobalHotkeyMonitor?

    /// Unit 8 — PID of the most recently-activated non-agent app. Updated
    /// by `workspaceActivationObserver` on every app-activation event
    /// system-wide. Read by AXPerception's `fallbackFrontmostProvider`
    /// closure (via a MainActor hop). Reset to nil when the tracked
    /// app terminates or the observer is removed. `@Published` not used
    /// — this is internal coordination state, not UI-visible. `private`
    /// to keep AppModel's surface tight (reviewer-flagged in Unit 8 round).
    private var lastNonAgentActivePID: pid_t?

    init(
        apiKeyProvider: @escaping @MainActor () -> String = AppModel.defaultAPIKeyProvider,
        overlayForTesting: (any OverlayControlling)? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.overlay = overlayForTesting ?? OverlayWindowController()
    }

    deinit {
        if let token = activationObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private static let defaultAPIKeyProvider: @MainActor () -> String = {
        // Guard against empty-string env var (set by shell profile, Anthropic CLI, or other
        // tooling) which would shadow the real key in the Keychain / flat file.
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        return ClaudeLLMClient.readKey() ?? ""
    }

    func bootstrap() async {
        // Restore autonomy mode from settings on launch.
        if let saved = AutonomyMode(rawValue: UserDefaults.agentSuite.defaultAutonomyMode) {
            autonomyMode = saved
        }
        // Always check silently on launch — never prompt automatically.
        // The user grants permissions explicitly via the banner buttons in the UI.
        permissions = Permissions.current(promptIfNeeded: false)
        await configureIfPossible()

        // Unit 29c/29d — close the audit trail for a gate that was still
        // parked when the app last quit/crashed. Tier is validated inside
        // reconciliationReceipt; the bubble reflects whether the receipt
        // actually landed; a corrupt journal is reported, not silently lost.
        switch await PendingGateJournal.production().consume() {
        case .none:
            break
        case .entry(let pending):
            let receipt = PendingGateJournal.reconciliationReceipt(from: pending)
            let wrote = (try? await ReceiptWriter.production().write(receipt)) != nil
            let tierLabel = receipt.tier
            messages.append(ConversationMessage(role: .system, text: wrote
                ? "ℹ️ A \(tierLabel) approval was still waiting when the app last closed. There is no record of a decision — treat the \(pending.action.type.rawValue) action as not executed. Recorded as unresolved."
                : "⚠️ A \(tierLabel) approval was still waiting when the app last closed, but the reconciliation receipt could NOT be written. Treat the \(pending.action.type.rawValue) action as not executed."))
        case .unreadable:
            messages.append(ConversationMessage(role: .system,
                text: "⚠️ A pending-approval record from the last session exists but could not be read. Treat any action from that session's final approval as not executed."))
        }

        // Surface permission + model state on launch so the user knows exactly
        // what's blocking if the send button isn't active.
        let ax = permissions.accessibilityGranted ? "✅" : "❌"
        let sc = permissions.screenRecordingGranted ? "✅" : "⚠️"
        let mr = modelReady ? "✅" : "❌"
        let blockReason: String
        if !permissions.accessibilityGranted {
            blockReason = " — tap the orange lock above to grant Accessibility"
        } else if !modelReady {
            blockReason = " — add API key in Settings (⌘,)"
        } else {
            blockReason = ""
        }
        messages.append(ConversationMessage(role: .system,
            text: "Accessibility \(ax)  Screen Recording \(sc)  Model \(mr)\(blockReason)"))

        // Re-check permissions silently when the app regains focus — so granting
        // Accessibility in System Settings takes effect without a manual "Refresh" click.
        // Uses promptIfNeeded:false to avoid re-triggering permission dialogs on every
        // activation; prompting only happens once during bootstrap above.
        // Guard against re-registration: bootstrap can be called more than once
        // (re-bootstrap on permission change, test fixtures, etc). Remove any
        // prior observer before installing the new one so we don't leak
        // duplicates that double-fire on every didBecomeActive.
        if let prior = activationObserver {
            NotificationCenter.default.removeObserver(prior)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.silentPermissionRecheck()
            }
        }

        // Unit 8 — observe app-activation events system-wide to track
        // `lastNonAgentActivePID`. AXPerception's fallbackFrontmostProvider
        // reads this so observe() can walk the operator's previous app
        // (Notes / Safari / …) instead of throwing agentIsFrontmost when
        // the agent's launcher itself is frontmost at task-submission.
        // Same double-registration guard pattern as activationObserver.
        if let prior = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(prior)
        }
        let agentPID = agentProcessID
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            // Skip our own activations — we only care about who the operator
            // was using before they pulled the agent forward.
            guard pid != agentPID else { return }
            Task { @MainActor [weak self] in
                self?.lastNonAgentActivePID = pid
            }
        }

        // Unit 28 — install voice-reachable hotkeys. The cross-app global
        // monitor needs the Accessibility grant, so the install is gated on
        // it and re-armed when the grant flips (see armHotkeys).
        armHotkeys()
    }

    /// Unit 28a — (re)install the voice hotkey monitor with the global
    /// (cross-app) tap gated on the Accessibility grant. Called from
    /// bootstrap() and from silentPermissionRecheck() on a grant flip, so
    /// the emergency Abort brake arms as soon as Accessibility is granted
    /// and isn't left silently dead if the grant was absent at launch or
    /// revoked mid-session. Idempotent: GlobalHotkeyMonitor.start() tears
    /// down any prior monitors first, so repeated calls don't leak taps.
    ///
    /// Routing: Approve/Reject go through the already-guarded approve()/
    /// reject() (no-ops when no gate is pending); Abort only fires when a
    /// run is active. None bypass the gate — a hotkey approval is an
    /// explicit human decision flowing through the same applyDecision
    /// chokepoint, emitting the same receipt as the HUD/launcher path.
    private func armHotkeys() {
        let monitor = hotkeyMonitor ?? GlobalHotkeyMonitor()
        monitor.start(includeGlobal: permissions.accessibilityGranted) { [weak self] intent in
            guard let self else { return }
            switch intent {
            case .approve: self.approve()
            case .reject:  self.reject()
            case .abort:   if self.isRunning { Task { await self.abort() } }
            }
        }
        hotkeyMonitor = monitor
    }

    /// Silent re-check called on app focus — never prompts, never shows dialogs.
    private func silentPermissionRecheck() async {
        let updated = Permissions.current(promptIfNeeded: false)
        guard updated != permissions else { return }
        // Detect previously-granted → now-denied: TCC was reset (re-sign, Sequoia
        // monthly re-prompt, or manual revoke in System Settings).
        if (permissions.accessibilityGranted && !updated.accessibilityGranted) ||
           (permissions.screenRecordingGranted && !updated.screenRecordingGranted) {
            tccResetDetected = true
        }
        // Unit 28a — re-arm the voice hotkeys when the Accessibility grant
        // flips either way. Grant-after-launch arms the cross-app global
        // brake without a full relaunch; revoke-mid-session tears the
        // (now non-functional) global tap down so `globalActive` reflects
        // reality. The local (agent-frontmost) monitor is unaffected.
        let accessibilityChanged = permissions.accessibilityGranted != updated.accessibilityGranted
        permissions = updated
        if accessibilityChanged {
            armHotkeys()
        }
        await configureIfPossible()
    }

    /// Grant Accessibility: fires the macOS dialog (or opens System Settings if previously denied).
    /// Called when the user taps the Accessibility row in the permissions banner.
    func grantAccessibility() async {
        Permissions.requestAccessibility()
        try? await Task.sleep(for: .milliseconds(500))
        let hadAccessibility = permissions.accessibilityGranted
        permissions = Permissions.current(promptIfNeeded: false)
        if permissions.accessibilityGranted { tccResetDetected = false }
        // Chain fix — this write path bypassed silentPermissionRecheck's
        // re-arm (and then suppressed it, since the next recheck sees no
        // delta). Re-arm the F15 emergency brake here on an Accessibility
        // flip, same as the recheck path does.
        if hadAccessibility != permissions.accessibilityGranted { armHotkeys() }
        await configureIfPossible()
    }

    /// Manual refresh triggered by the user — silently re-reads TCC state.
    func refreshPermissions() async {
        let updated = Permissions.current(promptIfNeeded: false)
        // A manual no-change Refresh click must not be destructive: 29a's
        // abort-first in configureIfPossible would kill a live (possibly
        // parked) run for nothing. Rebuild only when TCC state actually
        // moved or we have no orchestrator yet.
        let changed = updated != permissions
        let accessibilityChanged = updated.accessibilityGranted != permissions.accessibilityGranted
        permissions = updated
        if permissions.fullyGranted { tccResetDetected = false }
        // Chain fix — same re-arm gap as grantAccessibility().
        if accessibilityChanged { armHotkeys() }
        if changed || orchestrator == nil {
            await configureIfPossible()
        }
    }

    func clearContext() async {
        guard !isRunning else { return }
        // Reset all conversation and plan state on the model side before the
        // orchestrator clears its history — the .contextCleared event will add
        // a fresh status bubble.
        messages = [ConversationMessage(role: .system, text: "Context cleared — ready for a new task.")]
        planSteps = []
        currentPlanStep = 0
        lastRunOutcome = .idle
        liveActivity = .idle
        latestActionPreview = nil
        pendingApprovalAction = nil
        await orchestrator?.clearContext()
    }

    func runTask() async {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else { return }

        // Mid-run message — inject into the agent's running conversation.
        if isRunning && !isClarifying, let orchestrator {
            await orchestrator.sendMessage(trimmedTask)
            messages.append(ConversationMessage(role: .user, text: trimmedTask))
            task = ""
            return
        }

        // If the agent paused to ask a question, route this as the answer.
        if isClarifying, let orchestrator {
            messages.append(ConversationMessage(role: .user, text: trimmedTask))
            task = ""
            isClarifying = false
            status = "Resuming"
            liveActivity = .observing
            await orchestrator.resume(withClarification: trimmedTask)
            return
        }

        guard let orchestrator else {
            let reason: String
            if !permissions.allGranted {
                reason = "Accessibility permission is required. Grant it in System Settings and click Refresh."
            } else if !modelReady {
                reason = "Model not ready — check your API key in Settings (⌘,)."
            } else {
                reason = "Agent not initialised. Click Refresh or restart the app."
            }
            messages.append(ConversationMessage(role: .system, text: "⚠️ \(reason)"))
            return
        }
        if let advisory = validateSupportedApp(for: trimmedTask) {
            // Preset app isn't frontmost — show the advisory and wait for the user to
            // bring the app forward before retrying. Not a permanent block.
            messages.append(ConversationMessage(role: .system, text: advisory))
            return
        }
        messages.append(ConversationMessage(role: .user, text: trimmedTask))
        task = ""
        lastError = nil
        isRunning = true
        planSteps = []
        currentPlanStep = 0
        status = "Running"
        lastRunOutcome = .idle
        liveActivity = .observing
        // Unit 7 — track whether orchestrator emitted .failed during this run
        // so the runTask catch can skip its redundant "Run failed: …" bubble
        // when the orchestrator-side handler (added in Unit 7) already added
        // the operator-facing failure message.
        didReceiveFailedEventForCurrentRun = false

        // Wrap the orchestrator run in a stored Task so abort() can cancel it,
        // interrupting any in-flight URLSession or AX call within 1 cooperative checkpoint.
        // We do NOT await the task here — returning immediately restores composer focus
        // so the user can inject mid-run notes without clicking the field.
        let prompt = buildTaskPrompt(from: trimmedTask)
        // Unit 30a — generation guard. abort()'s drain is bounded (5s), so
        // a run task wedged in a non-cancellable call can outlive the abort
        // and un-wedge AFTER a newer run started. Its defer and terminal
        // status writes must then be no-ops: without the guard the stale
        // defer cleared the NEW run's isRunning/currentRunTask and the
        // stale success branch overwrote "Aborted" with "Finished".
        runGeneration += 1
        let myGeneration = runGeneration
        let runTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if runGeneration == myGeneration {
                    isRunning = false
                    currentRunTask = nil
                }
            }
            do {
                try await orchestrator.run(task: prompt)
                guard runGeneration == myGeneration, !Task.isCancelled else { return }
                try? await updateLatestReceiptSummary()
                if let preset = selectedPreset, preset.id == "notes-new-note" {
                    let verification = verifyNotesGoldenPath()
                    switch verification {
                    case .success(let message):
                        status = "Golden path complete"
                        lastRunOutcome = .success(message)
                        messages.append(ConversationMessage(role: .agent, text: message))
                        liveActivity = .idle
                    case .needsVerification(let message):
                        status = "Needs verification"
                        lastRunOutcome = .needsVerification(message)
                        messages.append(ConversationMessage(role: .system, text: message))
                        liveActivity = .idle
                    case .failure(let message):
                        status = "Verification failed"
                        lastRunOutcome = .failure(message)
                        messages.append(ConversationMessage(role: .system, text: message))
                        liveActivity = .idle
                    }
                } else if didReceiveFailedEventForCurrentRun {
                    // run() returns normally on rejected/expired/stalled
                    // breaks — those already emitted .failed with the real
                    // story. Declaring "Finished"/success here right after
                    // an "approval window expired" bubble was a fleet-caught
                    // operator-visible contradiction.
                    status = "Stopped"
                    lastRunOutcome = .failure("Task stopped before completion.")
                    liveActivity = .idle
                } else {
                    status = "Finished"
                    lastRunOutcome = .success("Task finished.")
                    liveActivity = .idle
                }
            } catch is CancellationError {
                // abort() handles state cleanup; nothing to do here.
            } catch {
                guard runGeneration == myGeneration else { return }
                lastError = error.localizedDescription
                status = "Failed"
                lastRunOutcome = .failure(error.localizedDescription)
                // Unit 7 — skip the "Run failed: …" bubble when orchestrator's
                // handle(.failed) already appended one. Without this dedupe,
                // perception-throw runs (Unit 5 / Unit 7 path) would show two
                // system bubbles for the same failure.
                if !didReceiveFailedEventForCurrentRun {
                    messages.append(ConversationMessage(role: .system, text: "Run failed: \(error.localizedDescription)"))
                }
                liveActivity = .idle
            }
        }
        currentRunTask = runTask
        // Intentionally not awaiting — caller's composerFocused restores immediately.
    }

    func abort() async {
        // Cancel the stored Task first so in-flight URLSession/AX calls receive
        // cooperative cancellation at the next Task.checkCancellation() checkpoint.
        currentRunTask?.cancel()
        await orchestrator?.abort()
        // Unit 13b — belt-and-suspenders. Orchestrator.run()'s defer also
        // releases on every exit path, but the defer Task is fire-and-
        // forget so it races this caller. The actor serialises both
        // calls (no duplicate posts) and `release()` is idempotent, so
        // whichever wins clears the OS-side state and the loser is a
        // no-op. The `await` here only guarantees release-before-return
        // when AppModel wins the race; if the defer Task wins, the
        // awaited call returns false and abort() returns immediately.
        // Both paths exist to maximise the probability the button
        // releases before any subsequent UI step that might depend on
        // a clean cursor state.
        await MouseHoldState.shared.release()
        // Drain the run task before returning so its terminal events land
        // BEFORE any caller that rebuilds the orchestrator sets fresh state
        // ("Ready" being overwritten by the dying run's last events was a
        // fleet-caught ordering race). Await suspends — it does not block
        // the main thread — and the unparked/cancelled run winds down fast.
        // Unit 30 — bounded (29c fleet deferral): if the run task is wedged
        // in a non-cancellable synchronous executor/AX call, an unbounded
        // `await value` would leave abort() suspended forever with status
        // stuck "Running". Poll the task's own completion signal (its defer
        // nils currentRunTask on the main actor) with a 5s ceiling, then
        // proceed with state cleanup regardless — the wedged task can still
        // wind down later; the operator gets their UI back now.
        for _ in 0..<50 where currentRunTask != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Whether the drain completed or hit the ceiling, retire the run's
        // generation so a still-wedged task reaps as a no-op when it
        // eventually un-wedges (its defer and terminal writes are guarded).
        runGeneration += 1
        currentRunTask = nil
        isRunning = false
        isClarifying = false
        planSteps = []
        currentPlanStep = 0
        status = "Aborted"
        // The drained run task may have set .success before the abort wound
        // it down — the recorded outcome must match the "Aborted" status.
        lastRunOutcome = .failure("Task aborted.")
        liveActivity = .idle
    }

    private func configureIfPossible() async {
        // Unit 29a — never replace or nil the orchestrator out from under a
        // live run. Post-Unit-29 a parked gate no longer self-terminates, so
        // an orphaned orchestrator would heartbeat (beep + "Paused" status)
        // forever with no reachable abort path — and a later F13 could resume
        // its stale gate. Abort the run first: visible, recoverable by voice.
        // Chain fix: but NOT when the run is still valid — an operator who
        // grants the optional Screen Recording permission mid-run (following
        // the banner's own advice) must not lose the run for it. Only a
        // permission state that invalidates the run (Accessibility lost)
        // justifies the abort; otherwise keep the current orchestrator and
        // let the next run pick up the new state.
        if isRunning {
            if permissions.allGranted { return }
            await abort()
        }
        // allGranted now only requires Accessibility — Screen Recording is an optional fallback.
        if permissions.allGranted {
            do {
                let apiKey = resolvedAPIKey()
                guard !apiKey.isEmpty else {
                    // Key missing — show the banner, don't set modelReady.
                    orchestrator = nil
                    modelReady = false
                    status = "API key required — add in Settings (⌘,)"
                    return
                }
                let llm: any ActionThinking
                if UserDefaults.agentSuite.useComputerUse {
                    llm = ComputerUseClient(apiKey: apiKey, model: UserDefaults.agentSuite.computerUseModelID)
                } else {
                    llm = try ClaudeLLMClient(apiKey: apiKey, model: currentModelID)
                }
                modelReady = true
                orchestrator = makeOrchestrator(llm: llm, apiKey: apiKey, autonomyMode: autonomyMode)
                overlay.setAbortHandler { [weak self] in
                    Task { await self?.abort() }
                }
                overlay.setApprovalResolvedHandler { [weak self] in
                    Task { @MainActor in
                        self?.pendingApprovalAction = nil
                        // Chain fix — clear the parked-gate "Paused — F13
                        // approve" status once ANY surface resolves the
                        // approval, or it persists for the rest of the run.
                        if self?.isRunning == true { self?.status = "Running" }
                    }
                }
                if permissions.fullyGranted {
                    status = "Ready"
                } else {
                    var missing: [String] = []
                    if !permissions.screenRecordingGranted { missing.append("Screen Recording") }
                    if !permissions.remoteDesktopGranted { missing.append("Remote Desktop") }
                    status = "Ready — grant \(missing.joined(separator: " & ")) in the banner above for full functionality"
                }
                try? await updateLatestReceiptSummary()
            } catch {
                lastError = error.localizedDescription
                status = "Missing configuration"
                modelReady = false
                messages.append(ConversationMessage(role: .system,
                    text: "⚠️ Setup error: \(error.localizedDescription)"))
            }
        } else {
            orchestrator = nil
            status = "Accessibility permission required"
            modelReady = false
        }
    }

    func applyPreset(_ preset: DemoPreset) {
        selectedPreset = preset
        task = preset.task
        messages.append(ConversationMessage(role: .system, text: "Preset: \(preset.title) (\(preset.supportedApp))"))
    }

    func clearPreset() {
        // Only wipe the text field if it still contains the preset's task string.
        // If the user overwrote it with their own text, leave it untouched.
        if let preset = selectedPreset, task == preset.task {
            task = ""
        }
        selectedPreset = nil
    }

    // MARK: — Throughline management (called by SettingsView)

    /// Load the current throughline from disk. SettingsView calls this on .onAppear.
    func loadThroughline() async -> AgentThroughline {
        await throughlineStore.load()
    }

    /// Add a hard boundary. Returns false if the rule is already present (no write).
    @discardableResult
    func addBoundary(_ rule: String) async -> Bool {
        await throughlineStore.addBoundary(rule)
    }

    /// Remove a hard boundary by exact string match.
    func removeBoundary(_ rule: String) async {
        await throughlineStore.removeBoundary(rule)
    }

    /// Remove a learned position by key.
    func removePosition(key: String) async {
        await throughlineStore.removePosition(key: key)
    }

    /// Clear all task history records. Hard boundaries and positions survive.
    func clearTaskHistory() async {
        await throughlineStore.clearHistory()
    }

    /// `internal` (not `private`) so AppModelApprovalSurfaceTests can drive the
    /// state-machine without an orchestrator. Matches the precedent of
    /// `ClaudeLLMClient.decodeAgentAction` being `internal static` for testability.
    func handle(event: OrchestratorEvent) {
        switch event {
        case .started(let task):
            // Operator-visible narration; the task text itself is already
            // `latestUserTask` in `buildTaskPrompt`, so excluding from the
            // prompt avoids duplicating it (and occupying a slot in the
            // 6-message budget).
            messages.append(ConversationMessage(
                role: .agent,
                text: "Starting task: \(task)",
                includeInPrompt: false, kind: .activity
            ))
            liveActivity = .observing
            refreshVisibleApps()
        case .observed(let bundleID, _):
            // Noisy low-level detail — update liveActivity + focused app indicator only.
            focusedAppName = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            liveActivity = .deciding
            // Unit 30a — the run is observing again, so no clarification can
            // be pending. Closes the residual fake-channel: after a .clarify
            // TIMEOUT auto-resume, nothing else cleared isClarifying, and the
            // operator's next message was silently dropped by the dead
            // resume(withClarification:) guard while the UI showed it sent.
            isClarifying = false
        case .proposed(let action, let tier):
            // 33a — say renders once, via the .agentSaid bubble; the
            // .proposed narration would duplicate the identical text.
            if action.type == .say { 
                latestActionPreview = nil
                break
            }
            let target = action.targetIndex.map { " → element \($0)" } ?? ""
            let tierLabel = tier == .auto ? "" : " [\(tier.rawValue.uppercased())]"
            // PR-4: surface the typed text payload for `.typeText` actions in
            // the conversation thread. KeystrokeOverlayController used to do
            // this via an auto-dismiss floating panel (violated AGENTS.md
            // §AuDHD-First Defaults "no auto-dismiss"). Folding the payload
            // here makes the thread the single source of operator-visible
            // truth — matches the receipt's cleartext-by-design posture.
            //
            // Privacy gate (PR-4 adversarial sev-1 fix):
            // `SafetyPolicy.isSensitiveTarget` only fires when
            // `targetIndex >= 0`. For coordinate-only typeText (CU pipeline,
            // or hallucinated `targetIndex: nil`), sensitive-target labels
            // can't be inspected and SafetyPolicy floors at `.preview` only.
            // A `.preview` operator approves with one click — if we then
            // print `action.text` in the screenshot-prone thread, a
            // sub-40-char password renders in clear. Mitigation: only
            // render the text payload at `.confirm` tier (operator
            // explicitly approved a destructive/sensitive disclosure).
            // Other tiers show a redacted character count instead, so the
            // operator still sees what was typed (length context) without
            // exposing the secret.
            let textPayload: String = {
                guard action.type == .typeText, let text = action.text, !text.isEmpty else { return "" }
                if tier == .confirm {
                    let truncated = text.count > 40 ? String(text.prefix(40)) + "…" : text
                    return " \"\(truncated)\""
                }
                return " [\(text.count) chars]"
            }()
            // includeInPrompt:false — action narrations are agent-internal
            // (the operator sees them in the thread). Excluding from the
            // next LLM prompt prevents `.confirm`-tier typeText payloads
            // from getting re-sent to Anthropic on every subsequent task
            // in the session. The LLM gets a fresh AX snapshot anyway;
            // its own past proposals aren't useful context. Cascade-
            // sev-1 finding from the milestone adversarial review.
            messages.append(ConversationMessage(
                role: .agent,
                text: "\(action.type.rawValue)\(textPayload)\(target)\(tierLabel) — \(action.rationale)",
                includeInPrompt: false,
                kind: tier == .auto ? .activity : .chat
            ))
            latestActionPreview = ActionPreview(
                typeLabel: action.type.rawValue,
                targetLabel: action.targetIndex.map { "Target \($0)" } ?? "No explicit target",
                rationale: action.rationale,
                tierLabel: tier.rawValue.uppercased()
            )
            pendingApprovalAction = tier == .auto ? nil : action
            liveActivity = tier == .auto ? .executing : .waitingApproval(tier.rawValue)
        case .agentSaid(let message):
            // Unit 33/33a — the agent's conversational channel, in the
            // dedicated agentSpeech role ("Agent says", teal) so
            // model-authored words are structurally distinguishable from
            // app-authored .agent lines — a prompt-injected say cannot
            // impersonate system truth. includeInPrompt false — the message
            // already lives in conversation history as the rationale.
            // Length-capped: the CU text fallback builds the action via the
            // memberwise init, bypassing the Codable 2000-char cap.
            messages.append(ConversationMessage(
                role: .agentSpeech,
                text: String(message.prefix(2000)),
                includeInPrompt: false
            ))
        case .clarificationRequested(let message):
            // Show as an explicit question so the user knows a reply is needed.
            // Role is .agent (green) to distinguish from system noise (orange).
            messages.append(ConversationMessage(
                role: .agent,
                text: "❓ Question for you:\n\n\(message)\n\nType your answer below and press Return."
            ))
            status = "Waiting for your answer"
            liveActivity = .clarifying
            isClarifying = true
        case .clarificationPending:
            // Unit 32 — recurring heartbeat for a parked question, mirror of
            // .approvalPending: audible cue + status, no transcript flood
            // (the question bubble already exists from .clarificationRequested).
            // Guard on isClarifying so a stale heartbeat racing its own
            // cancellation can't tell the operator to answer a dead question.
            guard isClarifying else { break }
            liveActivity = .clarifying
            status = "Paused — waiting for your answer (type below · F15 abort)"
            NSSound.beep()
        case .approvalRequired(let action, let tier):
            // Chain fix (Sev-1) — arm the hotkey/launcher mirror HERE, not
            // only in .proposed. The step-1 .complete escalation gates at
            // .confirm while its .proposed fired at .auto (classify(.complete)
            // is auto), leaving pendingApprovalAction nil: F13/F14 no-op'd,
            // the launcher card hid its buttons, and the 29a heartbeat guard
            // suppressed the beep — a SILENT park on a voice-invisible gate.
            // .approvalRequired is only emitted for tier != .auto, so arming
            // unconditionally here is correct and idempotent for the main
            // gate (where .proposed already set the same action).
            pendingApprovalAction = action
            messages.append(ConversationMessage(role: .system, text: "Waiting for \(tier.rawValue) approval: \(action.type.rawValue) — \(action.rationale) (F13 approve · F14 reject · F15 abort)."))
            liveActivity = .waitingApproval(tier.rawValue)
        case .approvalPending(_, let tier):
            // Unit 29 — the gate has been waiting past the timeout interval
            // and is now PAUSED (not rejected). Re-emitted each interval as
            // a heartbeat. Give a hands-free operator an audible cue —
            // NSSound.beep() needs no permission and is AuDHD-acceptable
            // (no flash, no auto-dismissing modal). Keep liveActivity on
            // waitingApproval so the HUD/launcher card stays bound. Avoid
            // appending a fresh bubble every interval (would flood the
            // transcript); the beep + status is the recurring signal.
            // Unit 29a — only while a gate is actually bound: a stale
            // heartbeat racing its own cancellation must not tell a voice
            // operator "F13 approve" when no pending action exists.
            guard pendingApprovalAction != nil else { break }
            liveActivity = .waitingApproval(tier.rawValue)
            status = "Paused — \(tier.rawValue) approval still needed (F13 approve · F15 abort)"
            NSSound.beep()
        case .recovering:
            // Recovery is an internal mechanism — no conversation bubble.
            // The subsequent .failed or .finished event will surface the outcome.
            // Clear the approval mirror so a stale action doesn't keep the
            // LauncherView card bound to a failed step.
            pendingApprovalAction = nil
            liveActivity = .deciding
        case .executionFinished(let result):
            // 34a — watch-mode "[Watch] Would have:" lines are the entire
            // point of watch mode (reviewing would-have actions); they stay
            // .chat. Everything else through this event is step machinery.
            let kind: ConversationMessage.Kind = result.hasPrefix("[Watch]") ? .chat : .activity
            messages.append(ConversationMessage(role: .agent, text: result, kind: kind))
            pendingApprovalAction = nil
            liveActivity = .observing
        case .receiptWriteFailed(let message):
            // Distinct from .executionFinished so the bubble role is .system (orange)
            // instead of .agent (green). Run continues — the action already executed,
            // only the audit trail entry for this step is incomplete.
            messages.append(ConversationMessage(
                role: .system,
                text: "⚠️ Receipt write failed: \(message). Audit trail may be incomplete."
            ))
        case .finished:
            messages.append(ConversationMessage(role: .agent, text: "Task finished."))
            pendingApprovalAction = nil
            liveActivity = .idle
            isClarifying = false
            planSteps = []
            currentPlanStep = 0
        case .failed(let message):
            didReceiveFailedEventForCurrentRun = true
            messages.append(ConversationMessage(role: .system, text: message))
            pendingApprovalAction = nil
            liveActivity = .idle
            isClarifying = false
            planSteps = []
            currentPlanStep = 0
        case .stepLimitReached(let stepCount):
            messages.append(ConversationMessage(role: .system, text: "Agent reached the \(stepCount)-step limit without completing the task. Try breaking the task into smaller steps."))
            pendingApprovalAction = nil
            liveActivity = .idle
            isClarifying = false
            planSteps = []
            currentPlanStep = 0
        case .planProgress(let steps, let step):
            planSteps = steps
            currentPlanStep = step
        case .appSwitched(let from, let to):
            // Surface the app transition as a brief status bubble.
            let fromName = from.split(separator: ".").last.map(String.init) ?? from
            let toName = to.split(separator: ".").last.map(String.init) ?? to
            liveActivity = .executing
            // A mid-run app switch invalidates any in-flight approval card —
            // the action it referred to was for the previous app context.
            pendingApprovalAction = nil
            // Operator-visible transition. Excluded from the LLM prompt:
            // the next observe() call already produces a fresh AX snapshot
            // reflecting the new app, so re-narrating the transition adds
            // no LLM signal and would waste a slot in the 6-msg budget.
            messages.append(ConversationMessage(
                role: .agent,
                text: "↩ Switched from \(fromName) to \(toName)",
                includeInPrompt: false,
                kind: .activity
            ))
            refreshVisibleApps()
        case .userMessageQueued(let text):
            // The user's text was already added as a .user bubble in runTask().
            // Add a system confirmation so the message doesn't appear to vanish.
            _ = text
            messages.append(ConversationMessage(role: .system, text: "📬 Note queued — agent will read this before its next step."))
            status = "Note queued"
        case .contextCleared:
            messages.append(ConversationMessage(role: .system, text: "Context cleared — conversation history reset."))
            planSteps = []
            currentPlanStep = 0
            status = "Ready"
        case .warning(let message):
            messages.append(ConversationMessage(role: .system, text: message))
        }
    }

    /// Refresh the list of regular-activation apps currently running.
    /// Called on each observe event so the UI always shows the current app landscape.
    func refreshVisibleApps() {
        visibleApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return RunningApp(bundleID: id, name: name)
            }
            .sorted { $0.name < $1.name }
    }

    private func buildTaskPrompt(from latestUserTask: String) -> String {
        // Filter out system-role messages (UI housekeeping like permission advisories,
        // receipt notices, preset labels) — they're not part of the agent conversation.
        // Also filter messages marked `includeInPrompt:false` (action-narration
        // bubbles) — operator sees them in the thread but they aren't useful
        // LLM context and may carry typeText payloads. Sev-1 cascade fix.
        let priorTurns = messages.suffix(6)
            .filter { $0.role != .system && $0.includeInPrompt }
            .map { message in
                let role: String
                switch message.role {
                case .user: role = "User"
                case .agent: role = "Agent"
                case .agentSpeech: role = "Agent"
                case .system: role = "System"
                }
                return "\(role): \(message.text)"
            }.joined(separator: "\n")

        if priorTurns.isEmpty {
            return latestUserTask
        }

        return """
        Current operator request:
        \(latestUserTask)

        Recent conversation:
        \(priorTurns)
        """
    }

    /// Returns an advisory message when the preset's app isn't frontmost (and tries to launch it),
    /// or nil when the run may proceed immediately.
    private func validateSupportedApp(for _: String) -> String? {
        guard let preset = selectedPreset else {
            // No preset active — any free-form task on any frontmost app is allowed.
            return nil
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontmost != preset.bundleID else {
            // Correct app is already frontmost — proceed with no message.
            return nil
        }
        // App isn't frontmost — try to launch it, then ask the user to bring it forward.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        return "Opening \(preset.supportedApp)… bring it to front and try again."
    }

    private func isFrontmostApp(bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private func verifyNotesGoldenPath() -> VerificationResult {
        guard isFrontmostApp(bundleID: "com.apple.Notes") else {
            return .needsVerification("Notes is not frontmost yet. Bring Notes to the front and verify the editor is focused.")
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failure("Could not resolve the frontmost application for verification.")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focusedValue else {
            return .needsVerification("Notes opened, but the focused editor could not be verified.")
        }

        let focusedElement = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)
        let role = axString(kAXRoleAttribute as CFString, on: focusedElement) ?? "AXUnknown"
        let description = axString(kAXDescriptionAttribute as CFString, on: focusedElement) ?? ""
        let title = axString(kAXTitleAttribute as CFString, on: focusedElement) ?? ""

        let isEditableRole = ["AXTextArea", "AXTextField"].contains(role)
        if isEditableRole {
            return .success("Golden path verified: Notes is frontmost and the editor is focused.")
        }

        if [description, title].joined(separator: " ").lowercased().contains("editor") {
            return .success("Golden path verified: Notes is frontmost and the editor appears focused.")
        }

        return .needsVerification("Notes is frontmost, but the focused editor could not be confirmed yet.")
    }

    private func updateLatestReceiptSummary() async throws {
        let directory = try ReceiptWriter.defaultBaseURL()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            latestReceiptSummary = nil
            return
        }

        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "jsonl" }

        guard let latest = try files.max(by: { lhs, rhs in
            let leftDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rightDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }) else {
            latestReceiptSummary = nil
            return
        }

        let values = try latest.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values.contentModificationDate ?? .now
        let content = try String(contentsOf: latest)
        let lastLine = content.split(separator: "\n").last.map(String.init) ?? ""
        var headline = "Latest receipt updated."
        let receiptDecoder = JSONDecoder()
        receiptDecoder.dateDecodingStrategy = .iso8601
        if let data = lastLine.data(using: .utf8) {
            do {
                let entry = try receiptDecoder.decode(ActionLogEntry.self, from: data)
                if !entry.approved {
                    headline = "Latest receipt recorded a rejection."
                } else if entry.executionResult == "success" || entry.executionResult == "task complete" {
                    headline = "Latest receipt recorded a successful action."
                } else {
                    headline = "Latest receipt: \(entry.executionResult)."
                }
            } catch {
                // F5: surface corrupt JSONL instead of silently falling back to a
                // generic "updated" headline. The receipt section's "N unreadable"
                // chip is the structured surface for the full count.
                headline = "Latest receipt: entry unreadable."
            }
        }
        latestReceiptSummary = ReceiptSummary(fileURL: latest, headline: headline, updatedAt: modifiedAt)
    }

    /// Called by SettingsView when the user saves a new API key.
    func reconfigure() async {
        // Unify the config-change-while-running policy with
        // rebuildOrchestrator: a Settings save refuses (courtesy message)
        // rather than silently aborting the run. configureIfPossible's
        // abort-first remains the backstop for permission-state flips,
        // where the run is invalidated anyway.
        guard !isRunning else {
            messages.append(ConversationMessage(role: .system,
                text: "⚠️ Can't apply this change while a task is running — stop the task, then apply the change again."))
            return
        }
        await configureIfPossible()
    }

    /// Resolve API key via the injected provider. Default chain: env → keychain → "".
    /// Tests override via the `apiKeyProvider` init parameter.
    private func resolvedAPIKey() -> String { apiKeyProvider() }

    /// Build a fresh orchestrator for a config change (model / perception / autonomy).
    /// Rebuilds the orchestrator with an explicitly-passed `useComputerUse` flag so
    /// callers can't desync UI bubble copy from the actual client constructed (per
    /// code-review feedback on the CU re-enable diff — the prior version re-read
    /// UserDefaults inside this method, opening a stale-state window if a future
    /// caller forgot to write the default before calling).
    private func rebuildOrchestrator(
        useComputerUse: Bool,
        autonomyMode: AutonomyMode,
        successMessage: String?
    ) {
        // Unit 29a — all current callers already guard !isRunning, but enforce
        // it here so a future caller can't orphan a live (possibly parked)
        // orchestrator, which post-Unit-29 would heartbeat forever.
        guard !isRunning else {
            messages.append(ConversationMessage(role: .system,
                text: "⚠️ Can't apply this change while a task is running — stop the task, then apply the change again."))
            return
        }
        let apiKey = resolvedAPIKey()
        guard !apiKey.isEmpty else {
            messages.append(ConversationMessage(role: .system,
                text: "⚠️ Couldn't apply change — check API key in Settings (⌘,)."))
            return
        }
        do {
            let llm: any ActionThinking
            if useComputerUse {
                llm = ComputerUseClient(apiKey: apiKey, model: UserDefaults.agentSuite.computerUseModelID)
            } else {
                llm = try ClaudeLLMClient(apiKey: apiKey, model: currentModelID)
            }
            orchestrator = makeOrchestrator(llm: llm, apiKey: apiKey, autonomyMode: autonomyMode)
            overlay.setAbortHandler { [weak self] in Task { await self?.abort() } }
            overlay.setApprovalResolvedHandler { [weak self] in
                Task { @MainActor in
                    self?.pendingApprovalAction = nil
                    if self?.isRunning == true { self?.status = "Running" }
                }
            }
            if let msg = successMessage {
                messages.append(ConversationMessage(role: .system, text: msg))
            }
        } catch {
            messages.append(ConversationMessage(
                role: .system,
                text: "⚠️ Couldn't apply change — check API key in Settings (⌘,)."
            ))
        }
    }

    /// Called by SettingsView when the user picks a different model.
    func applyModelChange(_ modelID: String) {
        currentModelID = modelID
        guard !isRunning, modelReady else { return }
        rebuildOrchestrator(
            useComputerUse: UserDefaults.agentSuite.useComputerUse,
            autonomyMode: autonomyMode,
            successMessage: "Model: \(modelID)"
        )
    }

    /// Called by SettingsView when the user toggles Computer Use mode or picks
    /// a different Computer Use model. The caller writes the UserDefaults BEFORE
    /// invoking this, so the explicit `useComputerUse` parameter is authoritative.
    func applyPerceptionModeChange(useComputerUse: Bool) {
        guard !isRunning, modelReady else { return }
        let label: String
        if useComputerUse {
            let cuModel = UserDefaults.agentSuite.computerUseModelID
            let display = ComputerUseModel.all.first(where: { $0.id == cuModel })?.displayName ?? cuModel
            label = "Perception: Computer Use (\(display))"
        } else {
            label = "Perception: Standard"
        }
        rebuildOrchestrator(
            useComputerUse: useComputerUse,
            autonomyMode: autonomyMode,
            successMessage: label
        )
    }

    func setAutonomyMode(_ mode: AutonomyMode) {
        autonomyMode = mode
        UserDefaults.agentSuite.defaultAutonomyMode = mode.rawValue
        if isRunning {
            // F2: surface the deferral so mid-run pill clicks don't silently no-op.
            messages.append(ConversationMessage(
                role: .system,
                text: "Autonomy: \(mode.shortLabel) — applies next task"
            ))
            return
        }
        guard modelReady else { return }
        rebuildOrchestrator(
            useComputerUse: UserDefaults.agentSuite.useComputerUse,
            autonomyMode: mode,
            successMessage: nil
        )
    }

    // MARK: - In-window approval dispatch
    //
    // LauncherView's approval card calls these. They route through the same
    // overlay.applyDecision chokepoint the HUD buttons use, so the gate
    // continuation resumes exactly once regardless of surface. Idempotent —
    // a second call after pendingApprovalAction is nilled is a no-op.

    func approve() { dispatchApproval(.approveOnce) }
    func alwaysAllow() { dispatchApproval(.alwaysAllow) }
    func reject() { dispatchApproval(.rejectOnce) }
    func neverAllow() { dispatchApproval(.neverAllow) }

    private func dispatchApproval(_ decision: ApprovalDecision) {
        guard pendingApprovalAction != nil else { return }
        pendingApprovalAction = nil
        overlay.applyDecision(decision)
    }

    /// Unit 15 — TaskGuard factory. Reads
    /// `UserDefaults.agentSuite.useLLMTaskClassifier` and wraps
    /// `KeywordTaskGuard` in `LLMTaskClassifier` when the operator opted
    /// in AND an API key is available. Otherwise returns the bare
    /// keyword guard, preserving F.6 (the production binary always runs
    /// the keyword banlist regardless of the LLM toggle).
    ///
    /// `internal` so `AppModelTaskGuardTests` can verify the wiring
    /// without re-implementing the toggle logic.
    static func makeTaskGuard(apiKey: String) -> any TaskGuarding {
        let baseGuard = KeywordTaskGuard()
        if !apiKey.isEmpty, UserDefaults.agentSuite.useLLMTaskClassifier {
            return LLMTaskClassifier(apiKey: apiKey, baseGuard: baseGuard)
        }
        return baseGuard
    }

    /// Unit 36 — the agent file workspace root (0700). Created lazily here so
    /// it exists before the first write; the Executor re-applies 0700/0600
    /// per write. Mirrors the ReceiptWriter/SnapshotWriter Application
    /// Support layout.
    nonisolated static func agentWorkspaceRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = base.appendingPathComponent("MacAgent/workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeOrchestrator(llm: any ActionThinking, apiKey: String, autonomyMode: AutonomyMode) -> Orchestrator {
        let planner: TaskPlanning = apiKey.isEmpty
            ? NoOpPlanner()
            : ClaudeTaskPlanner(apiKey: apiKey)
        let cursorCtrl = cursorFeedback
        let executor = Executor(
            onCursorAction: { [cursorCtrl] point in
                await MainActor.run { cursorCtrl.showRipple(at: point) }
            },
            useFastPasteForLongText: UserDefaults.agentSuite.useFastPasteForLongText,
            // 36a — live provider, not a captured value: disabling the
            // workspace toggle takes effect on the very next write (the
            // Executor is reused across runs).
            workspaceRootProvider: {
                let suite = UserDefaults(suiteName: UserDefaults.agentSuiteName) ?? .standard
                return suite.bool(forKey: "agentWorkspaceEnabled") ? AppModel.agentWorkspaceRoot() : nil
            }
        )
        return Orchestrator(
            llm: llm,
            perception: AXPerception(fallbackFrontmostProvider: { [weak self] in
                // Unit 8 — AppModel-tracked PID of the last non-agent app
                // to become active. Read via MainActor since `lastNon
                // AgentActivePID` is set by the workspace observer on the
                // main thread. Returns nil when no app has activated yet
                // (cold start) — AXPerception then throws agentIsFrontmost
                // as before.
                await MainActor.run { self?.lastNonAgentActivePID }
            }),
            visionFallback: VisionPerception(),
            executor: executor,
            overlay: overlay,
            receiptWriter: ReceiptWriter.production(),
            throughlineStore: throughlineStore,
            // Unit 19 — snapshot sidecar opt-in. Construct only when
            // the operator has toggled `persistSnapshots` on; nil means
            // the Orchestrator skips snapshot persistence entirely.
            // screenshotPNG is always stripped from the sidecar (separate
            // future toggle if anyone needs the PNG persisted).
            snapshotWriter: UserDefaults.agentSuite.persistSnapshots
                ? SnapshotWriter.production()
                : nil,
            ruleStore: ruleStore,
            // MANIFEST.md §Phase Status F.6 claims KeywordTaskGuard ships in production.
            // The Orchestrator default is PermissiveTaskGuard to keep test injection ergonomic;
            // we must override here so the shipped binary actually runs the keyword-banlist gate.
            //
            // Unit 15 — F.6 v1 stretch closure. If the operator has
            // opted into LLM-augmented pre-run safety AND an API key is
            // available, wrap KeywordTaskGuard in LLMTaskClassifier so
            // semantically-harmful tasks the keyword list can't catch
            // ("clean up old downloads") get a Haiku-graded check
            // before .started fires. Empty-key path falls back to the
            // bare KeywordTaskGuard — matching the existing planner
            // pattern (NoOpPlanner when key absent).
            taskGuard: Self.makeTaskGuard(apiKey: apiKey),
            planner: planner,
            // Unit 29c/29d — park ceiling (0 = unbounded, operator's
            // explicit choice) read LIVE at each heartbeat via a provider,
            // so tightening the ceiling in Settings applies to a gate that
            // is already parked. The closure builds its own suite handle —
            // UserDefaults reads are thread-safe and the @MainActor static
            // can't be touched from the orchestrator actor.
            gateMaxParkDurationProvider: {
                let suite = UserDefaults(suiteName: UserDefaults.agentSuiteName) ?? .standard
                let minutes = UserDefaults.gateMaxParkMinutes(in: suite)
                return minutes > 0 ? .seconds(minutes * 60) : nil
            },
            parkJournal: PendingGateJournal.production(),
            onEvent: { [weak self] event in
                await MainActor.run {
                    self?.handle(event: event)
                }
            },
            autonomyModeProvider: { autonomyMode },
            // NSWorkspace.shared is @MainActor-isolated but `runningApplications`
            // is one of the few AppKit APIs documented as thread-safe (per Apple
            // docs: "thread-safe with respect to concurrent reads"). The closure
            // is called from the Orchestrator actor's executor (NOT MainActor),
            // so a MainActor.assumeIsolated wrapper would TRAP at runtime — that
            // was the bug an adversarial review caught pre-push. Bare read is
            // documented-safe; the Sendable-bridging is purely Swift 6 hygiene.
            runningAppsProvider: {
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .compactMap { app in
                        guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                        return RunningApp(bundleID: id, name: name)
                    }
            }
        )
    }
}

private enum VerificationResult {
    case success(String)
    case failure(String)
    case needsVerification(String)
}

private func axString(_ attribute: CFString, on element: AXUIElement) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let value else { return nil }
    return value as? String
}
