/// SnapshotReader.swift
///
/// Unit 19 — read-only sibling of `SnapshotWriter`. Loads persisted
/// `PerceptionSnapshot` sidecars from the daily folder layout the
/// writer emits. Used by `MacAgentReplay --snapshot <hash>` to
/// reconstruct what the agent saw at the moment a receipted action
/// fired.
///
/// Mirrors `ReceiptReader` ergonomics: never writes, never deletes
/// (except via the explicit `prune` API), missing-file paths return
/// nil rather than throw.
import Foundation

public enum SnapshotReader {

    /// Resolve a hash prefix to all matching full hashes across day
    /// folders. Used by the CLI to support `--snapshot abc12` shorthand
    /// — operator pastes the first ~8 chars from a receipt and the CLI
    /// fills in the rest.
    ///
    /// Returns full hashes in newest-first order (most recent day
    /// folder first). Empty array if no match.
    public static func resolveHashPrefix(_ prefix: String, baseURL: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }
        let lowerPrefix = prefix.lowercased()
        // Day folders sorted newest-first (mtime descending) so the
        // most likely match (recent dogfood) appears first when the
        // prefix is ambiguous.
        let days = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        var matches: [String] = []
        for day in days {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for f in files where f.pathExtension == "json" {
                let hash = f.deletingPathExtension().lastPathComponent
                if hash.lowercased().hasPrefix(lowerPrefix) {
                    matches.append(hash)
                }
            }
        }
        return matches
    }

    /// Load a snapshot by its full hash. Returns nil if no sidecar
    /// exists (e.g. the run wasn't persisted — opt-in feature). Walks
    /// day folders newest-first; same hash in two days (impossible
    /// in practice but safe in code) returns the most-recent.
    public static func load(hash: String, baseURL: URL) throws -> PerceptionSnapshot? {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }
        let days = try FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for day in days {
            let candidate = day.appendingPathComponent("\(hash).json")
            if FileManager.default.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let snapshot = try? decoder.decode(PerceptionSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    /// Delete day folders older than `days` from `baseURL`. Operator
    /// runs this manually via `MacAgentReplay --prune-snapshots
    /// --older-than <days>` — no automatic retention daemon.
    /// Returns the count of day folders deleted.
    public static func prune(olderThanDays days: Int, baseURL: URL, now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return 0 }
        guard days >= 0 else { return 0 }
        let cal = Calendar(identifier: .iso8601)
        guard let cutoff = cal.date(byAdding: .day, value: -days, to: now) else { return 0 }
        // Shared formatter — must match SnapshotWriter.dateFormatter
        // contract exactly. See SnapshotDayFolderFormatter.
        let df = SnapshotDayFolderFormatter.make()
        let dayDirs = try FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        var deleted = 0
        for dir in dayDirs {
            let name = dir.lastPathComponent
            // Folder name must parse as YYYY-MM-DD; skip anything else
            // so we don't accidentally delete unrelated entries.
            guard let folderDate = df.date(from: name) else { continue }
            if folderDate < cutoff {
                try FileManager.default.removeItem(at: dir)
                deleted += 1
            }
        }
        return deleted
    }
}
