import Foundation
import Testing
@testable import MacOSAgentV0
@testable import MacAgentCore

// MARK: - F1: ClaudeLLMClient init failure surfaces as a system bubble
//
// Regression guard for the silent-try? bug closed in commit 4003eaf. When the
// API key is missing/empty and Settings asks for a model change, the user must
// see an orange system bubble — not get silent fallback to the old orchestrator.

@MainActor @Test
func rebuildSurfacesMissingKeyAsSystemBubble() async {
    let model = AppModel(apiKeyProvider: { "" })
    model.modelReady = true  // bypass the modelReady guard so applyModelChange proceeds
    let priorMessageCount = model.messages.count
    model.applyModelChange("claude-sonnet-4-6")
    let last = model.messages.last
    #expect(model.messages.count == priorMessageCount + 1,
            "applyModelChange with empty key must append exactly one bubble")
    #expect(last?.role == .system,
            "F1 failure path uses .system role for the orange-error visual")
    #expect(last?.text.contains("Couldn't apply change") == true,
            "Bubble text must surface the actual error reason")
}

// MARK: - F2: mid-run autonomy change emits a deferral bubble
//
// Regression guard for the silent-no-op bug closed in commit 4003eaf. Clicking
// an autonomy pill while a run is in flight must emit a small system bubble so
// the user knows the change applies to the next task — not silently noop.

@MainActor @Test
func midRunAutonomyChangeEmitsDeferralBubble() async {
    let model = AppModel(apiKeyProvider: { "sk-stub" })
    model.isRunning = true
    let priorMessageCount = model.messages.count
    model.setAutonomyMode(.autonomous)
    #expect(model.autonomyMode == .autonomous,
            "Mode property must update even when mid-run — deferral is about orchestrator rebuild, not state")
    #expect(model.messages.count == priorMessageCount + 1,
            "Mid-run setAutonomyMode must append exactly one bubble")
    #expect(model.messages.last?.role == .system,
            "Deferral notice uses .system role")
    #expect(model.messages.last?.text.contains("applies next task") == true,
            "Deferral bubble must explain when the change takes effect")
}
