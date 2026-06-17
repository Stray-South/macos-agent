import Foundation

/// Unit 29c — crash-safe audit journal for a parked approval gate.
///
/// Post-Unit-29 an unanswered gate parks (no auto-reject), so an app quit,
/// crash, or force-quit during the park would otherwise leave ZERO receipt
/// trace that a gated action was ever proposed. The orchestrator records the
/// parked action here when the first heartbeat fires (a gate answered within
/// one timeout interval never touches disk) and clears it when the gate
/// resolves. At next launch, AppModel consumes any leftover entry and writes
/// a rejection-shaped reconciliation receipt: the action was proposed, never
/// decided, never executed.
///
/// One file, one entry — gates are sequential per run and runs are exclusive,
/// so there is never more than one parked gate.
public actor PendingGateJournal {
    public struct Entry: Codable, Sendable {
        public let action: AgentAction
        public let tier: String
        public let snapshotHash: String
        public let parkedAt: Date

        public init(action: AgentAction, tier: String, snapshotHash: String, parkedAt: Date = Date()) {
            self.action = action
            self.tier = tier
            self.snapshotHash = snapshotHash
            self.parkedAt = parkedAt
        }
    }

    private let fileURL: URL

    public static func defaultFileURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReceiptWriterError.noApplicationSupportDirectory
        }
        return appSupport.appendingPathComponent("MacAgent/pending-gate.json", isDirectory: false)
    }

    /// Production factory — explicit prod-path intent at the call site,
    /// mirroring ReceiptWriter.production(). Tests pass their own fileURL.
    public static func production() -> PendingGateJournal {
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("MacAgent/pending-gate.json", isDirectory: false)
        return PendingGateJournal(fileURL: (try? Self.defaultFileURL()) ?? fallback)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(_ entry: Entry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public enum ConsumeOutcome: Sendable {
        /// No gate was parked at last shutdown (the overwhelmingly common case).
        case none
        /// A parked gate was found — write the reconciliation receipt.
        case entry(Entry)
        /// A journal file existed but could not be decoded (corruption,
        /// truncated write, tampering). The evidence that SOMETHING was
        /// parked must not vanish silently — surface it to the operator.
        case unreadable
    }

    /// Read-then-delete for launch reconciliation. Decode happens BEFORE
    /// the delete so a corrupt file is reported, not silently destroyed.
    /// Reads are capped at 64 KB — a legitimate entry is well under 4 KB,
    /// and bootstrap must not slurp an arbitrarily large file into memory.
    public func consume() -> ConsumeOutcome {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size <= 65_536, let data = try? Data(contentsOf: fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            return .unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(Entry.self, from: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return .unreadable
        }
        try? FileManager.default.removeItem(at: fileURL)
        return .entry(entry)
    }

    /// The rejection-shaped receipt that closes the audit trail for a gate
    /// left unresolved at shutdown. approved=false is honest: no decision
    /// is on record. The wording allows for the rare clear-after-receipt
    /// crash window where the decision WAS receipted moments earlier — an
    /// auditor seeing both entries reads this one as the journal artifact.
    /// The tier string round-trips from disk, so it is validated against
    /// SafetyTier (tampered/corrupt values collapse to "confirm", the
    /// safe-direction reading for an unresolved gate).
    public static func reconciliationReceipt(from entry: Entry) -> ActionLogEntry {
        let validatedTier = SafetyTier(rawValue: entry.tier)?.rawValue ?? SafetyTier.confirm.rawValue
        return ActionLogEntry(
            action: entry.action,
            tier: validatedTier,
            approved: false,
            executionResult: "unresolved at shutdown — no decision on record for this gated action (parked since \(ISO8601DateFormatter().string(from: entry.parkedAt))); reconciled at launch. If a same-action receipt exists moments before this one, the decision landed but the app terminated before the journal cleared.",
            durationMs: 0,
            snapshotHash: entry.snapshotHash
        )
    }
}
