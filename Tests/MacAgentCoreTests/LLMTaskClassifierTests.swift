/// LLMTaskClassifierTests.swift
///
/// Unit 15 / Path D Candidate 2 — F.6 v1 stretch goal.
///
/// Coverage:
///   - base guard short-circuits (LLM never called for keyword hits)
///   - SAFE verdict → nil (allow)
///   - HARMFUL verdict → reason string with reasoning
///   - Network failure → nil (graceful degrade; base already passed)
///   - Cache hit → second call doesn't re-hit the mock
///   - Verdict parser handles SAFE / HARMFUL / unparseable cases
///   - sha256 helper is deterministic
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - URLSession mock infrastructure
//
// MacAgentCore depends on URLSession.shared in production; tests inject a
// configured session whose protocol returns canned responses. Same pattern
// used elsewhere isn't established yet — set one up locally so the
// classifier's HTTP path is testable without network.

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // Static-shared handler so tests register responses by URL.
    // The static state RACES under Swift Testing's default parallel
    // executor — same lesson as 13b's `MouseHoldState.shared`. Tests
    // that touch this mock MUST live in a `@Suite(.serialized)` block
    // so registrations and callCount reads are sequential. See
    // `LLMClassifierSuite` below.
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var callCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MockURLProtocol.callCount += 1
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (resp, data) = responder(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeJSONResponse(text: String, status: Int = 200) -> (HTTPURLResponse, Data) {
    let url = URL(string: "https://api.anthropic.com/v1/messages")!
    let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    let body: [String: Any] = [
        "content": [["type": "text", "text": text]],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    return (resp, data)
}

private struct FixedBaseGuard: TaskGuarding {
    let reason: String?
    func shouldBlock(task: String) async -> String? { reason }
}

// MARK: - Verdict parser
//
// Serialized suite — `MockURLProtocol` uses static-shared `responder` +
// `callCount` state that races under Swift Testing's default parallel
// executor (same lesson as Unit 13b's `MouseHoldState.shared`).

@Suite(.serialized)
struct LLMClassifierSuite {

@Test
func classifierParser_handlesSafeVerdict() {
    if case .safe = LLMTaskClassifier.parseVerdict("SAFE: benign task") {
        // ok
    } else {
        Issue.record("expected .safe")
    }
    if case .safe = LLMTaskClassifier.parseVerdict("SAFE") {
        // ok — bare verdict without reasoning
    } else {
        Issue.record("expected .safe for bare SAFE verdict")
    }
}

@Test
func classifierParser_handlesHarmfulVerdict_carriesReasoning() {
    let v = LLMTaskClassifier.parseVerdict("HARMFUL: deletes all photos permanently")
    if case .harmful(let reasoning) = v {
        #expect(reasoning == "deletes all photos permanently",
                "parser must strip 'HARMFUL: ' prefix and return the reasoning portion")
    } else {
        Issue.record("expected .harmful")
    }
}

@Test
func classifierParser_unparseableReturnsUnparseable() {
    if case .unparseable = LLMTaskClassifier.parseVerdict("ok") { /* ok */ }
    else { Issue.record("expected .unparseable for non-verdict text") }
    if case .unparseable = LLMTaskClassifier.parseVerdict("") { /* ok */ }
    else { Issue.record("expected .unparseable for empty string") }
}

@Test
func classifierSha256_isDeterministic() {
    let a = LLMTaskClassifier.sha256("delete my files")
    let b = LLMTaskClassifier.sha256("delete my files")
    let c = LLMTaskClassifier.sha256("delete my files ")  // trailing space → different
    #expect(a == b)
    #expect(a != c)
    #expect(a.count == 64, "hex SHA256 must be 64 characters")
}

// MARK: - End-to-end classifier behavior

@Test
func classifier_baseGuardBlocks_neverCallsLLM() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "SAFE: should not be reached") }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: "keyword hit: do not delete"),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: TaskClassifierCache()
    )
    let reason = await classifier.shouldBlock(task: "delete everything")
    #expect(reason == "keyword hit: do not delete",
            "base-guard reason must short-circuit — no LLM call required for keyword hits")
    #expect(MockURLProtocol.callCount == 0,
            "LLM must NOT be called when base guard blocks (hot-path latency invariant)")
}

@Test
func classifier_safeVerdict_passesThrough() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "SAFE: benign click sequence") }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: TaskClassifierCache()
    )
    let reason = await classifier.shouldBlock(task: "open Safari and navigate to news.ycombinator.com")
    #expect(reason == nil, "SAFE verdict must return nil (allow)")
    #expect(MockURLProtocol.callCount == 1, "LLM must be called when base guard passes")
}

