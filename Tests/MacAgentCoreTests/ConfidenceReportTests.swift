import Testing
import Foundation
@testable import MacAgentCore

// G4 — the dogfood evidence summary. Pure function over receipts, so the
// categories that drive the confidence read are themselves verified.
@Suite struct ConfidenceReportTests {
    private func entry(_ type: ActionType, tier: String, approved: Bool, result: String) -> ActionLogEntry {
        ActionLogEntry(
            action: AgentAction(type: type, confidence: 0.9, requiresConfirmation: false, rationale: "r"),
            tier: tier, approved: approved, executionResult: result,
            durationMs: 1, snapshotHash: "h")
    }

    @Test func categorizesEveryOutcomeClass() {
        let r = ReceiptReplayFormatter.confidenceReport([
            entry(.click, tier: "auto", approved: true, result: "clicked"),
            entry(.typeText, tier: "preview", approved: true, result: "typed"),
            entry(.click, tier: "auto", approved: true, result: "error: AX press failed"),
            entry(.keyCombo, tier: "confirm", approved: false, result: "stalled-sameRiskyKeyCombo"),
            entry(.click, tier: "confirm", approved: true, result: "superseded — screen changed"),
            entry(.typeText, tier: "preview", approved: false, result: "yielded — user switched frontmost app"),
            entry(.writeFile, tier: "confirm", approved: false, result: "rejected"),
        ])
        #expect(r.total == 7)
        #expect(r.executedClean == 2)
        #expect(r.errored == 1)
        #expect(r.stalled == 1)
        #expect(r.superseded == 1)
        #expect(r.yielded == 1)
        #expect(r.rejected == 1)
        // Every entry is in exactly one bucket.
        #expect(r.executedClean + r.errored + r.stalled + r.superseded + r.yielded + r.rejected == r.total)
    }

    @Test func histogramsAndProblems() {
        let r = ReceiptReplayFormatter.confidenceReport([
            entry(.click, tier: "auto", approved: true, result: "clicked"),
            entry(.click, tier: "auto", approved: true, result: "error: boom"),
            entry(.typeText, tier: "preview", approved: true, result: "typed"),
        ])
        #expect(r.tierCounts["auto"] == 2)
        #expect(r.tierCounts["preview"] == 1)
        #expect(r.typeCounts["click"] == 2)
        #expect(r.problems.count == 1)
        #expect(r.problems[0].contains("error") && r.problems[0].contains("boom"))
    }

    @Test func emptyIsAllZero() {
        let r = ReceiptReplayFormatter.confidenceReport([])
        #expect(r.total == 0 && r.problems.isEmpty)
        // Render must not divide by zero.
        let s = ReceiptReplayFormatter.renderConfidenceReport(r, scope: "empty")
        #expect(s.contains("actions total"))
    }

    @Test func renderIncludesRatesAndProblems() {
        let r = ReceiptReplayFormatter.confidenceReport([
            entry(.click, tier: "auto", approved: true, result: "clicked"),
            entry(.click, tier: "auto", approved: true, result: "error: boom"),
        ])
        let s = ReceiptReplayFormatter.renderConfidenceReport(r, scope: "test")
        #expect(s.contains("executed clean"))
        #expect(s.contains("50%"))  // 1 of 2 clean
        #expect(s.contains("boom"))
    }
}
