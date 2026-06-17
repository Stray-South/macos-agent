import ApplicationServices
import Foundation
@testable import MacAgentCore
import Testing

@Test
func pruningRemovesHiddenZeroSizedAndDeepElements() {
    let raw = [
        RawAXElement(role: "AXButton", label: "Visible", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)), isEnabled: true, isVisible: true, depth: 1),
        RawAXElement(role: "AXButton", label: "Hidden", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)), isEnabled: true, isVisible: false, depth: 1),
        RawAXElement(role: "AXButton", label: "Zero", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 0, height: 10)), isEnabled: true, isVisible: true, depth: 1),
        RawAXElement(role: "AXButton", label: "Deep", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)), isEnabled: true, isVisible: true, depth: 16),
    ]

    let (pruned, truncated) = AXPerception.prune(rawElements: raw)

    #expect(pruned.count == 1)
    #expect(pruned.first?.label == "Visible")
    #expect(pruned.first?.index == 0)
    #expect(truncated == false)
}

@Test
func pruningReindexesSequentially() {
    let raw = (0..<3).map { index in
        RawAXElement(
            role: "AXButton",
            label: "Button \(index)",
            value: nil,
            frame: CodableRect(.init(x: Double(index), y: 0, width: 20, height: 20)),
            isEnabled: true,
            isVisible: true,
            depth: 1
        )
    }
    let (pruned, _) = AXPerception.prune(rawElements: raw)
    #expect(pruned.map(\.index) == [0, 1, 2])
}

@Test
func snapshotHashIsStableForIdenticalInputs() throws {
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    let elements = [
        UIElement(index: 0, role: "AXButton", label: "Submit", value: nil, frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)), isEnabled: true, isVisible: true),
    ]
    let a = try PerceptionSnapshot.make(timestamp: timestamp, focusedAppBundleID: "com.example.app", elements: elements)
    let b = try PerceptionSnapshot.make(timestamp: timestamp, focusedAppBundleID: "com.example.app", elements: elements)
    #expect(a.hash == b.hash)
}

@Test
func perceptionCachesSnapshotsWithin500ms() async throws {
    actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }
    let counter = Counter()
    let perception = AXPerception {
        let index = await counter.next()
        return (
            bundleID: "com.example.app",
            raw: [
                RawAXElement(
                    role: "AXButton",
                    label: "Button \(index)",
                    value: nil,
                    frame: CodableRect(.init(x: 0, y: 0, width: 20, height: 20)),
                    isEnabled: true,
                    isVisible: true,
                    depth: 0
                ),
            ],
            lookup: [:],
            agentIsOverlaid: false
        )
    }

    let first = try await perception.capture(forceRefresh: false)
    let second = try await perception.capture(forceRefresh: false)

    #expect(first.snapshot.hash == second.snapshot.hash)
    #expect(first.snapshot.elements.first?.label == "Button 1")
}

// MARK: - Cluster E: lookup-rebuild-post-prune

@Test
func pruneRebuildsLookupSoExecutorResolvesPostPruneIndexCorrectly() async throws {
    // Bug scenario: walker visits A (counter=0), B (counter=1, will be pruned —
    // zero-width), C (counter=2). Pre-fix lookup was keyed by walker counter,
    // so Executor.resolveTarget(targetIndex: 1) — meaning C in the post-prune
    // snapshot — would query lookup[1] and receive B's AXUIElement.
    //
    // The exposed surface here is `pruneWithWalkerIndices` + a synthetic walker.
    // We can't construct a real AXUIElement in a test, but we CAN verify that
    // the walker indices returned by prune match the surviving elements 1:1,
    // which is the invariant capture() relies on when rebuilding the lookup.
    let raw = [
        RawAXElement(role: "AXButton", label: "A", value: nil,
                     frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)),
                     isEnabled: true, isVisible: true, depth: 1, walkerIndex: 0),
        RawAXElement(role: "AXButton", label: "B-pruned", value: nil,
                     frame: CodableRect(.init(x: 0, y: 0, width: 0, height: 10)),  // zero width → pruned
                     isEnabled: true, isVisible: true, depth: 1, walkerIndex: 1),
        RawAXElement(role: "AXButton", label: "C", value: nil,
                     frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)),
                     isEnabled: true, isVisible: true, depth: 1, walkerIndex: 2),
    ]
    let (elements, walkerIndices, _) = AXPerception.pruneWithWalkerIndices(rawElements: raw)
    #expect(elements.map(\.label) == ["A", "C"],
            "B should be pruned — only A and C survive.")
    #expect(walkerIndices == [0, 2],
            "Surviving elements must carry their original walker counters, not the post-prune indices.")
    // Sanity: capture()'s rebuild loop maps post-prune index i to walkerIndices[i].
    // i=0 → walker 0 (A). i=1 → walker 2 (C). Pre-fix it would have been i=0→0 (A), i=1→1 (B-PRUNED).
}