@Test
func classifier_harmfulVerdict_blocksWithReasoning() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "HARMFUL: would delete personal data without recovery") }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: TaskClassifierCache()
    )
    let reason = await classifier.shouldBlock(task: "purge all my downloads forever no undo")
    let unwrapped = try? #require(reason)
    #expect(unwrapped?.contains("LLM classifier blocked") == true,
            "HARMFUL must return a block reason prefixed by the classifier source")
    #expect(unwrapped?.contains("delete personal data without recovery") == true,
            "block reason must carry the LLM's reasoning so the operator sees why")
}

@Test
func classifier_non2xx_degradesGracefully() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("server error".utf8))
    }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: TaskClassifierCache()
    )
    let reason = await classifier.shouldBlock(task: "any task")
    #expect(reason == nil,
            "API failure must NOT block the run — the base guard already passed, failing closed would be a denial-of-service against the operator")
}

@Test
func classifier_cacheHit_skipsSecondLLMCall() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "SAFE: cached test") }
    let cache = TaskClassifierCache()
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: cache
    )
    _ = await classifier.shouldBlock(task: "open Safari")
    _ = await classifier.shouldBlock(task: "open Safari")
    #expect(MockURLProtocol.callCount == 1,
            "second call with same task must hit the cache — operator retrying the same wording should not double-bill or double-latency")
}

@Test
func classifier_cacheEviction_capsAtMaxEntries() async {
    // Bound check on the FIFO eviction. Doesn't exercise the LLM at all;
    // pure cache-behavior test using the actor directly.
    let cache = TaskClassifierCache()
    // 33 inserts → first one evicted
    for i in 0..<33 {
        await cache.put("key\(i)", TaskClassifierCache.Entry(reason: "verdict\(i)", floor: nil))
    }
    let evicted = await cache.get("key0")
    let kept = await cache.get("key32")
    #expect(evicted == nil, "oldest entry must be evicted past the 32-entry cap")
    if let v = kept {
        #expect(v.reason == "verdict32")
    } else {
        Issue.record("most-recent entry must still be cached")
    }
}

// New test prompted by reviewer Sev-2 #3 fix: the parser must REJECT
// ambiguous verdicts like "SAFE, but actually this deletes everything"
// (lenient prefix matching would have accepted it and dropped the
// caveat). Unparseable → graceful degrade, base-guard verdict wins.
@Test
func classifierParser_rejectsAmbiguousVerdictsWithCaveat() {
    if case .unparseable = LLMTaskClassifier.parseVerdict("SAFE, but actually this deletes everything") {
        // ok — comma after the verdict word forces unparseable
    } else {
        Issue.record("parser must reject 'SAFE,...' as unparseable so the caveat isn't silently dropped")
    }
    if case .unparseable = LLMTaskClassifier.parseVerdict("SAFELY navigate to URL") {
        // ok — SAFELY is not SAFE
    } else {
        Issue.record("parser must reject 'SAFELY' — only the exact verdict token counts")
    }
    if case .unparseable = LLMTaskClassifier.parseVerdict("HARMFULLY destroying files") {
        // ok — HARMFULLY is not HARMFUL
    } else {
        Issue.record("parser must reject 'HARMFULLY' — only the exact verdict token counts")
    }
    // Positive: SAFE followed by a period is still SAFE.
    if case .safe = LLMTaskClassifier.parseVerdict("SAFE. The task is benign.") {
        // ok
    } else {
        Issue.record("parser must accept 'SAFE.' boundary (period after verdict)")
    }
}

// New test prompted by reviewer Sev-2 #1 fix: error paths must NOT
// cache nil. Operator triggering a rate limit (429) then retrying the
// same task wording later should re-attempt the LLM call, not get a
// silent forever-bypass.
@Test
func classifier_errorPathsDoNotCacheNil() async {
    MockURLProtocol.callCount = 0
    let cache = TaskClassifierCache()
    // First call: 500 server error → degrade to nil, do NOT cache.
    MockURLProtocol.responder = { _ in
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("transient".utf8))
    }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: cache
    )
    _ = await classifier.shouldBlock(task: "open Safari")
    // Now the server recovers — second call must re-attempt the LLM,
    // not hit a cached nil from the first error.
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "HARMFUL: would harm something") }
    let reason = await classifier.shouldBlock(task: "open Safari")
    #expect(reason?.contains("LLM classifier blocked") == true,
            "after a transient failure the SAME task must re-attempt the LLM — caching nil on error paths would silently bypass classification for the rest of the session")
    #expect(MockURLProtocol.callCount == 2,
            "second call MUST hit the LLM again — error-path nil-caching is a permanent bypass vector")
}

// MARK: - Unit 23 (D8) — RISKY tier-floor

// Parser must recognize RISKY as a distinct verdict. SAFE / RISKY /
// HARMFUL boundary rules are identical; RISKY is the new third state
// between "allow silently" and "block entirely".
@Test
func classifierParser_recognizesRiskyVerdict() {
    if case .risky(let reasoning) = LLMTaskClassifier.parseVerdict("RISKY: empty the trash, irreversible") {
        #expect(reasoning.contains("empty the trash"),
                "RISKY parser must surface the reasoning string for audit-trail logging")
    } else {
        Issue.record("'RISKY: ...' must parse as .risky")
    }
    // EOL boundary
    if case .risky(let reasoning) = LLMTaskClassifier.parseVerdict("RISKY") {
        #expect(reasoning == "(no reasoning provided)",
                "RISKY with no trailing reasoning still parses, fills placeholder")
    } else {
        Issue.record("bare 'RISKY' must parse as .risky")
    }
}

