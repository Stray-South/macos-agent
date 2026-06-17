/// TaskPlanner.swift
///
/// Produces a short numbered plan for a task before the action loop starts.
/// Injected into every subsequent LLM think() call so the agent stays oriented.
///
/// The planner is a single LLM call that asks Claude to decompose the task
/// into 3–7 concrete steps. It is intentionally lightweight — no tool use,
/// just a short text response. If planning fails (network error, bad key)
/// the run continues without a plan rather than aborting.
import Foundation
import os.log

private let plannerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "TaskPlanner"
)

public protocol TaskPlanning: Sendable {
    /// Returns a formatted plan string to prepend to the task context, or nil if planning failed.
    func plan(task: String, snapshot: PerceptionSnapshot) async -> String?
}

/// A planner that calls the Anthropic API with a dedicated low-token planning prompt.
public struct ClaudeTaskPlanner: TaskPlanning {
    private let apiKey: String
    let model: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = "claude-haiku-4-5-20251001",  // Use Haiku for planning — fast + cheap
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func plan(task: String, snapshot: PerceptionSnapshot) async -> String? {
        // Only show up to 20 elements to the planner — it doesn't need the full snapshot.
        // Sanitise external strings (AX label/value, role, operator task, focused bundle ID)
        // before they enter the planning prompt: any of these can carry newlines or Unicode
        // line separators that forge a `Task:` or `Visible elements:` section header.
        let elements = snapshot.elements.prefix(20).map { e in
            let role = ClaudeLLMClient.sanitizeForPrompt(e.role)
            let lbl  = ClaudeLLMClient.sanitizeForPrompt(e.label)
            let val  = e.value.map(ClaudeLLMClient.sanitizeForPrompt)
            return "[\(e.index)] \(role): \(lbl)\(val.map { " (\($0))" } ?? "")"
        }.joined(separator: "\n")
        let safeTask = ClaudeLLMClient.sanitizeForPrompt(task)
        let safeBundleID = ClaudeLLMClient.sanitizeForPrompt(snapshot.focusedAppBundleID)

        let prompt = """
        You are planning steps for a macOS desktop agent.

        Task: \(safeTask)

        Current app: \(safeBundleID)
        Visible elements (first 20):
        \(elements.isEmpty ? "(none visible yet)" : elements)

        Produce a numbered plan of 3–7 concrete steps to complete the task.
        Each step must be one action (click, type, menu, keyCombo, etc.).
        If the task is already trivially one step, write just that one step.
        Write ONLY the numbered list. No preamble, no explanation.

        Critical rules:
        - To navigate to a URL: always include THREE steps: (1) focus address bar with cmd+l, (2) type the URL, (3) press Return. Never skip the Return step.
        - Never plan "ask user to press Enter" — pressing Enter/Return is always a step the agent does itself.

        Example for URL navigation:
        1. Press cmd+l to focus the address bar
        2. Type "gmail.com"
        3. Press Return to navigate
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "temperature": 0.1,
            "messages": [["role": "user", "content": prompt]],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPrefix = String(decoding: data.prefix(400), as: UTF8.self)
            plannerLog.error("Planner request failed: status=\(http.statusCode, privacy: .public) model=\(self.model, privacy: .public) body=\(bodyPrefix, privacy: .public)")
            return nil
        }

        struct Response: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let text = decoded.content.first(where: { $0.type == "text" })?.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return """
        [PLAN for this task — follow these steps in order]
        \(text.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}

/// A planner that always returns nil — used in tests and when planning is disabled.
public struct NoOpPlanner: TaskPlanning {
    public init() {}
    public func plan(task: String, snapshot: PerceptionSnapshot) async -> String? { nil }
}