@Test
func captureRebuildsLookupKeyedByPostPruneIndex() async throws {
    // End-to-end via a custom walker. AXUIElement isn't Sendable so we create
    // the instances INSIDE the closure (no capture). To verify identity we use
    // AXUIElementCreateApplication(pid) with arbitrary distinct PIDs and read
    // them back via AXUIElementGetPid — pre-fix the walker-keyed lookup would
    // resolve index 1 to B-pruned (pid 101); post-fix it resolves to C (102).
    let perception = AXPerception {
        let a = AXUIElementCreateApplication(100)
        let b = AXUIElementCreateApplication(101)
        let c = AXUIElementCreateApplication(102)
        return (
            bundleID: "com.example",
            raw: [
                RawAXElement(role: "AXButton", label: "A", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)),
                             isEnabled: true, isVisible: true, depth: 1, walkerIndex: 0),
                RawAXElement(role: "AXButton", label: "B-pruned", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 0, height: 10)),
                             isEnabled: true, isVisible: true, depth: 1, walkerIndex: 1),
                RawAXElement(role: "AXButton", label: "C", value: nil,
                             frame: CodableRect(.init(x: 0, y: 0, width: 10, height: 10)),
                             isEnabled: true, isVisible: true, depth: 1, walkerIndex: 2),
            ],
            lookup: [0: a, 1: b, 2: c],
            agentIsOverlaid: false
        )
    }
    let observed = try await perception.capture(forceRefresh: true)
    #expect(observed.snapshot.elements.map(\.label) == ["A", "C"])

    func pidOf(_ el: AXUIElement?) -> pid_t? {
        guard let el else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }
    #expect(pidOf(observed.lookup.element(at: 0)) == 100,
            "post-prune index 0 must resolve to walker 0 (A, pid 100).")
    #expect(pidOf(observed.lookup.element(at: 1)) == 102,
            "post-prune index 1 must resolve to walker 2 (C, pid 102), NOT walker 1 (B-pruned, pid 101).")
    #expect(pidOf(observed.lookup.element(at: 2)) == nil,
            "post-prune index 2 has no element — only 2 elements survived. Pre-fix the walker-keyed lookup would have returned pid 102 here.")
}

@Test
func perceptionSnapshotRoundTripsWithScreenshotLogicalSize() throws {
    // PerceptionSnapshot Codable conformance must round-trip the new optional
    // screenshotLogicalSize field (added for Cluster E E4). Defaults nil; setting
    // it preserves the CGSize across encode/decode. Hash MUST be stable across
    // changes to screenshotLogicalSize since it's intentionally excluded from
    // SnapshotHashPayload — same reasoning as screenshotPNG.
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let elements = [
        UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                  frame: CodableRect(.init(x: 0, y: 0, width: 80, height: 30)),
                  isEnabled: true, isVisible: true),
    ]
    let withSize = try PerceptionSnapshot.make(
        timestamp: timestamp, focusedAppBundleID: "com.test", elements: elements,
        screenshotLogicalSize: CodableSize(.init(width: 1440, height: 900))
    )
    let withoutSize = try PerceptionSnapshot.make(
        timestamp: timestamp, focusedAppBundleID: "com.test", elements: elements
    )
    #expect(withSize.screenshotLogicalSize?.cgSize == CGSize(width: 1440, height: 900))
    #expect(withoutSize.screenshotLogicalSize == nil)
    #expect(withSize.hash == withoutSize.hash,
            "screenshotLogicalSize must be excluded from the hash (same rule as screenshotPNG).")

    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let data = try enc.encode(withSize)
    let decoded = try dec.decode(PerceptionSnapshot.self, from: data)
    #expect(decoded.screenshotLogicalSize?.cgSize == CGSize(width: 1440, height: 900),
            "screenshotLogicalSize must round-trip through Codable.")
}

