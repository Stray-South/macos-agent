/// AgentThroughline.swift
///
/// Persistent cross-session memory for the macOS agent.
///
/// Concept adapted from a prior project of mine (a Python cognitive-context
/// system): a persistent "throughline" of cross-session memory. The original's
/// three-layer architecture is collapsed here into a single lightweight struct
/// scoped to desktop-agent needs.
///
/// Three fields:
///   hardBoundaries  — rules that survive between sessions ("never empty trash")
///   positions       — key/value facts learned across sessions ("preferred browser: Safari")
///   taskHistory     — ring buffer of the last N task outcomes (newest first)
import Foundation

/// A record of one completed or failed agent run.
public struct TaskRecord: Codable, Sendable, Equatable {
    public let task: String
    public let outcome: String        // "success", "failed", "rejected", "aborted"
    public let stepCount: Int
    public let appBundleID: String
    public let timestamp: Date

    public init(task: String, outcome: String, stepCount: Int, appBundleID: String, timestamp: Date = .now) {
        self.task = task
        self.outcome = outcome
        self.stepCount = stepCount
        self.appBundleID = appBundleID
        self.timestamp = timestamp
    }
}

/// Session-level persistent context. Never overwritten by a new run;
/// updated additively after each run completes.
public struct AgentThroughline: Codable, Sendable {
    /// Operator-established rules that persist across sessions.
    /// Example: "Never delete files without explicit user confirmation."
    public var hardBoundaries: [String]

    /// Learned key/value facts about the user's environment or preferences.
    /// Example: ["preferred_browser": "Safari", "notes_shortcut": "cmd+option+n"]
    public var positions: [String: String]

    /// Ring buffer of the most recent task records (newest first, capped at maxHistory).
    public var taskHistory: [TaskRecord]

    public static let maxHistory = 20
    /// Maximum number of distinct hard boundaries kept on disk. Each entry is
    /// rendered into every LLM system prompt; unbounded growth bloats every
    /// future call and is also the only operator-write path adversarial input
    /// can reach via UI or throughline JSON tampering. FIFO eviction matches
    /// the `taskHistory` ring-buffer pattern.
    public static let maxBoundaries = 50

    public init(
        hardBoundaries: [String] = [],
        positions: [String: String] = [:],
        taskHistory: [TaskRecord] = []
    ) {
        self.hardBoundaries = hardBoundaries
        self.positions = positions
        self.taskHistory = taskHistory
    }

    /// Append a completed task record, keeping only the most recent maxHistory entries.
    public mutating func record(_ task: TaskRecord) {
        taskHistory.insert(task, at: 0)
        if taskHistory.count > Self.maxHistory {
            taskHistory = Array(taskHistory.prefix(Self.maxHistory))
        }
    }

    /// Add a hard boundary if it's not already present.
    /// Caps at 500 chars — real operator rules are concise; anything longer is likely poisoned input.
    /// Sanitises before storing so dedup compares canonical forms (otherwise a rule
    /// with embedded newlines and the same rule without would both stick around).
    @discardableResult
    public mutating func addBoundary(_ rule: String) -> Bool {
        let capped = String(rule.prefix(500)).sanitizingForPrompt()
        guard !hardBoundaries.contains(capped) else { return false }
        hardBoundaries.append(capped)
        // FIFO cap — protects every future system prompt from unbounded
        // hardBoundary bloat and protects the throughline JSON file from
        // adversarial-write-without-bound via UI or tampering.
        if hardBoundaries.count > Self.maxBoundaries {
            hardBoundaries.removeFirst(hardBoundaries.count - Self.maxBoundaries)
        }
        return true
    }

    /// Set or overwrite a position (committed fact or preference).
    /// Caps both key and value at 500 chars — mirrors addBoundary()'s limit and prevents
    /// unbounded disk growth or prompt injection from any position write path.
    /// Sanitises before storing so render-time and on-disk representations agree.
    public mutating func establish(key: String, value: String) {
        let safeKey = String(key.prefix(500)).sanitizingForPrompt()
        let safeVal = String(value.prefix(500)).sanitizingForPrompt()
        positions[safeKey] = safeVal
    }

    /// Remove a hard boundary by exact string match. No-op if not present.
    /// Sanitises input so callers can pass either the raw or canonical form.
    public mutating func removeBoundary(_ rule: String) {
        let canonical = rule.sanitizingForPrompt()
        hardBoundaries.removeAll { $0 == canonical }
    }

    /// Remove a learned position by key. No-op if key doesn't exist.
    /// Sanitises input so the lookup matches the canonical stored key.
    public mutating func removePosition(key: String) {
        positions.removeValue(forKey: key.sanitizingForPrompt())
    }

