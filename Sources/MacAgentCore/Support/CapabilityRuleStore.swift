import Foundation
import os.log

private let rulesLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "CapabilityRuleStore"
)

/// Actor-serialized store for user-defined capability rules.
/// Persists to JSON at ~/Library/Application Support/MacAgent/capability-rules.json.
/// All reads/writes are actor-isolated — race-free across concurrent orchestrator steps.
public actor CapabilityRuleStore {

    // MARK: - Storage

    private let fileURL: URL
    private var rules: [CapabilityRule] = []
    private var loaded = false
    /// Most recent persistence failure, or nil. Updated atomically inside the
    /// actor's `persist()` catch branch. Read via `lastPersistError()` so the
    /// Settings UI can show a banner when capability rules fail to land on disk
    /// (disk-full, sandbox denial, etc.) — pre-fix the catch was silent and
    /// disk-full silently dropped every Always/Never approval rule.
    private var lastPersistFailure: Error?

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = support
                .appendingPathComponent("MacAgent", isDirectory: true)
                .appendingPathComponent("capability-rules.json")
        }
        // One-shot migration of any pre-2026-05-23 capability-rules file:
        // tighten perms to 0600 / parent dir 0700. Mirrors ReceiptWriter +
        // ThroughlineStore patterns. Capability rules encode operator-approved
        // app/action policies — parallel privacy surface to receipts.
        Self.tightenPermissions(fileURL: self.fileURL)
    }

    /// Apply 0700 to parent dir + 0600 to file (if it exists). Best-effort.
    /// Called from init() for pre-existing files and from persist() to re-apply
    /// after the atomic tmp+replaceItemAt cycle (which swaps the inode and
    /// resets the file attribute to the umask default).
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

    // MARK: - Public API

    /// Load rules from disk (idempotent — subsequent calls return cached copy).
    @discardableResult
    public func load() async -> [CapabilityRule] {
        if loaded { return rules }
        loaded = true
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            rules = try decoder.decode([CapabilityRule].self, from: data)
        } catch {
            // File missing on first launch, or corrupted — start with empty rules.
            rules = []
        }
        return rules
    }

    /// Add a rule and persist immediately.
    public func add(_ rule: CapabilityRule) async {
        await load()
        // Deduplicate: if an identical rule already exists, no-op.
        let isDuplicate = rules.contains {
            $0.verdict == rule.verdict &&
            $0.actionType == rule.actionType &&
            $0.appBundleID == rule.appBundleID &&
            $0.labelPattern == rule.labelPattern
        }
        guard !isDuplicate else { return }
        rules.append(rule)
        await persist()
    }

    /// Remove a rule by ID and persist.
    public func remove(id: UUID) async {
        rules.removeAll { $0.id == id }
        await persist()
    }

    /// Remove all rules and persist.
    public func reset() async {
        rules = []
        await persist()
    }

    /// Returns a snapshot of the current rule list (for UI display).
    public func allRules() async -> [CapabilityRule] {
        await load()
        return rules
    }

    // MARK: - Rule Evaluation

    /// Evaluate all rules against an action+snapshot. Precedence: deny > ask > allow.
    /// Returns nil when no rule matches — caller falls back to SafetyPolicy/AutonomyMode.
    public func evaluate(
        _ action: AgentAction,
        _ snapshot: PerceptionSnapshot
    ) async -> CapabilityRule.Verdict? {
        await load()
        var best: CapabilityRule.Verdict? = nil
        var matched: [UUID] = []

        for rule in rules where rule.matches(action, snapshot) {
            matched.append(rule.id)
            switch (best, rule.verdict) {
            case (nil, _):
                best = rule.verdict
            case (.allow, .ask), (.allow, .deny), (.ask, .deny):
                best = rule.verdict     // deny > ask > allow
            default:
                break
            }
        }

        // Update trigger metadata for matched rules. The previous implementation
        // called `persist()` here on EVERY evaluation that matched any rule — for
        // an autonomous run with N steps and a single matching rule that's
        // N disk writes per session for purely informational metadata (last-
        // triggered date + trigger count surfaced in Settings UI). Skipping the
        // persist makes trigger metadata in-memory only between structural
        // changes (`add` / `remove` / `reset` each still persist the whole
        // store, picking up the accumulated counts). Trade-off: if the process
        // is killed mid-run the trigger increments from that run are lost —
        // acceptable, the counts are not safety-critical and the last-good
        // snapshot from a prior add/remove is still on disk.
        if !matched.isEmpty {
            let now = Date()
            for i in rules.indices where matched.contains(rules[i].id) {
                rules[i].lastTriggered = now
                rules[i].triggerCount += 1
            }
        }

        return best
    }

    /// Returns the most recent persistence failure, or nil if the latest
    /// `persist()` call succeeded. Settings UI can read this on its refresh
    /// hook and surface a banner when rules aren't landing on disk — the
    /// session-only fallback still works but the rules vanish on next launch.
    /// `async` (rather than synchronous-on-actor) for API clarity at call
    /// sites — external callers must `await` either way.
    public func lastPersistError() async -> Error? {
        lastPersistFailure
    }

    // MARK: - Persistence

    private func persist() async {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)
            // Atomic write via tmp file + replace to prevent partial writes on crash.
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            // File mode 0600 re-applied after every replaceItemAt — the rename
            // swaps the inode and resets the file attribute to the umask default.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            lastPersistFailure = nil
        } catch {
            // Non-fatal — rules are still in memory for this session.
            // Surface the failure so a future investigator can correlate
            // "Always/Never approvals vanished" with disk-full or sandbox
            // denial. Clean up any leftover .tmp file from the failed write.
            // Mark .private — filesystem error descriptions from Foundation
            // often embed the file path. The path is inside the app's
            // Application Support container (low PII risk) but log-read
            // entitlement holders should still see only the domain/code.
            rulesLog.error("CapabilityRuleStore.persist failed: \(error.localizedDescription, privacy: .private)")
            lastPersistFailure = error
            let tmp = fileURL.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
