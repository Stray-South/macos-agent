/// MacAgentReplay — read-only forensic CLI for the agent's receipts.
///
/// Unit 16 / Path D Candidate 3 Phase 1. Closes the friction point
/// surfaced in `docs/dogfood-loop.md`: today's "today-mode" capture
/// step requires `jq` + time-window matching. This CLI replaces that
/// pipeline with a structured, filterable view.
///
/// Hard read-only — never posts CGEvent, never calls Anthropic, never
/// touches anything outside the receipts directory. Matches the
/// Settings UI's defaults: newest-first across all daily files, cap
/// 30 entries.
///
/// Privacy: `action.text` for `.typeText` is redacted to `***` unless
/// `--show-text` is supplied. Other action types' `text` (key combos,
/// menu paths) prints verbatim — no privacy risk, useful for diagnosis.
import Foundation
import MacAgentCore

@main
struct MacAgentReplay {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        // Parse flags. Hand-rolled — Package.swift dependencies array
        // stays `[]` per CLAUDE.md ground rule (no ArgumentParser dep).
        var dateFlag: String? = nil
        var errorsOnly = false
        var showText = false
        var cap = 30
        // Unit 19 — snapshot subcommands.
        var snapshotHashPrefix: String? = nil
        var pruneSnapshots = false
        var pruneOlderThanDays: Int? = nil
        // Unit 21 / Path D Candidate 3 Phase 2b — snapshot diff.
        var diffHashPrefixes: (String, String)? = nil
        var reportMode = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--date":
                guard i + 1 < args.count else {
                    errorOut("--date requires a value (YYYY-MM-DD or 'today')")
                }
                dateFlag = args[i + 1]
                i += 2
            case "--errors":
                errorsOnly = true
                i += 1
            case "--report":
                reportMode = true
                i += 1
            case "--show-text":
                showText = true
                i += 1
            case "--limit":
                guard i + 1 < args.count, let parsed = Int(args[i + 1]), parsed >= 0 else {
                    errorOut("--limit requires a non-negative integer")
                }
                cap = parsed
                i += 2
            case "--snapshot":
                guard i + 1 < args.count else {
                    errorOut("--snapshot requires a hash or hash prefix")
                }
                snapshotHashPrefix = args[i + 1]
                i += 2
            case "--prune-snapshots":
                pruneSnapshots = true
                i += 1
            case "--older-than":
                guard i + 1 < args.count, let parsed = Int(args[i + 1]), parsed >= 0 else {
                    errorOut("--older-than requires a non-negative integer (days)")
                }
                pruneOlderThanDays = parsed
                i += 2
            case "--diff":
                // Reviewer-caught: reject flag-shaped hash args. Without
                // this guard, `--diff hashA --snapshot` would silently
                // set hashB="--snapshot" and the operator gets a
                // confusing "No snapshot matching prefix '--snapshot'"
                // error rather than "you need two hash prefixes here."
                guard i + 2 < args.count,
                      !args[i + 1].hasPrefix("--"),
                      !args[i + 2].hasPrefix("--") else {
                    errorOut("--diff requires two hash prefixes: --diff <hash-A> <hash-B>")
                }
                diffHashPrefixes = (args[i + 1], args[i + 2])
                i += 3
            default:
                errorOut("unknown argument: \(arg). Run --help for usage.")
            }
        }

        // Unit 19 — snapshot subcommand dispatch. These modes are
        // mutually exclusive with the receipt-listing default; they
        // return early.
        if pruneSnapshots {
            guard let days = pruneOlderThanDays else {
                errorOut("--prune-snapshots requires --older-than <days>")
            }
            await handlePruneSnapshots(olderThanDays: days)
            return
        }
        if let prefix = snapshotHashPrefix {
            await handleSnapshotLookup(hashPrefix: prefix)
            return
        }
        if let (a, b) = diffHashPrefixes {
            await handleSnapshotDiff(hashAPrefix: a, hashBPrefix: b)
            return
        }

        var resolvedDate: Date? = nil
        if let raw = dateFlag {
            guard let parsed = ReceiptReplayFormatter.parseDateFlag(raw) else {
                errorOut("invalid --date value: \(raw). Expected YYYY-MM-DD or 'today'.")
            }
            resolvedDate = parsed
        }

        // Resolve receipts directory. Mirrors ReceiptWriter's
        // production fallback chain.
        let baseURL: URL
        do {
            baseURL = try ReceiptWriter.defaultBaseURL()
        } catch {
            errorOut("could not resolve receipts directory: \(error.localizedDescription)")
        }

        // Read. Empty/missing dir → empty result, exit 0 (not an
        // error — first-launch state is normal per Path E runbook).
        let result: ReceiptReader.ReadResult
        if let date = resolvedDate {
            // loadDay is non-throwing — missing-file is the empty path.
            result = ReceiptReader.loadDay(baseURL: baseURL, date: date)
        } else {
            do {
                result = try ReceiptReader.loadAllNewestFirst(baseURL: baseURL)
            } catch {
                errorOut("failed to read receipts: \(error.localizedDescription)")
            }
        }

        if result.entries.isEmpty && result.skipped == 0 {
            let suffix = resolvedDate.map { _ in " for the requested date" } ?? ""
            print("No receipts found\(suffix) at \(baseURL.path).")
            exit(0)
        }

        // Phase G4 — confidence report: a structured summary of the loaded
        // receipts (success/stall/yield/error rates, tier + type histograms,
        // the actual problems). Dogfood evidence, not vibes.
        if reportMode {
            let scope = resolvedDate != nil ? (dateFlag ?? "date") : "all receipts"
            let report = ReceiptReplayFormatter.confidenceReport(result.entries)
            print(ReceiptReplayFormatter.renderConfidenceReport(report, scope: scope))
            if result.skipped > 0 {
                print("  (\(result.skipped) malformed line(s) skipped)")
            }
            return
        }

        // Filter + render. --date filtering is technically redundant
        // when we already loaded a single day, but the formatter is
        // tolerant of that (no-op pass).
        let filtered = ReceiptReplayFormatter.filter(
            entries: result.entries,
            date: resolvedDate,
            errorsOnly: errorsOnly,
            cap: cap
        )

        if filtered.isEmpty {
            let what = errorsOnly ? "error receipts" : "receipts"
            let where_ = resolvedDate.map { _ in " for the requested date" } ?? ""
            print("No \(what)\(where_) (after filtering).")
        } else {
            for line in ReceiptReplayFormatter.format(entries: filtered, showText: showText) {
                print(line)
            }
        }

        // Surface skipped count — same signal the Settings UI shows
        // via its "N unreadable" chip. Useful when bisecting a
        // schema-drift or partial-write incident.
        if result.skipped > 0 {
            FileHandle.standardError.write(Data(
                "(\(result.skipped) JSONL line\(result.skipped == 1 ? "" : "s") could not be decoded — skipped.)\n".utf8
            ))
        }

        exit(0)
    }

    // MARK: - Unit 19: snapshot subcommands

    /// Resolve a hash prefix to a single full hash, load the persisted
    /// snapshot, and pretty-print. Exit codes:
    ///   0 — success
    ///   1 — no match (no sidecar with that hash prefix, or feature
    ///       off and `snapshots/` doesn't exist)
    ///   2 — ambiguous prefix (>1 matches; list candidates)
    private static func handleSnapshotLookup(hashPrefix: String) async {
        let baseURL: URL
        do {
            baseURL = try SnapshotWriter.defaultBaseURL()
        } catch {
            errorOut("could not resolve snapshots directory: \(error.localizedDescription)")
        }
        let matches: [String]
        do {
            matches = try SnapshotReader.resolveHashPrefix(hashPrefix, baseURL: baseURL)
        } catch {
            errorOut("failed to scan snapshots directory: \(error.localizedDescription)")
        }
        if matches.isEmpty {
            FileHandle.standardError.write(Data(
                "No snapshot matching prefix '\(hashPrefix)'.\n\n".utf8
            ))
            FileHandle.standardError.write(Data("""
                Possible reasons:
                  • Snapshot persistence is off (Settings → Forensics → Persist snapshots to disk).
                    Snapshots are opt-in and only the run with the toggle ON gets sidecar files.
                  • The receipt referencing this hash was written before Unit 19 shipped.
                  • The day folder was pruned via --prune-snapshots --older-than N.
                  • Sidecar at \(baseURL.path) doesn't yet exist.
                \n
                """.utf8))
            exit(1)
        }
        if matches.count > 1 {
            FileHandle.standardError.write(Data(
                "Ambiguous prefix '\(hashPrefix)' matches \(matches.count) snapshots:\n".utf8
            ))
            for hash in matches.prefix(10) {
                FileHandle.standardError.write(Data("  \(hash)\n".utf8))
            }
            if matches.count > 10 {
                FileHandle.standardError.write(Data("  … (\(matches.count - 10) more)\n".utf8))
            }
            FileHandle.standardError.write(Data(
                "\nUse a longer prefix to disambiguate.\n".utf8
            ))
            exit(2)
        }
        // Exactly one match — load + pretty-print.
        let hash = matches[0]
        let snapshot: PerceptionSnapshot?
        do {
            snapshot = try SnapshotReader.load(hash: hash, baseURL: baseURL)
        } catch {
            errorOut("failed to load snapshot \(hash): \(error.localizedDescription)")
        }
        guard let snapshot else {
            // Should not happen — resolveHashPrefix found the file, so
            // load() should succeed. Race condition (pruned between
            // calls) is the only realistic path.
            errorOut("snapshot \(hash) found by prefix scan but failed to decode (raced with prune?)")
        }
        print(ReceiptReplayFormatter.formatSnapshot(snapshot))
        exit(0)
    }

    /// Unit 21 — positional diff between two persisted snapshots.
    /// Resolves both prefixes (must each map to exactly one hash),
    /// loads both, prints the formatted diff. Exit codes:
    ///   0 — success (diff or "identical" output)
    ///   1 — either prefix matches zero hashes
    ///   2 — either prefix matches multiple hashes
    private static func handleSnapshotDiff(hashAPrefix: String, hashBPrefix: String) async {
        let baseURL: URL
        do {
            baseURL = try SnapshotWriter.defaultBaseURL()
        } catch {
            errorOut("could not resolve snapshots directory: \(error.localizedDescription)")
        }
        let aHash = resolveSingleHash(prefix: hashAPrefix, baseURL: baseURL, label: "A")
        let bHash = resolveSingleHash(prefix: hashBPrefix, baseURL: baseURL, label: "B")
        let aSnap: PerceptionSnapshot?
        let bSnap: PerceptionSnapshot?
        do {
            aSnap = try SnapshotReader.load(hash: aHash, baseURL: baseURL)
            bSnap = try SnapshotReader.load(hash: bHash, baseURL: baseURL)
        } catch {
            errorOut("failed to load snapshots: \(error.localizedDescription)")
        }
        guard let a = aSnap else {
            errorOut("snapshot A (\(aHash)) decoded as nil — raced with prune?")
        }
        guard let b = bSnap else {
            errorOut("snapshot B (\(bHash)) decoded as nil — raced with prune?")
        }
        print(ReceiptReplayFormatter.formatSnapshotDiff(a, b))
        exit(0)
    }

    /// Shared helper for `--snapshot` and `--diff`. Resolves a hash
    /// prefix to exactly one full hash; exits 1 on no match, 2 on
    /// ambiguous match (with disambiguation list to stderr). The
    /// `label` parameter distinguishes A from B in `--diff`'s error
    /// messages.
    private static func resolveSingleHash(prefix: String, baseURL: URL, label: String = "") -> String {
        let matches: [String]
        do {
            matches = try SnapshotReader.resolveHashPrefix(prefix, baseURL: baseURL)
        } catch {
            errorOut("failed to scan snapshots directory: \(error.localizedDescription)")
        }
        let qualifier = label.isEmpty ? "" : " (\(label))"
        if matches.isEmpty {
            FileHandle.standardError.write(Data(
                "No snapshot matching prefix\(qualifier) '\(prefix)'.\n".utf8
            ))
            exit(1)
        }
        if matches.count > 1 {
            FileHandle.standardError.write(Data(
                "Ambiguous prefix\(qualifier) '\(prefix)' matches \(matches.count) snapshots:\n".utf8
            ))
            for h in matches.prefix(10) {
                FileHandle.standardError.write(Data("  \(h)\n".utf8))
            }
            if matches.count > 10 {
                FileHandle.standardError.write(Data("  … (\(matches.count - 10) more)\n".utf8))
            }
            exit(2)
        }
        return matches[0]
    }

    /// Delete day folders older than `olderThanDays` from the snapshots
    /// directory. Prints the count deleted.
    private static func handlePruneSnapshots(olderThanDays: Int) async {
        let baseURL: URL
        do {
            baseURL = try SnapshotWriter.defaultBaseURL()
        } catch {
            errorOut("could not resolve snapshots directory: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            print("No snapshots directory at \(baseURL.path) — nothing to prune.")
            exit(0)
        }
        let deleted: Int
        do {
            deleted = try SnapshotReader.prune(olderThanDays: olderThanDays, baseURL: baseURL)
        } catch {
            errorOut("prune failed: \(error.localizedDescription)")
        }
        print("Pruned \(deleted) day folder\(deleted == 1 ? "" : "s") older than \(olderThanDays) day\(olderThanDays == 1 ? "" : "s").")
        exit(0)
    }

    private static func printUsage() {
        let usage = """
        MacAgentReplay — read-only forensic view of MacAgent receipts.

        USAGE
          swift run MacAgentReplay [options]

        OPTIONS
          --date <YYYY-MM-DD|today>  Show only the matching UTC day. Filename-aligned.
          --errors                   Show only errors (approved=false OR result starts with "error:").
          --report                   Confidence summary: success/stall/yield/error rates,
                                     tier + type histograms, and the actual problems.
          --show-text                Print action.text verbatim for .typeText actions.
                                     DEFAULT: redacted to "***" because typeText payloads
                                     can carry operator-approved password / 2FA cleartext
                                     (MANIFEST §Snapshot/Receipt Model). Key combos and
                                     menu paths are always shown verbatim — no privacy risk.
          --limit <N>                Override the default 30-entry cap (post-filter).
          --help, -h                 Print this help and exit 0.

        SNAPSHOT SUBCOMMANDS (Unit 19+21, opt-in via Settings → Forensics)
          --snapshot <hash-prefix>   Pretty-print the persisted snapshot whose hash
                                     starts with this prefix. Lists elements + vision
                                     observations as a two-table report.
          --diff <hash-A> <hash-B>   Positional diff between two snapshots. Header
                                     (bundleID, element/vision deltas), per-index
                                     CHANGED/ADDED/REMOVED lines with affected fields.
                                     Identical hashes print "Snapshots are identical."
          --prune-snapshots          Delete day folders older than the threshold.
          --older-than <days>        Required with --prune-snapshots. Non-negative int.

        EXAMPLES
          swift run MacAgentReplay
          swift run MacAgentReplay --date today --errors
          swift run MacAgentReplay --date 2026-05-23 --limit 100
          swift run MacAgentReplay --show-text         # use only when you own the screen
          swift run MacAgentReplay --snapshot abc123
          swift run MacAgentReplay --diff abc123 def456
          swift run MacAgentReplay --prune-snapshots --older-than 30

        PRIVACY
          Receipts live at ~/Library/Application Support/MacAgent/receipts/ (0600 files
          in 0700 umbrella). Snapshots (Unit 19) live at .../snapshots/YYYY-MM-DD/
          with the same 0600/0700 chmod path; screenshotPNG is STRIPPED from sidecars
          by default. This CLI never writes or transmits anything; --prune-snapshots
          is the only delete path and requires --older-than.

        EXIT CODES
          0  Success (including "no receipts found" — normal first-launch state).
          1  Invalid arguments, read error, or --snapshot/--diff prefix matches zero entries.
          2  --snapshot/--diff prefix matches multiple entries (ambiguous — use longer prefix).
        """
        print(usage)
    }

    private static func errorOut(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        exit(1)
    }
}