// Unit 5 / H3 — AXPerceptionError.agentIsFrontmost carries the offending
// bundle ID through to the operator-facing message. AppModel.runTask's
// catch surfaces error.localizedDescription as a system conversation
// bubble; the message must name the bundle so the operator can identify
// what to switch away from.
@Test
func agentIsFrontmostErrorMessageNamesBundleID() {
    let error = AXPerceptionError.agentIsFrontmost(bundleID: "com.southernreach.macos-agent-v0")
    let description = error.errorDescription
    #expect(description?.contains("com.southernreach.macos-agent-v0") == true,
            "Error message must include the offending bundle ID so the operator can locate the window.")
    #expect(description?.contains("re-submit") == true || description?.contains("front") == true,
            "Error message must include actionable guidance — bring target app forward.")
}

// AXPerception.capture() propagates AXPerceptionError.agentIsFrontmost
// unchanged when an injected walker throws it. Locks the invariant that
// the cache/prune/lookup-rebuild pipeline doesn't swallow or transform
// the error class — AppModel.runTask's catch relies on the original
// error type surviving the path through observe() in Orchestrator.
@Test
func injectedWalkerThrowingAgentIsFrontmost_propagatesUnchanged() async throws {
    let perception = AXPerception {
        throw AXPerceptionError.agentIsFrontmost(bundleID: "com.southernreach.macos-agent-v0")
    }

    // Match the specific case, not the whole enum — a regression that
    // swapped the error to .permissionsRevoked or .noFrontmostApp would
    // sail past `throws: AXPerceptionError.self`.
    do {
        _ = try await perception.capture(forceRefresh: true)
        Issue.record("capture() must propagate agentIsFrontmost from the injected walker")
    } catch let error as AXPerceptionError {
        guard case .agentIsFrontmost(let bundleID) = error else {
            Issue.record("Expected .agentIsFrontmost, got \(error)")
            return
        }
        #expect(bundleID == "com.southernreach.macos-agent-v0")
    }
}

// `isAgentProcess` is the comparison the `defaultWalker` guard uses to
// decide whether the frontmost-app PID belongs to us. Extracted to a
// pure static helper so tests can exercise it without a real macOS
// frontmost app and without AX permission. A regression that flipped
// the operator (== to !=) or hardcoded a constant would be caught here.
@Test
func isAgentProcess_matchesOnlyWhenPIDsAreEqual() {
    #expect(AXPerception.isAgentProcess(12345, agentPID: 12345) == true)
    #expect(AXPerception.isAgentProcess(12345, agentPID: 99999) == false)
    #expect(AXPerception.isAgentProcess(0, agentPID: 0) == true,
            "PID 0 is the kernel; equality is what the helper tests, semantic meaning is the caller's problem.")
    // Default `agentPID` argument resolves to this process — sanity check
    // that the default is actually our PID (not, e.g., a hardcoded 0).
    let myPID = ProcessInfo.processInfo.processIdentifier
    #expect(AXPerception.isAgentProcess(myPID) == true)
}

