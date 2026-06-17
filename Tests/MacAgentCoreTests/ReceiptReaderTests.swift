/// ReceiptReaderTests.swift
///
/// Unit 16 — exercises the read-only sibling of `ReceiptWriter` against
/// real-on-disk fixtures (temp dirs only — never the operator's
/// production receipts). Mirrors the test pattern of
/// `ReceiptWriterPermissionsTests` and `receiptWriterProducesValidJSONL`.
import Foundation
@testable import MacAgentCore
import Testing

private func makeEntry(seq: Int) -> ActionLogEntry {
    ActionLogEntry(
        timestamp: Date(timeIntervalSince1970: 1_779_572_000 + Double(seq)),
        action: AgentAction(
            type: .click, targetIndex: seq, text: nil,
            confidence: 0.9, requiresConfirmation: false, rationale: "step \(seq)"
        ),
        tier: "auto", approved: true,
        executionResult: "clicked", durationMs: seq, snapshotHash: "h\(seq)"
    )
}

@Test
func receiptReader_missingDir_returnsEmptyNoThrow() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Deliberately do NOT create tmp — first-launch state.
    let result = try ReceiptReader.loadAllNewestFirst(baseURL: tmp)
    #expect(result.entries.isEmpty)
    #expect(result.skipped == 0,
            "missing dir must not be counted as 'skipped' — it's a clean empty state, not a parse failure")
}

@Test
func receiptReader_loadAllNewestFirst_returnsEntries() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let writer = ReceiptWriter(baseURL: tmp)
    for i in 0..<5 {
        try await writer.write(makeEntry(seq: i))
    }
    let result = try ReceiptReader.loadAllNewestFirst(baseURL: tmp)
    #expect(result.entries.count == 5)
    #expect(result.skipped == 0)
    // Newest-first within the single day's file: entry seq=4 must come
    // before seq=0 because lines are reversed.
    #expect(result.entries.first?.action.targetIndex == 4,
            "newest-first: last-written entry must be at index 0")
    #expect(result.entries.last?.action.targetIndex == 0)
}

@Test
func receiptReader_malformedLine_countedAsSkipped() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    // Build a JSONL file with one valid line + one garbage line.
    let valid = makeEntry(seq: 7)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let validData = try encoder.encode(valid)
    let validLine = String(data: validData, encoding: .utf8)!

    let payload = "\(validLine)\n{not valid json}\n"
    let filename = "2026-05-23.jsonl"
    try payload.write(to: tmp.appendingPathComponent(filename), atomically: true, encoding: .utf8)

    let result = try ReceiptReader.loadAllNewestFirst(baseURL: tmp)
    #expect(result.entries.count == 1, "valid line must be returned despite sibling malformed line")
    #expect(result.skipped == 1, "malformed line must be counted as skipped, not silently dropped")
}

@Test
func receiptReader_loadDay_singleFileFilter() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

    // Write entries explicitly across two dates by post-writing renamed files
    // (ReceiptWriter chooses the filename from entry.timestamp so we'd need
    // to construct two different timestamps; simpler: write two synthetic
    // files directly with hand-built JSONL).
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let dayA = ActionLogEntry(
        timestamp: Date(timeIntervalSince1970: 1_779_494_400), // 2026-05-23 UTC
        action: AgentAction(type: .click, targetIndex: 1, text: nil,
                            confidence: 0.9, requiresConfirmation: false, rationale: "a"),
        tier: "auto", approved: true,
        executionResult: "clicked", durationMs: 1, snapshotHash: "a"
    )
    let dayB = ActionLogEntry(
        timestamp: Date(timeIntervalSince1970: 1_779_580_801), // 2026-05-24 UTC
        action: AgentAction(type: .click, targetIndex: 2, text: nil,
                            confidence: 0.9, requiresConfirmation: false, rationale: "b"),
        tier: "auto", approved: true,
        executionResult: "clicked", durationMs: 1, snapshotHash: "b"
    )
    let aData = try encoder.encode(dayA) + Data([0x0a])
    let bData = try encoder.encode(dayB) + Data([0x0a])
    try aData.write(to: tmp.appendingPathComponent("2026-05-23.jsonl"))
    try bData.write(to: tmp.appendingPathComponent("2026-05-24.jsonl"))

    // loadDay must return ONLY the matching file's contents.
    let target = Date(timeIntervalSince1970: 1_779_494_400)
    let result = ReceiptReader.loadDay(baseURL: tmp, date: target)
    #expect(result.entries.count == 1)
    #expect(result.entries.first?.action.targetIndex == 1)
    #expect(result.skipped == 0)
}

@Test
func receiptReader_loadDay_missingFileReturnsEmpty() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // Empty directory; loadDay must not throw on missing day file.
    let result = ReceiptReader.loadDay(baseURL: tmp, date: Date())
    #expect(result.entries.isEmpty)
    #expect(result.skipped == 0)
}
