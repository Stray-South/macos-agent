/// ReceiptReader.swift
///
/// Unit 16 — read-only sibling of `ReceiptWriter`. Pulls `ActionLogEntry`
/// rows from the `~/Library/Application Support/MacAgent/receipts/`
/// JSONL tree. Used by `MacAgentReplay` CLI and any future read-only
/// consumer. Mirrors the decode pattern from `decodeReceipts` (in
/// `MacOSAgentV0/ReceiptLoader.swift`) but lives in `MacAgentCore` so
/// it's reachable from sibling executables.
///
/// The reader never writes, never deletes, never mutates the receipts
/// tree. Malformed JSONL lines are counted, not propagated — a single
/// corrupt entry must not block the rest of the read.
import Foundation

public enum ReceiptReader {

    public struct ReadResult: Sendable {
        public let entries: [ActionLogEntry]
        public let skipped: Int
        public init(entries: [ActionLogEntry], skipped: Int) {
            self.entries = entries
            self.skipped = skipped
        }
    }

    /// Read all JSONL receipt files under `baseURL`, returning entries
    /// in **newest-first order**: files sorted by content-modification
    /// date descending; within each file, lines reversed so the most
    /// recent entry is first. Mirrors `decodeReceipts` semantics from
    /// the Settings UI. Missing directory returns an empty result
    /// without throwing — the CLI's "no receipts yet" path is a normal
    /// state, not an error.
    public static func loadAllNewestFirst(baseURL: URL) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return ReadResult(entries: [], skipped: 0)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        return decode(files: files)
    }

    /// Read a single day's receipts. The filename is `yyyy-MM-dd.jsonl`
    /// per `ReceiptWriter`. UTC, locale `en_US_POSIX`. Missing file
    /// returns an empty result.
    ///
    /// Not `throws` — the body uses only non-throwing APIs
    /// (`FileManager.fileExists`, internal `decode(files:)`). The
    /// sibling `loadAllNewestFirst` IS `throws` because
    /// `contentsOfDirectory` can fail on permission errors.
    public static func loadDay(baseURL: URL, date: Date) -> ReadResult {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .iso8601)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        let filename = df.string(from: date) + ".jsonl"
        let fileURL = baseURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ReadResult(entries: [], skipped: 0)
        }
        return decode(files: [fileURL])
    }

    // MARK: - Internals

    private static func decode(files: [URL]) -> ReadResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [ActionLogEntry] = []
        var skipped = 0
        for file in files {
            let content = (try? String(contentsOf: file)) ?? ""
            // Reverse lines within a file so the most recent entry is first —
            // matches `decodeReceipts` newest-first semantics from the
            // Settings UI.
            let lines = content
                .split(separator: "\n", omittingEmptySubsequences: true)
                .reversed()
            for line in lines {
                guard let data = line.data(using: .utf8) else { skipped += 1; continue }
                do {
                    let entry = try decoder.decode(ActionLogEntry.self, from: data)
                    entries.append(entry)
                } catch {
                    skipped += 1
                }
            }
        }
        return ReadResult(entries: entries, skipped: skipped)
    }
}