// Parser boundary discipline applies to RISKY too — "RISKILY" must
// not match (the lenient prefix bug class for SAFE / HARMFUL applies
// equally to RISKY).
@Test
func classifierParser_riskyBoundaryDiscipline() {
    if case .unparseable = LLMTaskClassifier.parseVerdict("RISKILY deleting things") {
        // ok
    } else {
        Issue.record("'RISKILY' must NOT match RISKY — only the exact verdict token counts")
    }
    if case .unparseable = LLMTaskClassifier.parseVerdict("RISKY, but probably fine") {
        // ok — comma boundary
    } else {
        Issue.record("'RISKY, ...' must reject — comma after verdict isn't a clean boundary")
    }
}

// shouldBlock on RISKY must NOT block (returns nil) — RISKY means
// "allow but escalate the first action's tier", which is the
// tierFloor's job, not shouldBlock's.
@Test
func classifier_riskyVerdict_doesNotBlock() async {
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "RISKY: empty trash is borderline irreversible") }
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: TaskClassifierCache()
    )
    let reason = await classifier.shouldBlock(task: "empty the trash")
    #expect(reason == nil,
            "RISKY tasks are ALLOWED — shouldBlock must return nil. The tier escalation is a separate channel (tierFloor).")
}

// tierFloor must return .preview after a RISKY verdict was cached
// by the preceding shouldBlock call. One Haiku call serves both
// methods; no second network round-trip.
@Test
func classifier_tierFloor_returnsPreviewForRiskyTask() async {
    MockURLProtocol.callCount = 0
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "RISKY: borderline destructive") }
    let cache = TaskClassifierCache()
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: cache
    )
    _ = await classifier.shouldBlock(task: "empty the trash")
    let floor = await classifier.tierFloor(task: "empty the trash")
    #expect(floor == .preview,
            "RISKY verdict must set the tier floor to .preview so the operator confirms the first action")
    #expect(MockURLProtocol.callCount == 1,
            "tierFloor must read from the shouldBlock-populated cache — no second Haiku call")
}

// tierFloor must return nil for SAFE tasks — only RISKY warrants
// first-step escalation. Auto-promoting every task to .preview would
// defeat the whole point of AutonomyMode.
@Test
func classifier_tierFloor_returnsNilForSafeTask() async {
    MockURLProtocol.responder = { _ in makeJSONResponse(text: "SAFE: benign task") }
    let cache = TaskClassifierCache()
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: cache
    )
    _ = await classifier.shouldBlock(task: "summarize this document")
    let floor = await classifier.tierFloor(task: "summarize this document")
    #expect(floor == nil,
            "SAFE verdict must NOT escalate the first-action tier — only RISKY does")
}

// tierFloor must return nil when there's no cache entry. Defensive:
// if shouldBlock was somehow skipped or hit an error path that
// didn't populate the cache, tierFloor returning a defaulted .preview
// would be a silent friction-add. nil is the safe default.
@Test
func classifier_tierFloor_returnsNilWhenCacheEmpty() async {
    let cache = TaskClassifierCache()
    let classifier = LLMTaskClassifier(
        apiKey: "test-key",
        baseGuard: FixedBaseGuard(reason: nil),
        model: "test-model",
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        session: makeMockSession(),
        cache: cache
    )
    // Note: NO shouldBlock call — cache is empty
    let floor = await classifier.tierFloor(task: "never-classified task")
    #expect(floor == nil,
            "tierFloor must return nil when the cache has no verdict for this task — no defaulting")
}

// Default-extension behaviour: TaskGuarding conformers that don't
// override tierFloor (PermissiveTaskGuard, KeywordTaskGuard) must
// return nil. Production safety: only LLMTaskClassifier should ever
// raise the first-step tier.
@Test
func taskGuarding_defaultExtensionReturnsNilTierFloor() async {
    let permissive: any TaskGuarding = PermissiveTaskGuard()
    let keyword: any TaskGuarding = KeywordTaskGuard()
    let permissiveFloor = await permissive.tierFloor(task: "any task")
    let keywordFloor = await keyword.tierFloor(task: "any task")
    #expect(permissiveFloor == nil,
            "PermissiveTaskGuard must return nil tierFloor — only LLMTaskClassifier has semantic judgment")
    #expect(keywordFloor == nil,
            "KeywordTaskGuard must return nil tierFloor — no semantic understanding to distinguish RISKY from SAFE")
}

}
// end @Suite(.serialized) struct LLMClassifierSuite