// Unit 8 — AXPerception.init accepts a FallbackFrontmostProvider closure.
// Back-compat: when a custom walker is injected (tests), the fallback
// provider is ignored — the custom walker takes precedence. This lock
// guards against a refactor that accidentally pipes the provider through
// to the custom walker (which would break every existing test that
// injects a walker without expecting the fallback semantics).
@Test
func axPerception_customWalker_ignoresFallbackProvider() async throws {
    actor FallbackCounter {
        var calls = 0
        func bump() -> pid_t? { calls += 1; return 12345 }
        func count() -> Int { calls }
    }
    let counter = FallbackCounter()
    let perception = AXPerception(
        walker: {
            return (
                bundleID: "com.example.app",
                raw: [
                    RawAXElement(
                        role: "AXButton", label: "OK", value: nil,
                        frame: CodableRect(.init(x: 0, y: 0, width: 60, height: 30)),
                        isEnabled: true, isVisible: true, depth: 1
                    ),
                ],
                lookup: [:],
                agentIsOverlaid: false
            )
        },
        fallbackFrontmostProvider: { await counter.bump() }
    )

    let snapshot = try await perception.capture(forceRefresh: true)
    #expect(snapshot.snapshot.focusedAppBundleID == "com.example.app",
            "custom walker's bundleID must win — fallback path is not consulted when a walker is injected")
    #expect(await counter.count() == 0,
            "fallback provider must NOT be called when a custom walker is in use")
}

// Unit 8 — production `defaultWalker` cannot be directly unit-tested
// because it requires real macOS AX permission, a real NSWorkspace
// frontmost app, and the helper internals are private. This test pins
// the API contract: AXPerception(fallbackFrontmostProvider:) compiles
// and the closure type is `@Sendable () async -> pid_t?`. A regression
// that flips the closure's signature would fail to compile, catching
// the break before runtime.
@Test
func axPerception_fallbackProviderInit_compiles() {
    let _: AXPerception = AXPerception(
        fallbackFrontmostProvider: { () async -> pid_t? in nil }
    )
}

// Unit 8/10 — `resolveTargetApp` is the testable extraction of defaultWalker's
// "which app do I actually walk?" decision. Post-Unit-10, never returns nil:
//   (a) frontmost is NOT the agent → return frontmost as-is
//   (b) frontmost IS the agent + fallback provider returns a live PID →
//       return the resolved fallback AppInfo (Unit 8 path)
//   (c) frontmost IS the agent + no fallback provider OR provider returns nil
//       → return frontmost (the agent itself). Cold-start; defaultWalker
//       walks our own tree and agentIsOverlaid=true tells the LLM via the
//       Unit 10 prompt directive to dispatch switchApp first.
//   (d) frontmost IS the agent + provider returns PID + resolveFallback
//       returns nil (stale/terminated) → return frontmost (cold-start fallback)

@Test
func resolveTargetApp_nonAgentFrontmost_returnsFrontmost() async {
    let frontmost = AppInfo(pid: 12345, bundleID: "com.apple.notes", localizedName: "Notes")
    let agentPID = ProcessInfo.processInfo.processIdentifier
    #expect(frontmost.pid != agentPID, "test fixture must use a non-agent PID")

    let resolved = await AXPerception.resolveTargetApp(
        frontmost: frontmost,
        fallbackProvider: { 99999 }, // would-be-fallback ignored when frontmost isn't agent
        resolveFallback: { _ in
            Issue.record("resolveFallback must NOT be called when frontmost isn't the agent")
            return nil
        }
    )

    #expect(resolved.pid == 12345)
    #expect(resolved.bundleID == "com.apple.notes")
}

// Unit 10 — cold start: no fallback configured. resolveTargetApp returns the
// agent's own info (was nil pre-Unit-10). Walker walks the agent's own tree,
// agentIsOverlaid=true, LLM's cold-start prompt directive fires.
@Test
func resolveTargetApp_agentFrontmost_noFallback_returnsAgentItself() async {
    let agentPID = ProcessInfo.processInfo.processIdentifier
    let frontmost = AppInfo(pid: agentPID, bundleID: "com.southernreach.macos-agent-v0", localizedName: "macOS Agent v0")

    let resolved = await AXPerception.resolveTargetApp(
        frontmost: frontmost,
        fallbackProvider: nil,
        resolveFallback: { _ in
            Issue.record("resolveFallback must NOT be called when fallbackProvider is nil")
            return nil
        }
    )

    #expect(resolved.pid == agentPID,
            "Unit 10: cold start returns the agent's own info — caller walks own tree, prompt directs switchApp")
    #expect(resolved.bundleID == "com.southernreach.macos-agent-v0")
}

