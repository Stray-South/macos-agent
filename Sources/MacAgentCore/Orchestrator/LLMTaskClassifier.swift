/// LLMTaskClassifier.swift
///
/// Unit 15 / Path D Candidate 2 — F.6 v1 stretch goal closure.
///
/// `KeywordTaskGuard` (existing) catches a narrow set of explicit harmful
/// phrases ("scrape credentials", "create phishing"). It misses tasks
/// phrased outside the keyword list: "clean up old downloads to free disk
/// space", "reset my git repo to clean state", "wipe my desktop". MANIFEST
/// §Known Gaps explicitly names the "LLM-based threat-assessment
/// classifier" as the v1 stretch goal.
///
/// `LLMTaskClassifier` wraps a base `TaskGuarding` (default
/// `KeywordTaskGuard`) and adds a single Haiku call BEFORE `Orchestrator
/// .run()` emits `.started`. The wrapper short-circuits on the base
/// guard's reason (no LLM call for tasks the keyword list already
/// catches — zero added latency on the common path). Only tasks the
/// base passes get the LLM check.
///
/// Verdicts are SAFE / HARMFUL only. The three-state SAFE/RISKY/HARMFUL
/// design surfaced in the Path D research doc would require
/// `TaskGuarding.shouldBlock(task:) -> String?` to grow a tier-floor
/// channel — that's its own candidate. Scoped here to the two
/// outcomes the existing protocol supports.
///
/// Graceful degradation: any network failure, parse failure, or
/// non-2xx response returns `nil` (allow). The base guard already
/// passed; failing closed (block on LLM error) would be a denial-of-
/// service vector against the operator's own runs. The classifier
/// is additive defense — its absence falls back to the base guard's
/// existing protection.
///
/// In-session verdict cache (actor-isolated, capped at 32 entries) so
/// operator retrying the same task wording doesn't double-charge or
/// double-latency. Memory-only; no fourth state file (per
/// AGENTS.md §Agent State Files — a persistent cache would need the
/// chmod path enforcement and is deferred).
import Foundation
import os.log
import CryptoKit

private let classifierLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "LLMTaskClassifier"
)

/// In-session SHA256-keyed verdict cache. Actor-isolated so concurrent
/// calls from parallel Orchestrators in tests don't race. Cap = 32 so
/// memory stays bounded; eviction is FIFO via insertion-order array.
///
/// Unit 23 — cache entry holds BOTH the block reason AND the tier
/// floor so a single Haiku call serves both `shouldBlock` and
/// `tierFloor` for the same task. Semantics:
///   - HARMFUL: `(reason: String, floor: nil)` — task blocked
///   - RISKY:   `(reason: nil, floor: .preview)` — task allowed but
///              first-step tier raised to .preview
///   - SAFE:    `(reason: nil, floor: nil)` — task fully allowed
internal actor TaskClassifierCache {
    public struct Entry: Sendable, Equatable {
        public let reason: String?
        public let floor: SafetyTier?
        public init(reason: String?, floor: SafetyTier?) {
            self.reason = reason
            self.floor = floor
        }
        /// Convenience: a clean SAFE entry.
        public static let safe = Entry(reason: nil, floor: nil)
    }
    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries = 32

    func get(_ key: String) -> Entry? {
        entries[key]
    }

    func put(_ key: String, _ value: Entry) {
        if entries[key] != nil { return }
        if insertionOrder.count >= maxEntries, let oldest = insertionOrder.first {
            entries.removeValue(forKey: oldest)
            insertionOrder.removeFirst()
        }
        entries[key] = value
        insertionOrder.append(key)
    }

    /// Test-only. Production has no reason to clear the cache; a fresh
    /// classifier instance starts with an empty one.
    func reset() {
        entries.removeAll()
        insertionOrder.removeAll()
    }
}

public struct LLMTaskClassifier: TaskGuarding {
    private let apiKey: String
    private let baseGuard: any TaskGuarding
    let model: String
    private let endpoint: URL
    private let session: URLSession
    private let cache: TaskClassifierCache

    public init(
        apiKey: String,
        baseGuard: any TaskGuarding = KeywordTaskGuard(),
        // Maintenance note: this Haiku ID was REMOVED from `AgentModel.all`
        // in the 2026-05-23 audit (regressed to degenerate
        // click/wait/cmd+tab loops on the multi-tool action schema). The
        // retirement reasoning was specific to action-mode multi-tool —
        // it does NOT apply to the text-only SAFE/HARMFUL classification
        // path here, so the ID is intentionally retained as the
        // classifier default. Haiku 4.5 itself retires ≥2026-10-15 per
        // Anthropic's deprecation page; re-verify before that date and
        // swap to a successor Haiku.
        model: String = "claude-haiku-4-5-20251001",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseGuard = baseGuard
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.cache = TaskClassifierCache()
    }

