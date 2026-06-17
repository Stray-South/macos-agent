import Foundation
import Testing
@testable import MacOSAgentV0
@testable import MacAgentCore

// MANIFEST.md §Phase Status F.6 claims KeywordTaskGuard ships in production. The
// Orchestrator default is PermissiveTaskGuard (test ergonomics), so AppModel must
// override at construction. This test pins that wiring — without it the spec
// claim is silently false.
//
// Unit 15 added the LLM-augmented mode: when `useLLMTaskClassifier=true` AND
// an API key is present, AppModel wraps `KeywordTaskGuard` in
// `LLMTaskClassifier`. Both tests below cover the two toggle states.

@MainActor @Test
func appModelInjectsKeywordTaskGuardWhenToggleOff() async {
    // Defensive reset — UserDefaults persists across tests in the same process.
    UserDefaults.agentSuite.useLLMTaskClassifier = false
    let model = AppModel(apiKeyProvider: { "dummy" })
    model.modelReady = true
    model.applyModelChange("claude-sonnet-4-6")
    guard let orchestrator = model.orchestratorForTesting else {
        Issue.record("expected orchestrator after applyModelChange, got nil")
        return
    }
    let guardImpl = await orchestrator.taskGuardForTesting
    #expect(guardImpl is KeywordTaskGuard,
            "toggle-off path must use the bare KeywordTaskGuard, got \(type(of: guardImpl))")
}

@MainActor @Test
func appModelInjectsLLMClassifierWhenToggleOnAndKeyPresent() async {
    UserDefaults.agentSuite.useLLMTaskClassifier = true
    defer { UserDefaults.agentSuite.useLLMTaskClassifier = false }
    let model = AppModel(apiKeyProvider: { "dummy-non-empty" })
    model.modelReady = true
    model.applyModelChange("claude-sonnet-4-6")
    guard let orchestrator = model.orchestratorForTesting else {
        Issue.record("expected orchestrator after applyModelChange, got nil")
        return
    }
    let guardImpl = await orchestrator.taskGuardForTesting
    #expect(guardImpl is LLMTaskClassifier,
            "toggle-on + key path must wrap KeywordTaskGuard in LLMTaskClassifier, got \(type(of: guardImpl))")
}

@MainActor @Test
func appModelFallsBackToKeywordGuardWhenToggleOnButKeyMissing() async {
    UserDefaults.agentSuite.useLLMTaskClassifier = true
    defer { UserDefaults.agentSuite.useLLMTaskClassifier = false }
    // Construct via the factory directly — AppModel without an API key
    // doesn't build the orchestrator at all (modelReady stays false), so
    // we exercise the factory path that AppModel.makeOrchestrator calls.
    let guardImpl = AppModel.makeTaskGuard(apiKey: "")
    #expect(guardImpl is KeywordTaskGuard,
            "empty-key path must fall back to KeywordTaskGuard even when toggle is on — LLMTaskClassifier needs a key, no silent failures")
}