@Test
func resolveTargetApp_agentFrontmost_fallbackResolves_returnsFallback() async {
    let agentPID = ProcessInfo.processInfo.processIdentifier
    let frontmost = AppInfo(pid: agentPID, bundleID: "com.southernreach.macos-agent-v0", localizedName: "macOS Agent v0")
    let fallbackInfo = AppInfo(pid: 7777, bundleID: "com.apple.notes", localizedName: "Notes")

    let resolved = await AXPerception.resolveTargetApp(
        frontmost: frontmost,
        fallbackProvider: { 7777 },
        resolveFallback: { pid in
            #expect(pid == 7777, "resolveFallback must be called with the provider's returned PID")
            return fallbackInfo
        }
    )

    #expect(resolved.pid == 7777)
    #expect(resolved.bundleID == "com.apple.notes",
            "snapshot's focusedAppBundleID must reflect the fallback app, not the agent")
}

// Unit 10 — stale fallback PID also falls back to agent's own info (was nil
// pre-Unit-10). The chain: provider returns a PID, resolveFallback can't find
// it (app terminated between activation and walk), so resolveTargetApp
// degrades to cold-start semantics rather than throwing.
@Test
func resolveTargetApp_agentFrontmost_fallbackStale_returnsAgentItself() async {
    let agentPID = ProcessInfo.processInfo.processIdentifier
    let frontmost = AppInfo(pid: agentPID, bundleID: "com.southernreach.macos-agent-v0", localizedName: "macOS Agent v0")

    let resolved = await AXPerception.resolveTargetApp(
        frontmost: frontmost,
        fallbackProvider: { 7777 },
        resolveFallback: { _ in nil } // provider returned 7777, but resolver couldn't find it (terminated)
    )

    #expect(resolved.pid == agentPID,
            "Unit 10: stale fallback degrades to cold-start (walk own tree + cold-start prompt) rather than throwing")
}

// MARK: - Unit 9 — agentIsOverlaid flag

// Default value is false — additive Codable field doesn't disturb existing
// snapshots. PerceptionSnapshot.make() callers that omit the new param get
// the safe-default.
@Test
func perceptionSnapshot_agentIsOverlaid_defaultsFalse() throws {
    let s = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.apple.notes",
        elements: []
    )
    #expect(s.agentIsOverlaid == false)
}

@Test
func perceptionSnapshot_agentIsOverlaid_setterRoundTrips() throws {
    let s = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.apple.notes",
        elements: [],
        agentIsOverlaid: true
    )
    #expect(s.agentIsOverlaid == true)

    // Codable round-trip preserves the flag.
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let data = try enc.encode(s)
    let decoded = try dec.decode(PerceptionSnapshot.self, from: data)
    #expect(decoded.agentIsOverlaid == true)
}

// The flag is intentionally EXCLUDED from the snapshot hash — same precedent
// as screenshotPNG / screenshotLogicalSize. Two snapshots that differ only
// in agentIsOverlaid must produce the same hash (otherwise the orchestrator's
// snapshot-hash-based caching / dedup would treat fallback vs non-fallback
// observations as different states for the same UI).
@Test
func perceptionSnapshot_agentIsOverlaid_excludedFromHash() throws {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let elements = [
        UIElement(index: 0, role: "AXButton", label: "OK", value: nil,
                  frame: CodableRect(.init(x: 0, y: 0, width: 60, height: 30)),
                  isEnabled: true, isVisible: true),
    ]
    let withFlag = try PerceptionSnapshot.make(
        timestamp: timestamp, focusedAppBundleID: "com.apple.notes",
        elements: elements, agentIsOverlaid: true
    )
    let withoutFlag = try PerceptionSnapshot.make(
        timestamp: timestamp, focusedAppBundleID: "com.apple.notes",
        elements: elements, agentIsOverlaid: false
    )
    #expect(withFlag.hash == withoutFlag.hash,
            "agentIsOverlaid must be excluded from the snapshot hash — same rule as screenshotPNG.")
}

