import Foundation
import MacAgentCore

/// One row displayed in the Settings → Recent Receipts list.
/// Moved from SettingsView.swift to enable @testable import from the test target
/// without dragging the SwiftUI view surface along with it.
struct ReceiptRow: Identifiable {
    let id = UUID()
    let date: String
    let action: String
    let result: String
    let approved: Bool
    let tier: String
}

struct ReceiptDecodeResult {
    let rows: [ReceiptRow]
    let skipped: Int
}

/// Pure decode loop — no I/O dependencies except the injectable `readContents`.
/// Lifted out of SettingsView.loadReceipts() so the test target can drive it with
/// a synthetic JSONL fixture and assert the skipped-count behavior (F5).
///
/// - Parameters:
///   - files: receipt JSONL files in newest-first order. The function reads each in turn,
///            from the last line backward, until `cap` rows are collected.
///   - cap: maximum rows to return. Default 30 matches the Settings UI cap.
///   - decoder: pre-configured JSONDecoder (caller supplies date strategy).
///   - dateFormatter: formats `entry.timestamp` into the `date` column.
///   - readContents: file→string reader, injectable for tests.
/// - Returns: rows (newest-first across files) and a count of JSONL lines that failed to decode.
func decodeReceipts(
    files: [URL],
    cap: Int = 30,
    decoder: JSONDecoder,
    dateFormatter: DateFormatter,
    readContents: (URL) -> String? = { try? String(contentsOf: $0) }
) -> ReceiptDecodeResult {
    var rows: [ReceiptRow] = []
    var skipped = 0
    outer: for file in files {
        let content = readContents(file) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        for line in lines {
            guard rows.count < cap else { break outer }
            guard let data = line.data(using: .utf8) else { skipped += 1; continue }
            do {
                let entry = try decoder.decode(ActionLogEntry.self, from: data)
                let textSnippet = entry.action.text.map { " \"\($0.prefix(20))\"" } ?? ""
                let targetSnippet = entry.action.targetIndex.map { " [\($0)]" } ?? ""
                rows.append(ReceiptRow(
                    date: dateFormatter.string(from: entry.timestamp),
                    action: "\(entry.action.type.rawValue)\(targetSnippet)\(textSnippet)",
                    result: entry.executionResult,
                    approved: entry.approved,
                    tier: entry.tier
                ))
            } catch {
                // F5: corrupt JSONL lines counted so the section header surfaces a chip.
                skipped += 1
            }
        }
    }
    return ReceiptDecodeResult(rows: rows, skipped: skipped)
}
