import Foundation
import Testing
@testable import MacOSAgentV0
@testable import MacAgentCore

// MARK: - F5: corrupt JSONL lines are counted, not silently dropped
//
// Regression guard for the silent-decode-failure bug closed in commit 4003eaf.
// Settings now surfaces a "N unreadable" chip in the section header; that chip
// is fed by ReceiptDecodeResult.skipped. If decodeReceipts ever reverts to
// `try?` instead of try/catch+counter, this test fails.

@Test
func decodeReceiptsCountsCorruptLines() throws {
    // Build the valid line by round-tripping an ActionLogEntry through JSONEncoder.
    // Avoids hand-rolling JSON that drifts when AgentAction's Codable shape changes.
    let action = AgentAction(
        type: .click,
        targetIndex: 0,
        text: nil,
        confidence: 0.9,
        requiresConfirmation: false,
        rationale: "test"
    )
    let entry = ActionLogEntry(
        action: action,
        tier: "auto",
        approved: true,
        executionResult: "success",
        durationMs: 42,
        snapshotHash: "deadbeef"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let validData = try encoder.encode(entry)
    let validLine = String(decoding: validData, as: UTF8.self)
    let corruptLine = "{this is not json"

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("decodeReceipts-\(UUID().uuidString).jsonl")
    try (validLine + "\n" + corruptLine + "\n").write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short

    let result = decodeReceipts(files: [tmp], decoder: decoder, dateFormatter: df)

    #expect(result.rows.count == 1,
            "One valid line → exactly one ReceiptRow")
    #expect(result.skipped == 1,
            "One corrupt line → skipped count of 1")
    #expect(result.rows.first?.approved == true,
            "Decoded row carries the original approved=true")
}

@Test
func decodeReceiptsRespectsCap() throws {
    // Defensive: if cap is exceeded, the function stops collecting rows.
    // Guards the 30-row Settings UI cap from accidental removal.
    let action = AgentAction(
        type: .click, targetIndex: 0, text: nil,
        confidence: 0.9, requiresConfirmation: false, rationale: "cap"
    )
    let entry = ActionLogEntry(
        action: action, tier: "auto", approved: true,
        executionResult: "success", durationMs: 1, snapshotHash: "h"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let line = String(decoding: try encoder.encode(entry), as: UTF8.self)
    let body = Array(repeating: line, count: 50).joined(separator: "\n") + "\n"

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("decodeReceipts-cap-\(UUID().uuidString).jsonl")
    try body.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short

    let result = decodeReceipts(files: [tmp], cap: 10, decoder: dec, dateFormatter: df)
    #expect(result.rows.count == 10, "cap=10 must stop the function at 10 rows")
    #expect(result.skipped == 0, "No corrupt lines → skipped=0")
}