// CU system prompt — when agentIsOverlaid is true, the prompt must
// instruct the model to dispatch switchApp before any click. This locks
// the LLM-facing warning text so a future refactor doesn't silently
// remove the safety guidance.
@Test
func cuSystemPrompt_agentIsOverlaid_emitsSwitchAppDirective() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.notes",
        elements: [], agentIsOverlaid: true
    )
    let prompt = ComputerUseClient.buildSystemPrompt(
        task: "click new note", snapshot: snapshot, history: [], runningApps: []
    )
    #expect(prompt.contains("macOS Agent v0's launcher window is still in front"),
            "Operator-friendly framing of the overlay condition must be in the prompt.")
    #expect(prompt.contains("switchApp"),
            "Model must be told to dispatch switchApp first — without this directive the CGEvent click lands on the agent overlay.")
    #expect(prompt.contains("com.apple.notes"),
            "Prompt must include the fallback app's bundle ID so the switchApp action is targeted correctly.")
}

@Test
func cuSystemPrompt_agentIsOverlaid_false_noWarning() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.notes",
        elements: [], agentIsOverlaid: false
    )
    let prompt = ComputerUseClient.buildSystemPrompt(
        task: "click new note", snapshot: snapshot, history: [], runningApps: []
    )
    #expect(!prompt.contains("launcher window is still in front"),
            "When the agent is NOT overlaid, the warning must be absent — false positives would confuse the model.")
}

// Standard-path (ClaudeLLMClient) parallel — the standard prompt is the
// default for all operators (CU is opt-in via the useComputerUse pref).
// The Unit 9 warning must appear in BOTH prompt paths, not just the CU
// one, or operators on the default path get no safety guidance.
@Test
func llmSystemPrompt_agentIsOverlaid_emitsSwitchAppDirective() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.notes",
        elements: [], agentIsOverlaid: true
    )
    let prompt = try ClaudeLLMClient.buildSystemPrompt(
        task: "click new note", snapshot: snapshot, runningApps: []
    )
    #expect(prompt.contains("macOS Agent v0's launcher window is still in front"),
            "Standard-path prompt must carry the same operator-friendly framing as the CU prompt.")
    #expect(prompt.contains("switchApp"),
            "Model must be told to dispatch switchApp first on the standard path too.")
    #expect(prompt.contains("com.apple.notes"),
            "Prompt must include the fallback app's bundle ID so the switchApp action is targeted correctly.")
}

@Test
func llmSystemPrompt_agentIsOverlaid_false_noWarning() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.notes",
        elements: [], agentIsOverlaid: false
    )
    let prompt = try ClaudeLLMClient.buildSystemPrompt(
        task: "click new note", snapshot: snapshot, runningApps: []
    )
    #expect(!prompt.contains("launcher window is still in front"),
            "Standard-path prompt must suppress the warning when the agent is NOT overlaid.")
}

// MARK: - Unit 10 — cold-start prompt directive

// When focusedAppBundleID IS the agent's bundle (cold start: walker walked
// its own tree because no fallback was available), the prompt's cold-start
// branch fires instead of the Unit 9 fallback-fired branch. The text must:
//   - Explicitly say "COLD START" so the LLM doesn't confuse with Unit 9.
//   - Tell the LLM NOT to click any AX element below (those are launcher UI).
//   - Direct the LLM to dispatch switchApp(text="<bundleID>") as first action,
//     mentioning that switchApp activates running OR launches by bundle ID.
//   - Permit clarify when task is ambiguous about which app.

@Test
func cuSystemPrompt_coldStart_emitsColdStartDirective() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: agentBundleID,
        elements: [], agentIsOverlaid: true
    )
    let prompt = ComputerUseClient.buildSystemPrompt(
        task: "open Notes and write a poem", snapshot: snapshot, history: [], runningApps: []
    )
    #expect(prompt.contains("COLD START"),
            "Cold-start branch must announce itself explicitly so the LLM doesn't confuse with Unit 9's fallback-fired text.")
    #expect(prompt.contains("switchApp"),
            "Cold-start prompt must direct the LLM to dispatch switchApp first.")
    #expect(prompt.contains("activate a running app OR launch"),
            "Cold-start prompt must educate the LLM that switchApp covers both running and not-yet-running apps.")
    #expect(prompt.contains("clarify"),
            "Cold-start prompt must mention clarify as a valid fallback for ambiguous tasks.")
    #expect(prompt.contains("do NOT click"),
            "Cold-start prompt must explicitly forbid clicking the launcher's own AX elements.")
}

