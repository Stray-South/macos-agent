/// TaskGuard.swift
///
/// Task-level safety gate applied once per run, before any LLM call or action.
/// Blocks task strings that match known-harmful automation patterns regardless
/// of what the LLM or executor would do with them.
import Foundation

/// Injectable pre-run gate. Return nil to allow; return a reason string to block.
public protocol TaskGuarding: Sendable {
    func shouldBlock(task: String) async -> String?
    /// Unit 23 — RISKY tier-floor. After `shouldBlock` returns nil
    /// (task allowed), the orchestrator calls this to learn whether
    /// the task warrants a minimum tier for the FIRST action of the
    /// run. Use case: the LLM classifier judges a task borderline
    /// (e.g. "empty the trash" — single irreversible step but
    /// operator-recoverable) — return `.preview` so the operator
    /// sees and confirms the first action before the agent commits.
    ///
    /// Default extension returns nil — guards without semantic
    /// understanding (PermissiveTaskGuard, KeywordTaskGuard) don't
    /// implement this; only `LLMTaskClassifier` overrides it.
    /// First-step-only: tier-floor escalation is consumed after step 1
    /// (per Orchestrator wiring).
    func tierFloor(task: String) async -> SafetyTier?
}

public extension TaskGuarding {
    func tierFloor(task: String) async -> SafetyTier? { nil }
}

/// Default — passes every task through. Used in production and in tests that
/// don't need task-level blocking.
public struct PermissiveTaskGuard: TaskGuarding {
    public init() {}
    public func shouldBlock(task: String) async -> String? { nil }
}

/// Blocks tasks whose text contains a known-harmful browser-automation phrase.
/// Phrase list is intentionally narrow — false positives are worse than misses here.
public struct KeywordTaskGuard: TaskGuarding {
    // internal for testability
    internal static let blockedPhrases: [String] = [
        "scrape credentials",
        "harvest passwords",
        "steal cookies",
        "exfiltrate",
        "phishing page",
        "create phishing",
        "send phishing",
        "bulk navigate",
        "automate clicks to deceive",
        "click farm",
        "ad fraud",
        "scrape personal data without consent",
        "bypass captcha for",
        "automated credential stuffing",
        "mass account creation",
    ]

    public init() {}

    public func shouldBlock(task: String) async -> String? {
        let lower = task.lowercased()
        for phrase in Self.blockedPhrases where lower.contains(phrase) {
            return "Task contains prohibited automation pattern: \"\(phrase)\""
        }
        return nil
    }
}
