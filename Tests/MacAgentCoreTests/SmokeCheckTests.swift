import MacAgentCore
import Testing

@Test
func smokeCheckUsesSharedClaudeActionContract() async throws {
    let result = try await SmokeCheck.run(
        llm: SmokeMockLLM(
            action: AgentAction(
                type: .click,
                targetIndex: 0,
                confidence: 0.91,
                requiresConfirmation: false,
                rationale: "Continue is visible and enabled."
            )
        )
    )

    #expect(result.snapshot.elements.count == 3)
    #expect(result.action.type == .click)
    #expect(result.action.targetIndex == 0)
}

private struct SmokeMockLLM: ActionThinking {
    let action: AgentAction

    func nextAction(task: String, snapshot: PerceptionSnapshot, history: [LLMMessage], runningApps: [RunningApp]) async throws -> AgentAction {
        action
    }
}
