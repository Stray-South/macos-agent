/// SnapshotWriter.swift
///
/// Unit 19 / Path D Candidate 3 Phase 2a — persistent snapshot sidecar.
///
/// `ReceiptWriter` records what the agent DID (one JSONL line per
/// action). `SnapshotWriter` records what the agent SAW at the moment
/// of the action: the full `PerceptionSnapshot` keyed by its
/// `snapshotHash`. Together they make a run forensically replayable —
/// `MacAgentReplay --snapshot <hash>` can pretty-print the element
/// list that the LLM was looking at when it picked the offending
/// `targetIndex`.
///
/// Storage layout (mirrors AGENTS.md §Agent State Files chmod path):
///
///     ~/Library/Application Support/MacAgent/snapshots/
///         YYYY-MM-DD/          (0700)
///             <hash>.json      (0600)
///
/// Daily folder matches receipt convention; eases prune-by-date.
/// Hash-keyed files dedupe identical snapshots across many receipts
/// in the same run (the agent's UI state often holds steady across
/// several actions — same hash, one file).
///
/// **Default screenshot-PNG behaviour: STRIPPED.** A real captured
/// PNG at retina resolution is 500 KB – 2 MB; base64-encoded into
/// JSON it's 4/3 of that. At 200 actions/day this is 100–500 MB/day —
/// unacceptable without retention. Operator can opt into PNG-in-sidecar
/// via the `includeScreenshot:` init param if a future feature needs
/// it; default ships the structured data only.
///
/// **Dedupe-by-hash.** A snapshot with `hash="abc..."` writes
/// `<day>/abc.json` once and skips on every subsequent call. The
/// `snapshotHash` already excludes the PNG and the logical-size from
/// its compute, so identical UI states with different capture rounds
/// hash equal.
///
/// **Opt-in.** Construction is gated at AppModel.makeOrchestrator —
/// the writer only exists when `UserDefaults.agentSuite.persistSnapshots`
/// is true. The Orchestrator receives `snapshotWriter: SnapshotWriter?`;
/// nil means "feature off, do nothing." Default off — disk-growth has
/// visible consequences; operator opts in.
///
/// Threading: actor isolation makes concurrent writes safe. The
/// Orchestrator's fire-and-forget Task pattern ensures snapshot
/// persistence doesn't block the loop.
import Foundation
import os.log

private let snapshotLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "SnapshotWriter"
)

public enum SnapshotWriterError: Error, LocalizedError, Sendable {
    case noApplicationSupportDirectory

    public var errorDescription: String? {
        "Could not locate the Application Support directory. Snapshot sidecars cannot be written."
    }
}

