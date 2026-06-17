import Foundation

public enum OrchestratorEvent: Sendable {
    case started(task: String)
    case observed(appBundleID: String, elementCount: Int)
    case proposed(action: AgentAction, tier: SafetyTier)
    case clarificationRequested(message: String)
    /// Unit 32 — recurring heartbeat while a clarification question waits
    /// for the operator's answer (gate parity: parked questions beep each
    /// interval and NEVER auto-resume with an assumption; the old 240+60s
    /// timeout silently answered "(no reply)" for a slow voice operator).
    /// Resolves only on resume(withClarification:), abort, or the wall-clock
    /// approval wait limit (which stops the task safely).
    case clarificationPending(message: String)
    case approvalRequired(action: AgentAction, tier: SafetyTier)
    /// Unit 29 — emitted when an approval gate has been waiting past the
    /// timeout interval WITHOUT being answered. Replaces the old
    /// auto-reject-on-timeout behavior: the run is paused (continuation
    /// parked), not killed. Re-emitted on every timeout interval as a
    /// heartbeat so a hands-free operator gets a recurring audible cue
    /// (AppModel beeps + updates status) rather than a silent stall. The
    /// run resumes only on an explicit decision (HUD / launcher / hotkey),
    /// or the operator aborts (Unit 28 Abort hotkey is the escape).
    case approvalPending(action: AgentAction, tier: SafetyTier)
    case executionFinished(result: String)
    /// Unit 33 — the agent spoke to the operator via a .say action: a
    /// conversational message that does NOT pause the run (clarify is the
    /// pausing, answer-required channel). Renders as an agent chat bubble.
    case agentSaid(message: String)
    /// Emitted when a step fails but the agent is attempting recovery before declaring failure.
    /// AppModel should display this as a transient status, not a terminal error.
    case recovering(message: String)
    case finished
    case failed(message: String)
    /// Emitted when the orchestrator exits because it has consumed all maxSteps budget
    /// without the LLM returning a `.complete` action. Distinct from `.failed` so the UI
    /// can surface a more precise message and the throughline can record "step_limit" as the outcome.
    case stepLimitReached(stepCount: Int)
    /// Emitted when a multi-step plan is parsed (currentStep = 0) and after each
    /// meaningful action advances the plan pointer. Not emitted for trivial/single-step tasks.
    case planProgress(steps: [String], currentStep: Int)
    /// Emitted when execution focus moves from one app to another.
    case appSwitched(from: String, to: String)
    /// Emitted when the user sends a message while the agent is running.
    /// The text has been injected into the conversation history for the next think() call.
    case userMessageQueued(text: String)
    /// Emitted after clearContext() resets conversation history and plan state.
    case contextCleared
    /// Emitted when a receipt write fails mid-run. Distinct from .failed (terminal)
    /// and .executionFinished (success/result) so AppModel can render it as a
    /// .system role bubble rather than .agent. The already-executed action is not
    /// rolled back — the audit trail is just incomplete for that step.
    case receiptWriteFailed(message: String)
    /// Emitted for non-fatal advisory conditions during a run (e.g. vision fullscreen
    /// fallback active). Distinct from .executionFinished so the UI can render it as a
    /// .system role bubble and consumers can ignore it without treating it as a result.
    case warning(message: String)
}
