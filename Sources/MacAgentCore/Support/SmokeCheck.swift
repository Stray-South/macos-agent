import Foundation

public struct SmokeCheckResult: Sendable {
    public let task: String
    public let snapshot: PerceptionSnapshot
    public let action: AgentAction

    public init(task: String, snapshot: PerceptionSnapshot, action: AgentAction) {
        self.task = task
        self.snapshot = snapshot
        self.action = action
    }
}

public enum SmokeCheck {
    public static func makeSampleSnapshot() throws -> PerceptionSnapshot {
        try PerceptionSnapshot.make(
            timestamp: .now,
            focusedAppBundleID: "com.apple.finder",
            elements: [
                UIElement(
                    index: 0,
                    role: "AXButton",
                    label: "Continue",
                    value: nil,
                    frame: CodableRect(CGRect(x: 120, y: 80, width: 120, height: 32)),
                    isEnabled: true,
                    isVisible: true
                ),
                UIElement(
                    index: 1,
                    role: "AXTextField",
                    label: "Search",
                    value: nil,
                    frame: CodableRect(CGRect(x: 24, y: 24, width: 240, height: 28)),
                    isEnabled: true,
                    isVisible: true
                ),
                UIElement(
                    index: 2,
                    role: "AXStaticText",
                    label: "Welcome to macOS Agent v0",
                    value: nil,
                    frame: CodableRect(CGRect(x: 24, y: 140, width: 280, height: 20)),
                    isEnabled: true,
                    isVisible: true
                ),
            ]
        )
    }

    public static func defaultTask() -> String {
        "Click the Continue button if it is available, otherwise clarify what is missing."
    }

    public static func run(
        llm: ActionThinking,
        task: String? = nil,
        history: [LLMMessage] = []
    ) async throws -> SmokeCheckResult {
        let resolvedTask = task ?? defaultTask()
        let snapshot = try makeSampleSnapshot()
        let action = try await llm.nextAction(task: resolvedTask, snapshot: snapshot, history: history, runningApps: [])
        return SmokeCheckResult(task: resolvedTask, snapshot: snapshot, action: action)
    }
}