@Test
func llmSystemPrompt_coldStart_emitsColdStartDirective() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: agentBundleID,
        elements: [], agentIsOverlaid: true
    )
    let prompt = try ClaudeLLMClient.buildSystemPrompt(
        task: "open Notes and write a poem", snapshot: snapshot, runningApps: []
    )
    #expect(prompt.contains("COLD START"))
    #expect(prompt.contains("switchApp"))
    #expect(prompt.contains("activate a running app OR launch"))
    #expect(prompt.contains("clarify"))
}

// Differentiation: when focusedAppBundleID is a NON-AGENT app + agentIsOverlaid
// is true (Unit 9 fallback-fired case), the prompt must use the existing
// fallback-fired text — NOT the cold-start text. The two scenarios produce
// different operator-facing semantics in receipts and the LLM's expected
// action target.
// Unit 10 — readOnly adjustedTier lock. The autonomy-matrix integration
// test for readOnly uses RejectingOverlay, which would still block execution
// even if `readOnly.adjustedTier` were broken. This unit test directly
// asserts the mode's tier-mapping behavior so a future refactor that
// accidentally raises switchApp to .auto under readOnly fails here.
@Test
func autonomyMode_readOnly_keepsSwitchAppAtPreview() {
    let switchApp = AgentAction(
        type: .switchApp, text: "com.apple.notes",
        confidence: 0.95, requiresConfirmation: false,
        rationale: "test"
    )
    // readOnly floors EVERY non-terminal action at .preview regardless of
    // baseTier — the mode never executes, so the gate's purpose shifts from
    // "should I run this?" to "show the operator what would happen." The
    // baseTier doesn't affect operational safety because nothing fires.
    #expect(AutonomyMode.readOnly.adjustedTier(for: switchApp, baseTier: .preview) == .preview,
            "readOnly: switchApp .preview stays .preview.")
    #expect(AutonomyMode.readOnly.adjustedTier(for: switchApp, baseTier: .auto) == .preview,
            "readOnly: switchApp .auto MUST demote to .preview so the operator sees it in the gate.")
    #expect(AutonomyMode.readOnly.adjustedTier(for: switchApp, baseTier: .confirm) == .preview,
            "readOnly: .confirm demotes to .preview — operational safety unchanged since readOnly never executes.")
    // Sanity: terminal actions stay at baseTier in readOnly (per the explicit
    // switch on action.type in AutonomyMode.swift). Lock the non-demote path.
    let complete = AgentAction(type: .complete, confidence: 1.0, requiresConfirmation: false, rationale: "done")
    #expect(AutonomyMode.readOnly.adjustedTier(for: complete, baseTier: .auto) == .auto,
            "readOnly: terminal actions pass through unchanged — only non-terminals demote.")
}

@Test
func cuSystemPrompt_fallbackFired_emitsFallbackDirective_notColdStart() throws {
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.notes",
        elements: [], agentIsOverlaid: true
    )
    let prompt = ComputerUseClient.buildSystemPrompt(
        task: "click new note", snapshot: snapshot, history: [], runningApps: []
    )
    #expect(!prompt.contains("COLD START"),
            "Fallback-fired branch (focusedAppBundleID != agent's) must NOT use the cold-start text.")
    #expect(prompt.contains("launcher window is still in front of com.apple.notes"),
            "Fallback-fired branch must use the existing Unit 9 text naming the target app.")
}

// MARK: - Unit 25 isFocused schema