    /// Internal init for tests that need a shared cache across calls.
    /// Production callers use the standard init and get a fresh cache.
    internal init(
        apiKey: String,
        baseGuard: any TaskGuarding,
        model: String,
        endpoint: URL,
        session: URLSession,
        cache: TaskClassifierCache
    ) {
        self.apiKey = apiKey
        self.baseGuard = baseGuard
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.cache = cache
    }

    public func shouldBlock(task: String) async -> String? {
        // Base guard runs first — fast keyword pass on the hot path.
        // Tasks the keyword list catches never incur LLM latency.
        if let baseReason = await baseGuard.shouldBlock(task: task) {
            return baseReason
        }

        // Cache check by sha256(task) — operator typing the same task
        // twice doesn't double-charge or double-latency. The cache
        // entry's `reason` field is what `shouldBlock` returns; the
        // `floor` field is consumed by `tierFloor` below for the same
        // task wording, so a single Haiku call serves both methods.
        let key = Self.sha256(task)
        if let cached = await cache.get(key) {
            return cached.reason
        }

        // Sanitise the task before it enters the prompt-bound copy.
        // Same defense as `ClaudeTaskPlanner` — prompt injection via
        // Unicode line separators must not forge classifier section
        // headers.
        let safeTask = ClaudeLLMClient.sanitizeForPrompt(task)

        let prompt = """
        You are a safety classifier for a macOS desktop automation agent.

        The user wants the agent to perform this task: "\(safeTask)"

        Rate the task as exactly one of:
        SAFE — the task is benign automation work (read, navigate, click, type,
                organize, summarize, draft, search). Even if the task is silly
                or unproductive, if it doesn't risk irreversible harm,
                exfiltrate data, attack other users, or cause widespread system
                damage, classify it SAFE.
        RISKY — the task is allowed but contains a single irreversible step
                the operator should see and confirm before the agent commits.
                Examples: "empty the trash" (one-shot purge, but operator can
                choose to confirm), "delete this folder" (single destructive
                step, operator-recoverable via Time Machine / backup if they
                have one), "send this email" (one-shot external commit). The
                agent should be allowed to plan and act, but the FIRST step
                must surface to the operator before committing.
        HARMFUL — the task carries a real risk of one or more of:
                    • mass irreversible data loss (wipe/format/purge ALL
                      files, ALL apps, ALL history) — operator cannot recover
                    • credential exfiltration or unauthorised access to other
                      users' data
                    • impersonation, fraud, deception of third parties
                    • mass automation against external services (scraping,
                      spam, click farms)
                    • system-wide damage (shutdown, reboot, disable security
                      features, modify launchd, escalate privileges)

        Boundary rule: a single irreversible step the operator can choose to
        confirm is RISKY, not HARMFUL. Mass / silent / unrecoverable damage
        is HARMFUL.

        Reply with ONLY the verdict word followed by a brief reasoning, all
        on one line, like:
        SAFE: the task asks to summarize a document
        RISKY: the task asks to empty the trash, one irreversible step
        HARMFUL: the task asks to wipe all photos with no recovery path

        Do NOT include any preamble, code block, or additional formatting.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 100,
            "temperature": 0.0,  // deterministic verdict
            "messages": [["role": "user", "content": prompt]],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            classifierLog.error("Classifier failed: JSON serialisation error")
            return nil  // graceful degrade — base guard already passed
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = 10  // tight — this gates `.started`

        // Reviewer-caught Sev-2: do NOT cache on error paths.
        //
        // Caching `nil` on transient failures (network, 429 rate limit,
        // 500 server error, parse failure, unparseable verdict) would
        // permanently bypass the classifier for that task wording for
        // the rest of the session — exactly the silently-degraded
        // failure mode the toggle copy doesn't warn about. The base
        // guard still runs first (its protection persists), but the
        // operator's expectation when they enable the LLM toggle is
        // that the LLM actually checks. A retry on the next call with
        // the same task is acceptable; a permanent bypass is not.
        //
        // Cache writes happen only on the successful-parse path
        // (`await cache.put(...)` at the verdict switch below).
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            classifierLog.info("Classifier network failure — degrading to base-guard verdict (SAFE)")
            return nil
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyPrefix = String(decoding: data.prefix(200), as: UTF8.self)
            classifierLog.error("Classifier non-2xx: status=\(http.statusCode, privacy: .public) body=\(bodyPrefix, privacy: .private)")
            return nil
        }

        struct Response: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            classifierLog.error("Classifier parse failure — degrading to base-guard verdict (SAFE)")
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = Self.parseVerdict(trimmed)
        let entry: TaskClassifierCache.Entry
        switch verdict {
        case .safe:
            // Reviewer-caught Sev-2: reasoning + task-echo strings stay
            // `.private` so they don't land in Console.app where a
            // shoulder-surfer or shared-login-session user could read
            // the operator's task content. The verdict word itself is
            // `.public` for grep-ability in audit traces.
            classifierLog.info("Classifier verdict=SAFE body=\(trimmed.prefix(200), privacy: .private)")
            entry = .safe
        case .risky(let reasoning):
            // RISKY: don't block, but cache a `.preview` floor so the
            // Orchestrator escalates the first action's tier.
            classifierLog.notice("Classifier verdict=RISKY reasoning=\(reasoning, privacy: .private)")
            entry = TaskClassifierCache.Entry(reason: nil, floor: .preview)
        case .harmful(let reasoning):
            classifierLog.notice("Classifier verdict=HARMFUL reasoning=\(reasoning, privacy: .private)")
            entry = TaskClassifierCache.Entry(
                reason: "LLM classifier blocked the task: \(reasoning)",
                floor: nil
            )
        case .unparseable:
            // Unparseable: don't cache (reviewer Sev-2 #1) and don't
            // block (graceful degrade — base guard already passed).
            classifierLog.error("Classifier unparseable verdict body=\(trimmed, privacy: .private) — degrading to SAFE")
            return nil
        }
        // Only successful-parse SAFE / RISKY / HARMFUL verdicts are cached.
        await cache.put(key, entry)
        return entry.reason
    }

    /// Unit 23 — RISKY tier-floor.
    ///
    /// `shouldBlock` has already run by the time the Orchestrator calls
    /// this (per the `TaskGuarding` contract wired in `Orchestrator.run`),
    /// so the cache is already populated for this task wording. Reading
    /// from cache means no second Haiku call — one call serves both
    /// methods.
    ///
    /// If the cache is somehow empty (e.g. the base guard blocked, or
    /// `shouldBlock` hit an error path and didn't populate), returns nil
    /// — no escalation. Conservative: a missing classifier verdict
    /// should never force operator confirmation on otherwise-auto tasks.
    public func tierFloor(task: String) async -> SafetyTier? {
        let key = Self.sha256(task)
        if let cached = await cache.get(key) {
            return cached.floor
        }
        return nil
    }

    // MARK: - Verdict parsing

    enum Verdict {
        case safe
        case risky(reasoning: String)
        case harmful(reasoning: String)
        case unparseable
    }

    static func parseVerdict(_ text: String) -> Verdict {
        // Reviewer-caught Sev-2: `hasPrefix("SAFE")` was too lenient —
        // "SAFE, but actually this deletes everything" matched as
        // `.safe` and the trailing caveat was silently dropped.
        // Require the verdict token to end at a clean boundary
        // (end-of-string, `:`, whitespace, or `.`). Anything beyond
        // (comma, semicolon, more letters, etc.) is unparseable so the
        // graceful-degrade path runs the base-guard verdict alone
        // rather than misclassifying ambiguous wording.
        //
        // Unit 23: HARMFUL must be checked BEFORE RISKY because the
        // string "HARMFUL" starts with no shared prefix, but if we ever
        // add tokens that share prefixes the order would matter.
        // Current order: SAFE, RISKY, HARMFUL.
        let upper = text.uppercased()
        func cleanBoundary(after prefix: String) -> Bool {
            guard upper.hasPrefix(prefix) else { return false }
            let next = upper.dropFirst(prefix.count).first
            // EOL OR allowed punctuation/whitespace immediately after.
            guard let ch = next else { return true }
            return ch == ":" || ch == "." || ch.isWhitespace
        }
        func extractReasoning() -> String {
            let stripped = text.drop(while: { $0.isLetter })
                               .drop(while: { $0 == ":" || $0 == "." || $0.isWhitespace })
            return String(stripped).isEmpty
                ? "(no reasoning provided)"
                : String(stripped)
        }
        if cleanBoundary(after: "SAFE") {
            return .safe
        }
        if cleanBoundary(after: "RISKY") {
            return .risky(reasoning: extractReasoning())
        }
        if cleanBoundary(after: "HARMFUL") {
            return .harmful(reasoning: extractReasoning())
        }
        return .unparseable
    }

    // MARK: - Hashing

    static func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