    /// Clear all task history. Hard boundaries and positions are preserved.
    public mutating func clearHistory() {
        taskHistory = []
    }

    /// Format the throughline as a compact block for injection into the LLM system prompt.
    /// Only emits sections that contain data — empty throughline produces an empty string.
    public func promptBlock() -> String {
        var lines: [String] = []

        if !hardBoundaries.isEmpty {
            lines.append("Hard rules (always follow, no exceptions):")
            for rule in hardBoundaries {
                // Double-sanitise (write path already canonicalises) — defence-in-depth for
                // older JSON files written before sanitise-on-write landed. Idempotent.
                let sanitizedRule = String(rule.prefix(500)).sanitizingForPrompt()
                lines.append("  • \(sanitizedRule)")
            }
        }

        if !positions.isEmpty {
            lines.append("Established facts about this user's environment:")
            for (key, value) in positions.sorted(by: { $0.key < $1.key }) {
                // Same defence-in-depth pattern as hardBoundaries above.
                let sanitizedKey   = String(key.prefix(500)).sanitizingForPrompt()
                let sanitizedValue = String(value.prefix(500)).sanitizingForPrompt()
                lines.append("  • \(sanitizedKey): \(sanitizedValue)")
            }
        }

        let recent = Array(taskHistory.prefix(5))
        if !recent.isEmpty {
            lines.append("Recent task history (newest first):")
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withFullDate]
            for record in recent {
                let date = df.string(from: record.timestamp)
                // Both task and appBundleID can carry external content — sanitise both at
                // render time. load() also scrubs on read, but in-memory AgentThroughlines
                // constructed without going through the store (tests, future direct usage)
                // would otherwise reach this point with raw fields.
                let sanitizedTask = String(record.task.prefix(500)).sanitizingForPrompt()
                let sanitizedApp  = record.appBundleID.sanitizingForPrompt()
                lines.append("  • [\(date)] \"\(sanitizedTask)\" → \(record.outcome) (\(record.stepCount) steps, \(sanitizedApp))")
            }
        }

        guard !lines.isEmpty else { return "" }
        return """
        [PERSISTENT CONTEXT — learned from prior sessions]
        \(lines.joined(separator: "\n"))
        """
    }
}

