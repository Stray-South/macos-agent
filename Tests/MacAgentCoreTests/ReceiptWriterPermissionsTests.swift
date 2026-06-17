import Foundation
@testable import MacAgentCore
import Testing

// Cluster A: ReceiptWriter must persist daily JSONL files with mode 0600 and
// the containing directory with mode 0700. Receipts hold cleartext typeText
// payloads (passwords/2FA codes approved by the operator per MANIFEST §Receipt
// Model "Cleartext by design") — default umask 0644 left them world-readable.

private func modeOf(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return (attrs[.posixPermissions] as? Int) ?? -1
}

@Test
func receiptWriter_persistsJSONLAt0600() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let entry = ActionLogEntry(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        action: AgentAction(type: .complete, confidence: 1.0,
                            requiresConfirmation: false, rationale: "done"),
        tier: "auto",
        approved: true,
        executionResult: "ok",
        durationMs: 0,
        snapshotHash: "fixture"
    )
    try await writer.write(entry)

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    #expect(files.count == 1, "Exactly one daily JSONL must exist after one write.")
    let mode = try modeOf(files[0].path)
    #expect(mode == 0o600,
            "Receipt JSONL must be mode 0600 (owner-rw, no group/other). Got: \(String(format: "0%o", mode))")
}

@Test
func receiptWriter_tightensParentDirectoryTo0700() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let entry = ActionLogEntry(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        action: AgentAction(type: .complete, confidence: 1.0,
                            requiresConfirmation: false, rationale: "done"),
        tier: "auto",
        approved: true,
        executionResult: "ok",
        durationMs: 0,
        snapshotHash: "fixture"
    )
    try await writer.write(entry)

    let mode = try modeOf(tmp.path)
    #expect(mode == 0o700,
            "Receipts directory must be mode 0700 (owner-rwx, no group/other). Got: \(String(format: "0%o", mode))")
}

@Test
func receiptWriter_reAppliesModeAfterEachAtomicWrite() async throws {
    // Atomic write replaces the file's inode each call. The previous-call's
    // 0600 attribute lives on a now-deleted inode; the new inode would inherit
    // the user's umask (typically 0644). chmod must run on every write, not
    // just at first creation.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let makeEntry: (String) -> ActionLogEntry = { rationale in
        ActionLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            action: AgentAction(type: .complete, confidence: 1.0,
                                requiresConfirmation: false, rationale: rationale),
            tier: "auto", approved: true, executionResult: "ok",
            durationMs: 0, snapshotHash: "fixture"
        )
    }
    try await writer.write(makeEntry("first"))
    try await writer.write(makeEntry("second"))
    try await writer.write(makeEntry("third"))

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let mode = try modeOf(files[0].path)
    #expect(mode == 0o600,
            "After three successive writes the JSONL must still be 0600 — chmod must re-apply per write.")
}
