import Foundation

public enum ReceiptWriterError: Error, LocalizedError, Sendable {
    case noApplicationSupportDirectory

    public var errorDescription: String? {
        "Could not locate the Application Support directory. Receipts cannot be written."
    }
}

public actor ReceiptWriter {
    private let baseURL: URL
    private let encoder: JSONEncoder
    private let dateFormatter: DateFormatter

    public static func defaultBaseURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ReceiptWriterError.noApplicationSupportDirectory
        }
        return appSupport.appendingPathComponent("MacAgent/receipts", isDirectory: true)
    }

    /// Production factory — Unit 11 (defense-in-depth atop Unit 1's
    /// Orchestrator chokepoint). The default `baseURL: URL? = nil` init
    /// silently fell back to `~/Library/Application Support/MacAgent/receipts`;
    /// after Unit 1 only AppModel reaches that path, but a future test that
    /// constructs `ReceiptWriter()` directly + passes to the orchestrator's
    /// now-mandatory `receiptWriter:` arg would still pollute. The
    /// factory makes the prod-path intent explicit at the call site;
    /// the `baseURL: URL? = nil` default stays for back-compat but the
    /// canonical production constructor goes through here.
    public static func production() -> ReceiptWriter {
        let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("MacAgent/receipts", isDirectory: true)
        return ReceiptWriter(baseURL: (try? Self.defaultBaseURL()) ?? fallback)
    }

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            // Fall back to ~/MacAgent/receipts if Application Support is unavailable (extremely rare).
            let fallback = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("MacAgent/receipts", isDirectory: true)
            self.baseURL = (try? Self.defaultBaseURL()) ?? fallback
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
    }

    /// Persist one receipt entry as a JSONL line.
    ///
    /// **Append-only invariant scope:** "append-only" here means the agent never deletes
    /// or rewrites entries it has previously emitted — not that this implementation uses
    /// `O_APPEND` at the OS level. Each call performs a read-modify-rewrite: read the
    /// existing file, concatenate the new line, atomic temp-file rename. This means
    ///   - a third-party edit between two agent writes is silently re-included on the next write,
    ///   - long sessions pay O(file size) per write.
    /// The actor serialises calls, so two writes from this process cannot race. If true
    /// O_APPEND semantics are needed (e.g. for tamper detection or external concurrent
    /// writers), switch to FileHandle in append mode and drop the read-modify pattern.
    public func write(_ entry: ActionLogEntry) async throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        // Tighten the receipts directory to 0700 every write — the atomic-write
        // pattern below creates a fresh inode each call so attribute changes on
        // any single jsonl file don't propagate, but the parent dir is stable
        // across calls. Best-effort: chmod failure does not block the receipt.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: baseURL.path
        )
        let filename = dateFormatter.string(from: entry.timestamp) + ".jsonl"
        let fileURL = baseURL.appendingPathComponent(filename)
        let newLine = try encoder.encode(entry) + Data([0x0a])
        let existing = (try? Data(contentsOf: fileURL)) ?? Data()
        try (existing + newLine).write(to: fileURL, options: .atomic)
        // Receipts contain cleartext typeText payloads (passwords, 2FA codes
        // approved by the operator — MANIFEST §Receipt Model). Atomic write
        // replaces the inode each call so we must re-chmod on every write,
        // not just at file creation. Best-effort: chmod failure does not
        // block the entry from being persisted.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