/// Actor that persists the throughline to disk and handles concurrent access.
public actor ThroughlineStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Canonical throughline location: `~/Library/Application Support/MacAgent/throughline.json`.
    /// Mirrors `ReceiptWriter.defaultBaseURL()` so all agent state lives under one
    /// `0700` umbrella in Application Support. Fallback to `~/MacAgent/throughline.json`
    /// only if `applicationSupportDirectory` is unavailable (extremely rare sandbox edge).
    public static func defaultURL() -> URL {
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            return appSupport
                .appendingPathComponent("MacAgent", isDirectory: true)
                .appendingPathComponent("throughline.json")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("MacAgent/throughline.json")
    }

    /// Legacy location used before the 2026-05-23 relocation. Read by
    /// `migrateLegacyHomeDirThroughline` and by `load()` as a fallback if
    /// migration failed (e.g. AppSupport read-only). Never written.
    internal static func legacyDefaultURL() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("MacAgent/throughline.json")
    }

    /// The path this store reads from, set once at init. Stored separately
    /// from `defaultURL()` to avoid a TOCTOU between init-time path
    /// resolution and load-time path resolution (e.g. if AppSupport becomes
    /// available between the two calls, `defaultURL()` would change shape
    /// and the legacy-fallback check in load() would yield a false negative).
    /// Reviewer-flagged in PR-2 adversarial pass.
    private let resolvedDefaultURLAtInit: URL?

    /// Production factory — Unit 11 (defense-in-depth atop Unit 1's
    /// Orchestrator chokepoint). Equivalent of `ReceiptWriter.production()`.
    /// Use this at production construction sites to make the prod-path
    /// intent explicit; the `fileURL: URL? = nil` default stays for
    /// back-compat but the canonical production constructor goes through
    /// here.
    ///
    /// **MUST** call `ThroughlineStore()` (nil-URL path), not
    /// `ThroughlineStore(fileURL: defaultURL())`. The `init` gates
    /// `migrateLegacyHomeDirThroughline` and the load()-time legacy
    /// fallback on `fileURL == nil` — explicit URL skips both. Reviewer-
    /// caught Sev-1 in Unit 11 review: passing the resolved URL silently
    /// stranded pre-2026-05-23 users' throughline data at the legacy
    /// `~/MacAgent/throughline.json` location.
    public static func production() -> ThroughlineStore {
        return ThroughlineStore()
    }

    public init(fileURL: URL? = nil) {
        let resolved = fileURL ?? ThroughlineStore.defaultURL()
        self.fileURL = resolved
        // Snapshot defaultURL() at init only if the caller used the default —
        // explicit-fileURL callers (tests) don't get the legacy-fallback in
        // load() because their isolation requirement excludes $HOME entirely.
        self.resolvedDefaultURLAtInit = (fileURL == nil) ? resolved : nil
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        // One-shot relocation of any pre-2026-05-23 throughline file from
        // ~/MacAgent/ to ~/Library/Application Support/MacAgent/. Only runs
        // when caller used the default URL — explicit fileURL (tests) skips
        // migration to preserve isolation.
        if fileURL == nil {
            Self.migrateLegacyHomeDirThroughline(
                legacy: Self.legacyDefaultURL(),
                target: resolved
            )
        }
        // Tighten perms on the resolved file (whether freshly migrated, newly
        // created on save, or pre-existing at the new path). Idempotent —
        // serves as the fallback chmod if `migrateLegacyHomeDirThroughline`'s
        // own `setAttributes` call silently failed.
        Self.tightenPermissions(fileURL: resolved)
    }

    /// If `legacy` exists and `target` doesn't, move it into place and remove
    /// the now-empty legacy parent directory. All `try?` — on any failure
    /// the legacy file is left untouched and `load()` falls through to read
    /// it. Retried next launch. Single-process invariant means no race.
    ///
    /// **Symlink guard:** if `legacy` is a symbolic link (not a regular
    /// file), the migration is skipped entirely. Otherwise `moveItem` would
    /// rename the symlink itself into the AppSupport target, then `load()`
    /// would follow it and `setAttributes(0o600)` would chmod the symlink's
    /// destination — letting an attacker who can write to `~/MacAgent/`
    /// redirect the agent's read to (and chmod-clobber) an unrelated file.
    /// Sev-1 PR-2 adversarial finding.
    ///
    /// `legacy` and `target` are parameterised so tests can drive the helper
    /// directly against tmp paths instead of `NSHomeDirectory()`.
    internal static func migrateLegacyHomeDirThroughline(
        legacy: URL,
        target: URL
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path),
              !fm.fileExists(atPath: target.path) else { return }
        // Reject symlinks. `attributesOfItem` follows links; `attributesOfItem`-
        // via-NSURL-resourceValues with `.isSymbolicLinkKey` does not.
        if let isSymlink = try? legacy.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink, isSymlink {
            return
        }
        try? fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: target.deletingLastPathComponent().path
        )
        do {
            try fm.moveItem(at: legacy, to: target)
            try? fm.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: target.path
            )
            // Best-effort cleanup of the now-empty legacy parent. If the user
            // had other files in ~/MacAgent/ this will fail silently — that's
            // intentional (don't touch unrelated files).
            try? fm.removeItem(at: legacy.deletingLastPathComponent())
        } catch {
            // Migration failed (perm denied, disk full, etc) — leave legacy
            // in place. load() will pick it up via the legacy fallback below.
        }
    }

    /// Apply 0700 to parent dir + 0600 to file (if it exists). Best-effort —
    /// chmod failures don't block anything. Called from init() to migrate
    /// pre-existing files written by older builds, and from save() to re-apply
    /// after every atomic-rename (which swaps the inode and resets the file
    /// attribute to the umask default).
    private static func tightenPermissions(fileURL: URL) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        }
    }

    /// Load the throughline from disk. Returns an empty throughline if the file doesn't exist.
    ///
    /// Scrubs prompt-injection codepoints from every string field on read (defense-in-depth).
    /// `promptBlock()` already sanitises at render time, but a future code path that reads
    /// throughline data directly (CapabilityRule export, Settings UI, etc.) would otherwise
    /// see raw poisoned content from JSON files written by prior versions. Idempotent —
    /// running sanitise twice produces the same result as running it once.
    public func load() -> AgentThroughline {
        // Primary read: the resolved fileURL. Fallback: if the file isn't at
        // the new AppSupport location AND we resolved the default URL at init
        // (i.e. the caller didn't pass an explicit isolated path), read from
        // legacy. Compare against the init-time snapshot rather than a fresh
        // `defaultURL()` call — fresh resolution can drift if AppSupport
        // availability changes between init and load, causing a false negative
        // here and silent empty-throughline returns. PR-2 adversarial fix.
        let primary = try? Data(contentsOf: fileURL)
        let data: Data?
        if primary != nil {
            data = primary
        } else if let initDefault = resolvedDefaultURLAtInit, fileURL == initDefault {
            data = try? Data(contentsOf: ThroughlineStore.legacyDefaultURL())
        } else {
            data = nil
        }
        guard let data,
              var throughline = try? decoder.decode(AgentThroughline.self, from: data) else {
            return AgentThroughline()
        }
        throughline.hardBoundaries = throughline.hardBoundaries.map { $0.sanitizingForPrompt() }
        throughline.positions = Dictionary(uniqueKeysWithValues:
            throughline.positions.map {
                ($0.key.sanitizingForPrompt(), $0.value.sanitizingForPrompt())
            }
        )
        throughline.taskHistory = throughline.taskHistory.map { r in
            TaskRecord(
                task: r.task.sanitizingForPrompt(),
                outcome: r.outcome,
                stepCount: r.stepCount,
                appBundleID: r.appBundleID.sanitizingForPrompt(),
                timestamp: r.timestamp
            )
        }
        return throughline
    }

    /// Append a task record and save atomically.
    /// Also extracts outcome-derived positions so the LLM gains environmental context.
    /// Note: disk I/O runs synchronously on the actor's executor. The throughline file
    /// is small (~20 records) so latency is negligible; revisit if file size grows.
    public func record(_ task: TaskRecord) {
        var throughline = load()
        throughline.record(task)
        if task.outcome == "success" {
            throughline.establish(key: "last_successful_app", value: task.appBundleID)
            if task.stepCount == 1 {
                // Cap matches addBoundary()'s 500-char limit — prevents context-window bloat
                // from a long task string being injected into every subsequent LLM prompt.
                throughline.establish(key: "last_trivial_task", value: String(task.task.prefix(500)))
            }
        }
        save(throughline)
    }

    /// Add a hard boundary. Returns false (no write) if the rule is already present.
    /// Actor isolation ensures this load→mutate→save is atomic relative to other actor calls.
    @discardableResult
    public func addBoundary(_ rule: String) -> Bool {
        var t = load()
        guard t.addBoundary(rule) else { return false }
        save(t)
        return true
    }

    /// Remove a hard boundary by exact string match.
    public func removeBoundary(_ rule: String) {
        var t = load(); t.removeBoundary(rule); save(t)
    }

    /// Remove a learned position by key.
    public func removePosition(key: String) {
        var t = load(); t.removePosition(key: key); save(t)
    }

    /// Clear all task history records. Hard boundaries and positions are preserved.
    public func clearHistory() {
        var t = load(); t.clearHistory(); save(t)
    }

    /// Save the full throughline atomically.
    ///
    /// File mode 0600 + parent dir 0700 re-applied after every atomic-rename.
    /// Throughline holds operator hard rules + learned positions + last 20 task
    /// records — parallel privacy surface to ReceiptWriter's cleartext receipts.
    /// Pre-2026-05-23 builds left this at default umask (0644 world-readable);
    /// init() migrates existing files, save() maintains perms across atomic-
    /// rename inode swaps.
    public func save(_ throughline: AgentThroughline) {
        guard let data = try? encoder.encode(throughline) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }
}