@Test
func uiElement_decodesLegacyJSONWithoutIsFocused_defaultsToFalse() throws {
    // Snapshot sidecars written before Unit 25 lack the isFocused key.
    // Custom Codable on UIElement must default isFocused=false on decode
    // so old sidecars still load.
    let legacyJSON = """
    {
        "index": 0,
        "role": "AXButton",
        "label": "Continue",
        "frame": {"x": 0, "y": 0, "width": 80, "height": 30},
        "isEnabled": true,
        "isVisible": true
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(UIElement.self, from: legacyJSON)
    #expect(decoded.isFocused == false,
            "Pre-Unit-25 JSON missing isFocused must decode to false (Codable default).")
    #expect(decoded.label == "Continue",
            "Other fields must decode normally.")
}

@Test
func uiElement_encodeIncludesIsFocused() throws {
    let el = UIElement(
        index: 0, role: "AXTextField", label: "Search", value: "",
        frame: CodableRect(.init(x: 0, y: 0, width: 100, height: 20)),
        isEnabled: true, isVisible: true, isFocused: true
    )
    let data = try JSONEncoder().encode(el)
    let str = String(decoding: data, as: UTF8.self)
    #expect(str.contains("\"isFocused\":true"),
            "Encoded JSON must include the isFocused key — Unit 25 surface.")
}

@Test
func snapshotHash_changesWhenIsFocusedDiffers() throws {
    // Hash includes elements per SnapshotHashPayload. Two snapshots that
    // differ only in isFocused must produce different hashes. This is the
    // one-time rotation flagged in Unit 25 research.
    let frame = CodableRect(.init(x: 0, y: 0, width: 100, height: 20))
    let t = Date(timeIntervalSince1970: 1_000_000)
    let a = try PerceptionSnapshot.make(
        timestamp: t, focusedAppBundleID: "com.example.app",
        elements: [UIElement(index: 0, role: "AXTextField", label: "Search",
                             value: "", frame: frame, isEnabled: true, isVisible: true,
                             isFocused: false)]
    )
    let b = try PerceptionSnapshot.make(
        timestamp: t, focusedAppBundleID: "com.example.app",
        elements: [UIElement(index: 0, role: "AXTextField", label: "Search",
                             value: "", frame: frame, isEnabled: true, isVisible: true,
                             isFocused: true)]
    )
    #expect(a.hash != b.hash,
            "Snapshot hash must change when isFocused flips — the field IS UI state.")
}

@Test
func standardSystemPrompt_includesIsFocusedInSerializedElements() throws {
    let frame = CodableRect(.init(x: 0, y: 0, width: 200, height: 28))
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.Notes",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "Sidebar",
                      value: nil, frame: frame, isEnabled: true, isVisible: true,
                      isFocused: false),
            UIElement(index: 1, role: "AXTextField", label: "Search",
                      value: "", frame: frame, isEnabled: true, isVisible: true,
                      isFocused: true)
        ]
    )
    let prompt = try ClaudeLLMClient.buildSystemPrompt(
        task: "search notes", snapshot: snapshot, runningApps: []
    )
    #expect(prompt.contains("\"isFocused\":true"),
            "Standard-path prompt JSON must surface the focused element's isFocused=true.")
    #expect(prompt.contains("isFocused: true on at most one element"),
            "Standard-path prompt Rules block must explain isFocused semantics.")
}

@Test
func cuSystemPrompt_includesFocusedFlagWhenTrue_omitsWhenFalse() throws {
    let frame = CodableRect(.init(x: 0, y: 0, width: 200, height: 28))
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.apple.Notes",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "Sidebar",
                      value: nil, frame: frame, isEnabled: true, isVisible: true,
                      isFocused: false),
            UIElement(index: 1, role: "AXTextField", label: "Search",
                      value: "", frame: frame, isEnabled: true, isVisible: true,
                      isFocused: true)
        ]
    )
    let prompt = ComputerUseClient.buildSystemPrompt(
        task: "search notes", snapshot: snapshot, history: [], runningApps: []
    )
    let searchLine = prompt.split(separator: "\n").first { $0.contains("[1]") }
    #expect(searchLine?.contains("focused:true") == true,
            "CU line-format must include focused:true on the focused element.")
    let sidebarLine = prompt.split(separator: "\n").first { $0.contains("[0]") }
    #expect(sidebarLine?.contains("focused") == false,
            "CU line-format must omit the focused field on non-focused elements (terse-by-default).")
}