public actor SnapshotWriter {
    private let baseURL: URL
    private let includeScreenshot: Bool
    private let encoder: JSONEncoder
    private let dateFormatter: DateFormatter

    public static func defaultBaseURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw SnapshotWriterError.noApplicationSupportDirectory
        }
        return appSupport.appendingPathComponent("MacAgent/snapshots", isDirectory: true)
    }

    /// Production factory — symmetric to `ReceiptWriter.production()`.
    public static func production(includeScreenshot: Bool = false) -> SnapshotWriter {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("MacAgent/snapshots", isDirectory: true)
        return SnapshotWriter(
            baseURL: (try? Self.defaultBaseURL()) ?? fallback,
            includeScreenshot: includeScreenshot
        )
    }

    public init(baseURL: URL? = nil, includeScreenshot: Bool = false) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let fallback = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("MacAgent/snapshots", isDirectory: true)
            self.baseURL = (try? Self.defaultBaseURL()) ?? fallback
        }
        self.includeScreenshot = includeScreenshot
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.dateFormatter = SnapshotDayFolderFormatter.make()
    }

    /// Persist a snapshot at `<baseURL>/YYYY-MM-DD/<hash>.json`.
    ///
    /// **Idempotent by hash:** if the file already exists, this is a
    /// no-op (no encode, no write, no chmod). Subsequent observations
    /// with the same hash within a run incur no extra disk I/O.
    ///
    /// `screenshotPNG` is stripped from the encoded payload by default
    /// (see `includeScreenshot`). The on-disk JSON contains the
    /// structured fields only.
    public func persist(_ snapshot: PerceptionSnapshot) async {
        let dayDir = baseURL.appendingPathComponent(
            dateFormatter.string(from: snapshot.timestamp),
            isDirectory: true
        )
        let fileURL = dayDir.appendingPathComponent("\(snapshot.hash).json")

        // Dedupe: skip if a sidecar for this hash already exists today.
        // Same UI state across multiple receipts in a run reuses one file.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }

        do {
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            // Tighten parent dir + day dir to 0700 per AGENTS.md
            // §Agent State Files. Best-effort; chmod failure does not
            // block the snapshot from being persisted (the payload is
            // pure UI state, lower privacy risk than typeText receipts —
            // but we still enforce the umbrella policy).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: baseURL.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dayDir.path
            )

            let payload = includeScreenshot ? snapshot : Self.withoutScreenshot(snapshot)
            let data = try encoder.encode(payload)

            // Reviewer-caught Sev-2: switched from `replaceItemAt`
            // (whose documented contract assumes an EXISTING destination
            // — behavior on first write is implementation-defined per
            // Foundation) to `Data.write(.atomic)`, which is documented
            // to write via tmp + atomic rename and works uniformly for
            // first-write and overwrite. Mirrors ReceiptWriter's pattern
            // (CapabilityRuleStore uses replaceItemAt but only after a
            // bootstrap path that guarantees the destination exists).
            //
            // The atomic-rename swaps the inode and resets file attrs,
            // so 0600 must be re-applied after the write. Best-effort
            // chmod (try?) is documented in AGENTS.md §Agent State Files
            // as the accepted sub-millisecond gap pattern.
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            // Non-fatal — the receipt log is the primary audit trail;
            // snapshot sidecar is the augmentation. Failure here means
            // `MacAgentReplay --snapshot <hash>` won't find this one,
            // but the receipt itself is unaffected.
            //
            // Reviewer-caught Sev-2 (lastPersistError):
            // path leaks via `error.localizedDescription` are a real
            // privacy surface IF the error is exposed to a UI. We don't
            // expose it (YAGNI — no Settings consumer yet), and we
            // mark the log line `.private` per established convention.
            // If a future Settings UI needs to surface this, sanitize
            // at that boundary.
            snapshotLog.error("SnapshotWriter.persist failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Returns a copy of `snapshot` with `screenshotPNG` set to nil
    /// (and `screenshotLogicalSize` likewise, since the two fields
    /// only make sense as a pair). All other fields are preserved.
    ///
    /// **Maintenance note**: if `PerceptionSnapshot` grows a new field
    /// with no default value in `PerceptionSnapshot.init`, the Swift
    /// compiler will catch the missing argument here and fail the
    /// build — explicit memberwise call is the safety mechanism. A
    /// new field WITH a default that ought to be preserved verbatim
    /// (not the default) is a maintenance trap to watch for.
    ///
    /// `internal` so tests can verify the strip path explicitly.
    internal static func withoutScreenshot(_ snapshot: PerceptionSnapshot) -> PerceptionSnapshot {
        PerceptionSnapshot(
            timestamp: snapshot.timestamp,
            focusedAppBundleID: snapshot.focusedAppBundleID,
            elements: snapshot.elements,
            hash: snapshot.hash,
            visionObservations: snapshot.visionObservations,
            visionUsedFullScreenFallback: snapshot.visionUsedFullScreenFallback,
            elementListTruncated: snapshot.elementListTruncated,
            visionIndexOffset: snapshot.visionIndexOffset,
            captureOrigin: snapshot.captureOrigin,
            screenshotPNG: nil,
            screenshotLogicalSize: nil,
            agentIsOverlaid: snapshot.agentIsOverlaid
        )
    }
}

/// Reviewer-caught Sev-2: `SnapshotWriter` and `SnapshotReader.prune`
/// both format/parse day folder names as `yyyy-MM-dd` UTC. Independent
/// formatter instances are a maintenance trap — a locale/timezone
/// experiment in one site without the matching change in the other
/// would silently break prune (it would skip all folders the writer
/// created). Shared factory closes that trap.
///
/// `DateFormatter` is not `Sendable` in Swift 6.2, so we return a
/// fresh instance per call rather than a static-let cache.
internal enum SnapshotDayFolderFormatter {
    static func make() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}