// MARK: - Prompt sanitization helper (mirrors ClaudeLLMClient.sanitizeForPrompt — keep in sync)

private extension String {
    /// Strips line-break codepoints, zero-width space, and Unicode tag characters
    /// from strings before they are rendered into the LLM prompt block.
    /// Mirrors the codepoint set in ClaudeLLMClient.sanitizeForPrompt().
    func sanitizingForPrompt() -> String {
        let lineBreakStripped = self
            .replacingOccurrences(of: "\r\n",     with: " ")
            .replacingOccurrences(of: "\n",       with: " ")
            .replacingOccurrences(of: "\r",       with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")  // LINE SEPARATOR
            .replacingOccurrences(of: "\u{2029}", with: " ")  // PARAGRAPH SEPARATOR
            .replacingOccurrences(of: "\u{000B}", with: " ")  // VERTICAL TAB
            .replacingOccurrences(of: "\u{000C}", with: " ")  // FORM FEED
            .replacingOccurrences(of: "\u{0085}", with: " ")  // NEXT LINE (NEL)
            .replacingOccurrences(of: "\u{200B}", with: "")   // ZERO-WIDTH SPACE (invisible)
        // Strip Unicode tag characters (U+E0000–U+E007F) — non-BMP, requires scalar filter.
        let tagRange: ClosedRange<UInt32> = 0xE0000...0xE007F
        let scalars = lineBreakStripped.unicodeScalars.filter { !tagRange.contains($0.value) }
        return String(String.UnicodeScalarView(scalars))
    }
}
