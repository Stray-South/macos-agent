import Foundation
import MacAgentCore

@main
struct MacOSAgentSmoke {
    static func main() async {
        do {
            let task = CommandLine.arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let llm = try ClaudeLLMClient()
            let result = try await SmokeCheck.run(llm: llm, task: task.isEmpty ? nil : task)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let payload = SmokePayload(
                task: result.task,
                snapshotHash: result.snapshot.hash,
                elementCount: result.snapshot.elements.count,
                action: result.action
            )
            let data = try encoder.encode(payload)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Smoke check failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private struct SmokePayload: Codable {
    let task: String
    let snapshotHash: String
    let elementCount: Int
    let action: AgentAction
}
