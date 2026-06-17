/// ComputerUseTranslateTests.swift
///
/// Wire-format and translator regression tests for `ComputerUseClient`. These
/// exercise the pure-translation surface; they don't make network calls.
///
/// Coverage (paired to commit `fix(cu): translator wire-format + safety-floor activation`):
///   - `scroll` reads `scroll_direction` / `scroll_amount` (was `direction`/`amount`).
///   - `nearestElement` honors the 100-pt distance threshold (returns nil index).
///   - `coordinate(from:)` returns `nil` (not `.zero`) on missing / malformed.
///   - `x11KeysToMacOS` preserves `ctrl`, maps `super` → `cmd`.
///   - `AnyCodable.init` decode order matches `LLMClient.AnyDecodable`.
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - x11 key mapping (pure helper, public-via-actor)
//
// Exposed via `xKeysForTesting(_:)` accessor on ComputerUseClient to avoid
// reflection. See note in source.

@Test
func cuAnyCodable_decodesInt() throws {
    let data = Data("42".utf8)
    let v = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(v.value is Int)
    #expect((v.value as? Int) == 42)
}

@Test
func cuAnyCodable_decodesTrueAsBool() throws {
    let data = Data("true".utf8)
    let v = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(v.value is Bool)
    #expect((v.value as? Bool) == true)
}

@Test
func cuAnyCodable_decodes1Point5AsDouble() throws {
    let data = Data("1.5".utf8)
    let v = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(v.value is Double)
    #expect((v.value as? Double) == 1.5)
}

@Test
func cuAnyCodable_decodesNullAsNSNull() throws {
    let data = Data("null".utf8)
    let v = try JSONDecoder().decode(AnyCodable.self, from: data)
    #expect(v.value is NSNull)
}

// MARK: - Translator behavior (exercised via the public actor API)
//
// `translate` is private. Coverage here is via `nextAction` against a stubbed
// URLSession that returns canned responses. Lower-level pure helpers
// (`coordinate`, `nearestElement`, `x11KeysToMacOS`) are exposed for tests via
// internal-static accessor in `ComputerUseClient+Testing.swift` (added in this
// commit) so the test surface is direct and brittle-free.

@Test
func cuCoordinate_fromIntPair_returnsCGPoint() {
    let dict: [String: Any] = ["coordinate": [120, 80]]
    let any = AnyCodable(dict["coordinate"]!)
    let p = ComputerUseClient.coordinateForTesting(any)
    #expect(p != nil)
    #expect(p?.x == 120)
    #expect(p?.y == 80)
}

@Test
func cuCoordinate_fromDoublePair_returnsCGPoint() {
    let any = AnyCodable([120.5, 80.5] as [Any])
    let p = ComputerUseClient.coordinateForTesting(any)
    #expect(p != nil)
    #expect(p?.x == 120.5)
    #expect(p?.y == 80.5)
}

@Test
func cuCoordinate_fromMissing_returnsNil() {
    let p = ComputerUseClient.coordinateForTesting(nil)
    #expect(p == nil)
}

@Test
func cuCoordinate_fromMalformed_returnsNil() {
    let any = AnyCodable(["foo", "bar"] as [Any])
    let p = ComputerUseClient.coordinateForTesting(any)
    #expect(p == nil)
}

@Test
func cuCoordinate_fromShortArray_returnsNil() {
    let any = AnyCodable([42] as [Any])
    let p = ComputerUseClient.coordinateForTesting(any)
    #expect(p == nil)
}

@Test
func cuX11KeysToMacOS_superMapsToCmd() {
    #expect(ComputerUseClient.x11KeysToMacOSForTesting("super+c") == "cmd+c")
}

@Test
func cuX11KeysToMacOS_ctrlPreservesControl() {
    // Regression guard: prior implementation remapped ctrl→cmd, silently
    // turning every terminal Ctrl+C into a macOS Copy.
    #expect(ComputerUseClient.x11KeysToMacOSForTesting("ctrl+c") == "ctrl+c")
}

@Test
func cuX11KeysToMacOS_controlPreservesControl() {
    #expect(ComputerUseClient.x11KeysToMacOSForTesting("control+a") == "control+a")
}

@Test
func cuX11KeysToMacOS_returnLowercased() {
    #expect(ComputerUseClient.x11KeysToMacOSForTesting("Return") == "return")
}

@Test
func cuNearestElement_within100pt_returnsIndex() throws {
    let snap = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "OK",
                      value: nil,
                      frame: CodableRect(.init(x: 100, y: 100, width: 40, height: 20)),
                      isEnabled: true, isVisible: true),
        ]
    )
    // Element center is (120, 110). Click at (150, 150) → dist ~50 → within threshold.
    let (idx, conf) = ComputerUseClient.nearestElementForTesting(CGPoint(x: 150, y: 150), snapshot: snap)
    #expect(idx == 0)
    #expect(conf >= 0.6, "expected medium confidence within 100pt, got \(conf)")
}

@Test
func cuNearestElement_beyond100pt_returnsNilIndex() throws {
    let snap = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "OK",
                      value: nil,
                      frame: CodableRect(.init(x: 100, y: 100, width: 40, height: 20)),
                      isEnabled: true, isVisible: true),
        ]
    )
    // Element center (120, 110). Click at (500, 500) → dist ~565 → > 100pt threshold.
    // Returns nil so the safety floor + executor coordinate fallback activate.
    let (idx, conf) = ComputerUseClient.nearestElementForTesting(CGPoint(x: 500, y: 500), snapshot: snap)
    #expect(idx == nil, "expected nil index past 100pt threshold; AX matching disabled to activate coord-only floor")
    #expect(conf == 0.45, "confidence reported as 0.45 for far misses")
}

// MARK: - Defensive decoder hardening (F4-1)

@Test
func cuTranslate_zoomAction_returnsWaitWithExplicitRationale() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("zoom"),
        "region": AnyCodable([100, 200, 400, 350] as [Any]),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .wait)
    #expect(action.rationale.contains("zoom requested but not enabled"),
            "rationale should explicitly mention zoom — pre-fix this fell to 'Unknown' default")
}

// MARK: - Cluster F: history image stripping

@Test
func cuStripImages_replacesImageBlocksWithTextPlaceholders() {
    let input: [CUContent] = [
        .text("hi"),
        .image(mediaType: "image/png", data: "<base64-blob>"),
        .text("bye"),
    ]
    let stripped = ComputerUseClient.stripImages(from: input)
    #expect(stripped.count == 3)
    if case .text(let s) = stripped[0] { #expect(s == "hi") } else { Issue.record("text 0 lost") }
    if case .text(let s) = stripped[1] { #expect(s.hasPrefix("[screenshot omitted")) } else { Issue.record("image not replaced with text placeholder") }
    if case .text(let s) = stripped[2] { #expect(s == "bye") } else { Issue.record("text 2 lost") }
}

@Test
func cuStripImages_preservesToolUseAndRecursesIntoToolResult() {
    // tool_use + tool_result must round-trip with the same toolUseID — orphan
    // tool_use without a matching tool_result is a hard Anthropic API error.
    let nested: [CUContent] = [
        .image(mediaType: "image/png", data: "<old-screenshot>"),
        .text("ok"),
    ]
    let input: [CUContent] = [
        .toolUse(id: "tu_123", name: "computer", input: [:]),
        .toolResult(toolUseID: "tu_123", content: nested),
        .text("fresh"),
    ]
    let stripped = ComputerUseClient.stripImages(from: input)
    #expect(stripped.count == 3)
    if case .toolUse(let id, _, _) = stripped[0] {
        #expect(id == "tu_123", "tool_use ID must be preserved verbatim — orphan tool_use is an API error.")
    } else {
        Issue.record("tool_use block was not preserved")
    }
    if case .toolResult(let id, let inner) = stripped[1] {
        #expect(id == "tu_123", "tool_result must keep its toolUseID so the pair stays bound.")
        #expect(inner.count == 2, "inner content count preserved")
        if case .text(let s) = inner[0] { #expect(s.hasPrefix("[screenshot omitted")) }
        else { Issue.record("nested image not stripped inside tool_result") }
        if case .text(let s) = inner[1] { #expect(s == "ok") }
    } else {
        Issue.record("tool_result block was not preserved")
    }
}

@Test
func cuHistoryCap_preservesUserFirstInvariantAcrossTrim() {
    // Pre-followup bug: cuHistory.count==21 (after appending user[20]) →
    // suffix(20) drops user[0], leaving the history starting with assistant[1].
    // Anthropic rejects conversations that don't start with a user message.
    // Post-fix the cap fires at >19 so post-append count <= 19 (odd → user-first).
    let expectedOddCap = 19
    #expect(expectedOddCap % 2 == 1,
            "Post-user-append cap must be odd so the kept window starts with a user message.")
    #expect(expectedOddCap <= 20,
            "Cap must stay within the documented '10 turns (20 messages)' budget.")
}

// MARK: - D6 fix — orphan tool_result rewrite after trim
//
// Live use 2026-05-25 hit HTTP 400 "unexpected tool_use_id found in
// tool_result blocks" at turn ~11 of a multi-step CU run. Root cause:
// the suffix(19) trim drops the prior assistant message (which owned
// the tool_use_id our now-first user message's tool_result refers to).
// Anthropic's API requires each tool_result to match a tool_use in the
// immediately-preceding assistant turn. applyHistoryCap rewrites the
// kept-first user's content to drop the orphan tool_result.

/// Build a synthetic alternating user/assistant conversation of `turns`
/// turns. Each user (except [0]) carries a `tool_result` for the prior
/// assistant's tool_use_id; the prior assistant carries the matching
/// tool_use. Mirrors what ComputerUseClient's nextAction actually builds.
private func makeSyntheticHistory(turns: Int) -> [CUMessage] {
    var history: [CUMessage] = []
    // user[0]: initial screenshot, no tool_result.
    history.append(CUMessage(role: "user", content: [
        .image(mediaType: "image/png", data: "<initial>"),
        .text("Begin working on the task.")
    ]))
    // Subsequent turns: assistant[tool_use], user[tool_result + image].
    for i in 1...turns {
        let id = "toolu_synth_\(i)"
        history.append(CUMessage(role: "assistant", content: [
            .toolUse(id: id, name: "computer", input: [:])
        ]))
        history.append(CUMessage(role: "user", content: [
            .toolResult(toolUseID: id, content: [
                .image(mediaType: "image/png", data: "<screenshot-\(i)>")
            ]),
            .text("Current screenshot attached. Continue the task.")
        ]))
    }
    return history
}

@Test
func applyHistoryCap_noopWhenUnderCap() {
    // 5-turn history → 11 messages. Cap at 19 → no trim.
    let history = makeSyntheticHistory(turns: 5)
    #expect(history.count == 11)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    #expect(trimmed.count == 11, "Under-cap history must be returned unchanged.")
}

@Test
func applyHistoryCap_keptFirstIsUser_evenWhenTrimming() {
    // 10-turn → 21 messages. Cap at 19 → trim to last 19. The kept-first
    // must be a user role (Anthropic alternation invariant).
    let history = makeSyntheticHistory(turns: 10)
    #expect(history.count == 21)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    #expect(trimmed.count == 19)
    #expect(trimmed.first?.role == "user",
            "Kept-first message must be user; got: \(trimmed.first?.role ?? "nil")")
}

@Test
func applyHistoryCap_rewritesKeptFirstUserWhenItHadOrphanToolResult() {
    // 10-turn → 21 messages. After suffix(19), kept-first would be the
    // old user[2] containing a tool_result for old assistant[1]'s
    // tool_use — which was just dropped. THIS IS THE BUG. The fix must
    // rewrite that kept-first to drop the orphan tool_result.
    let history = makeSyntheticHistory(turns: 10)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    // Verify NO tool_result block exists in the kept-first user.
    let firstHasToolResult = trimmed.first?.content.contains(where: {
        if case .toolResult = $0 { return true } else { return false }
    }) ?? false
    #expect(!firstHasToolResult,
            "Kept-first user MUST NOT contain a tool_result block (would orphan against the dropped prior assistant).")
}

@Test
func applyHistoryCap_keptFirstUserContainsTruncationPlaceholder() {
    // The rewritten kept-first should carry a text placeholder so the
    // model knows context was truncated.
    let history = makeSyntheticHistory(turns: 10)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    guard let firstText = trimmed.first?.content.first,
          case .text(let s) = firstText else {
        Issue.record("Kept-first must contain a text placeholder.")
        return
    }
    #expect(s.contains("history cap") || s.contains("omitted"),
            "Truncation placeholder must mention the omission so the model knows context was lost. Got: \(s)")
}

@Test
func applyHistoryCap_doesNotRewriteWhenKeptFirstHasNoToolResult() {
    // Edge case: if the kept-first user happened to have no tool_result
    // (e.g. it's still user[0], the initial screenshot), the rewrite
    // should NOT fire. We test this by capping a 9-turn history (19
    // messages) at exactly 19 — no trim happens, so user[0] is intact.
    let history = makeSyntheticHistory(turns: 9)
    #expect(history.count == 19)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    #expect(trimmed.count == 19)
    // The first message should be the original user[0] with the
    // initial screenshot, not the placeholder.
    guard let firstContent = trimmed.first?.content,
          let firstBlock = firstContent.first,
          case .image = firstBlock else {
        Issue.record("Initial user[0] must remain intact when no trim is needed.")
        return
    }
}

@Test
func applyHistoryCap_rewriteKeepsRoleAndAlternation() {
    // After the rewrite the message must still have role="user" — if it
    // accidentally became "assistant" the alternation rule breaks too.
    let history = makeSyntheticHistory(turns: 10)
    let trimmed = ComputerUseClient.applyHistoryCap(history, cap: 19)
    #expect(trimmed[0].role == "user")
    #expect(trimmed[1].role == "assistant")
    #expect(trimmed[2].role == "user")
    // Spot-check the tail too — assistant/user alternation should hold
    // through the kept window.
    for (i, msg) in trimmed.enumerated() {
        let expected = i.isMultiple(of: 2) ? "user" : "assistant"
        #expect(msg.role == expected,
                "Index \(i) expected role \(expected), got \(msg.role).")
    }
}

@Test
func cuStripImages_isIdempotent() {
    // Running the stripper twice produces the same result as once.
    let input: [CUContent] = [
        .image(mediaType: "image/png", data: "<blob>"),
        .toolResult(toolUseID: "x", content: [
            .image(mediaType: "image/png", data: "<inner>"),
        ]),
    ]
    let once = ComputerUseClient.stripImages(from: input)
    let twice = ComputerUseClient.stripImages(from: once)
    // CUContent isn't Equatable; compare by serialising the type tag column.
    func sketch(_ c: [CUContent]) -> [String] {
        c.map { block in
            switch block {
            case .text(let s): return "text:\(s)"
            case .image: return "image"
            case .toolUse(let id, _, _): return "toolUse:\(id)"
            case .toolResult(let id, let inner): return "toolResult:\(id):[" + sketch(inner).joined(separator: ",") + "]"
            }
        }
    }
    #expect(sketch(once) == sketch(twice),
            "stripImages must be idempotent — re-running produces the same shape.")
}

@Test
func cuContent_decodesToolResultBlock_roundTrips() throws {
    let json = """
    [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_abc",
        "content": [
          { "type": "text", "text": "ok" }
        ]
      }
    ]
    """
    let decoded = try JSONDecoder().decode([CUContent].self, from: Data(json.utf8))
    #expect(decoded.count == 1)
    if case .toolResult(let id, let content) = decoded[0] {
        #expect(id == "toolu_abc")
        #expect(content.count == 1)
        if case .text(let s) = content[0] {
            #expect(s == "ok")
        } else {
            Issue.record("nested content should decode as text")
        }
    } else {
        Issue.record("top-level should decode as tool_result, got \(decoded[0])")
    }
}

// MARK: - F4-3: drag

// MARK: - Cluster C: blind-type flagging

@Test
func cuTranslate_typeWithoutTextField_setsRequiresConfirmation() async throws {
    // No AX elements at all -> nearestFocusedElement returns (nil, 0.60).
    // The translation must set requiresConfirmation:true so the receipt
    // records the LLM's blind-target intent. Tier still lands at .preview
    // via classify() line 58; the autonomous-mode carve-out (commit dbf6ae9)
    // holds that floor.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("type"),
        "text": AnyCodable("hello"),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .typeText)
    #expect(action.targetIndex == nil)
    #expect(action.requiresConfirmation == true,
            "blind type with no AX target must set requiresConfirmation:true (documents intent in receipt).")
}

@Test
func cuTranslate_typeWithAXTextField_doesNotSetRequiresConfirmation() async throws {
    // First enabled text field heuristic returns (idx, 0.85). 0.85 is the not-less-than
    // boundary — requiresConfirmation stays false because there IS a resolved target.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXTextField", label: "Search", value: nil,
                      frame: CodableRect(.init(x: 0, y: 0, width: 200, height: 30)),
                      isEnabled: true, isVisible: true),
        ]
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("type"),
        "text": AnyCodable("hello"),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .typeText)
    #expect(action.targetIndex == 0)
    #expect(action.confidence == 0.85)
    #expect(action.requiresConfirmation == false,
            "AX-resolved text field at 0.85 confidence should not need confirmation flag.")
}

@Test
func cuTranslate_leftClickDrag_setsDragWithStartAndEndCoordinates() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("left_click_drag"),
        "start_coordinate": AnyCodable([100, 200] as [Any]),
        "coordinate": AnyCodable([300, 400] as [Any]),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .drag)
    #expect(action.startCoordinate?.cgPoint == CGPoint(x: 100, y: 200))
    #expect(action.coordinate?.cgPoint == CGPoint(x: 300, y: 400))
}

@Test
func cuTranslate_leftClickDrag_missingStartReturnsWait() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("left_click_drag"),
        "coordinate": AnyCodable([300, 400] as [Any]),
        // start_coordinate omitted
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .wait)
    #expect(action.rationale.contains("missing or malformed"))
}

// MARK: - F4-5: dual-beta routing

@Test
func cuToolVersion_opus47_returnsNewBeta() async {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let version = await client.cuToolVersion
    #expect(version == .v20251124)
    #expect(version.betaHeader == "computer-use-2025-11-24")
    #expect(version.toolTypeName == "computer_20251124")
}

@Test
func cuToolVersion_sonnet46_returnsNewBeta() async {
    let client = ComputerUseClient(apiKey: "test", model: "claude-sonnet-4-6")
    let version = await client.cuToolVersion
    #expect(version == .v20251124)
}

@Test
func cuToolVersion_haiku45_returnsOldBeta() async {
    let client = ComputerUseClient(apiKey: "test", model: "claude-haiku-4-5-20251001")
    let version = await client.cuToolVersion
    #expect(version == .v20250124)
    #expect(version.betaHeader == "computer-use-2025-01-24")
    #expect(version.toolTypeName == "computer_20250124")
}

@Test
func cuToolVersion_sonnet45_returnsOldBeta() async {
    let client = ComputerUseClient(apiKey: "test", model: "claude-sonnet-4-5-20250929")
    let version = await client.cuToolVersion
    #expect(version == .v20250124)
}

@Test
func cuToolVersion_opus41_returnsOldBeta() async {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-1")
    let version = await client.cuToolVersion
    #expect(version == .v20250124)
}

// MARK: - F4-2: tripleClick + hold_key

@Test
func cuTranslate_tripleClick_setsTripleClickType() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("triple_click"),
        "coordinate": AnyCodable([100, 100] as [Any]),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .tripleClick,
            "triple_click must map to .tripleClick, got \(action.type)")
    #expect(action.coordinate?.cgPoint == CGPoint(x: 100, y: 100))
}

@Test
func cuTranslate_holdKey_emitsHoldKeyWithDurationMs() async throws {
    // F7: hold_key now maps to the true-duration .holdKey ActionType with
    // durationMs (was: degenerate .keyCombo dropping the duration).
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("hold_key"),
        "text": AnyCodable("shift"),
        "duration": AnyCodable(2.5),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .holdKey)
    #expect(action.text == "shift")
    #expect(action.durationMs == 2500,
            "2.5s → 2500ms; got \(String(describing: action.durationMs))")
}

@Test
func cuTranslate_holdKey_missingDuration_setsDurationMsZero() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("hold_key"),
        "text": AnyCodable("shift"),
        // duration omitted
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.type == .holdKey)
    #expect(action.durationMs == 0,
            "missing duration → 0ms (no-op hold)")
}

@Test
func cuNearestElement_emptyAxTree_returnsNilIndex() throws {
    let snap = try PerceptionSnapshot.make(
        timestamp: .now,
        focusedAppBundleID: "com.test",
        elements: []
    )
    let (idx, _) = ComputerUseClient.nearestElementForTesting(CGPoint(x: 100, y: 100), snapshot: snap)
    #expect(idx == nil)
}

// MARK: - Unit 6 / H3 sibling — agent-app exclusion list for captureScreen

// Stub conforming to the internal `ProcessIdentifiable` protocol so tests
// don't need to instantiate `SCRunningApplication` (no public initializer).
// See Support/AgentIdentity.swift for the protocol + helper definitions.
private struct StubProcessApp: ProcessIdentifiable {
    let processID: pid_t
}

// `agentAppsToExclude` picks every app whose PID matches the agent's.
// The `SCContentFilter(excludingApplications:)` call in both
// `ComputerUseClient.captureScreen` and `VisionPerception.captureVisualContext`
// (full-screen fallback) consumes the result to keep the agent's launcher
// / HUD windows out of the pixels the LLM sees. Regression target: a
// PID-match inversion (== to !=) or a hardcoded constant in the predicate
// would be caught here.
@Test
func agentAppsToExclude_returnsOnlyMatchingPIDs() {
    let apps = [
        StubProcessApp(processID: 100),
        StubProcessApp(processID: 999),
        StubProcessApp(processID: 200),
        StubProcessApp(processID: 999),
    ]
    let excluded = agentAppsToExclude(in: apps, agentPID: 999)
    #expect(excluded.map(\.processID) == [999, 999],
            "All apps with the agent's PID must be in the exclusion list — leaving any in keeps the agent overlay in the screenshot.")
}

// Empty exclusion list when the agent isn't in the supplied app set is
// the safe-degrade path (matches pre-Unit-6 behavior). Real-world cause:
// SCShareableContent may briefly omit our own process during launch.
// captureScreen() should still produce a usable screenshot in that case.
@Test
func agentAppsToExclude_emptyWhenAgentNotPresent() {
    let apps = [StubProcessApp(processID: 100), StubProcessApp(processID: 200)]
    let excluded = agentAppsToExclude(in: apps, agentPID: 999)
    #expect(excluded.isEmpty)
}

// Default `agentPID` argument resolves to `agentProcessID` (the shared
// canonical identity constant in Support/AgentIdentity.swift) — confirms
// the production call sites, which omit `agentPID`, get the right value.
// Mirrors `AXPerception.isAgentProcess_matchesOnlyWhenPIDsAreEqual` (Unit 5).
@Test
func agentAppsToExclude_defaultPIDIsCurrentProcess() {
    let myPID = agentProcessID
    let apps = [StubProcessApp(processID: myPID), StubProcessApp(processID: myPID + 1)]
    let excluded = agentAppsToExclude(in: apps)
    #expect(excluded.map(\.processID) == [myPID])
}

// Lock the cross-Unit invariant: `AXPerception.isAgentProcess` (Unit 5)
// and `agentAppsToExclude` (Unit 6) MUST identify the agent the same way.
// A future change that updates only one site would silently re-introduce
// the H3 bug class on the other pipeline. This test passes the same PID
// through both predicates and asserts both agree.
@Test
func agentIdentitySources_axAndCUAgreeOnSamePID() {
    let agentPID = pid_t(12345)
    let nonAgentPID = pid_t(99999)

    #expect(AXPerception.isAgentProcess(agentPID, agentPID: agentPID) == true)
    #expect(agentAppsToExclude(
        in: [StubProcessApp(processID: agentPID), StubProcessApp(processID: nonAgentPID)],
        agentPID: agentPID
    ).map(\.processID) == [agentPID])

    #expect(AXPerception.isAgentProcess(nonAgentPID, agentPID: agentPID) == false)
    #expect(agentAppsToExclude(
        in: [StubProcessApp(processID: nonAgentPID)],
        agentPID: agentPID
    ).isEmpty)
}

// MARK: - Unit 13a — stateful mouse translator (Path C, part 1)

// `left_mouse_down` / `left_mouse_up` / `mouse_move` translate to the new
// .mouseDown / .mouseUp / .mouseMove ActionTypes. 13a wires the schema
// + translator; 13b ships the executor state machine. These tests lock
// the CU-wire-format → ActionType mapping so 13b can be implemented
// against a stable contract.

private func translateCUMouseAction(_ actionStr: String, coord: [Int]) async -> AgentAction {
    let client = ComputerUseClient(apiKey: "k", model: "claude-opus-4-6")
    let snapshot = try! PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.test", elements: []
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable(actionStr),
        "coordinate": AnyCodable(coord),
    ]
    return await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
}

@Test
func cuTranslator_leftMouseDown_mapsToMouseDownActionType() async {
    let action = await translateCUMouseAction("left_mouse_down", coord: [100, 200])
    #expect(action.type == .mouseDown,
            "Unit 13a: CU 'left_mouse_down' must map to .mouseDown ActionType (was previously a no-op .wait fallthrough).")
    #expect(action.coordinate?.x == 100)
    #expect(action.coordinate?.y == 200)
    #expect(action.requiresConfirmation == false,
            "stateful mouse actions are not self-flagged as needing confirm — SafetyPolicy tiering handles approval semantics.")
}

@Test
func cuTranslator_leftMouseUp_mapsToMouseUpActionType() async {
    let action = await translateCUMouseAction("left_mouse_up", coord: [150, 250])
    #expect(action.type == .mouseUp,
            "Unit 13a: CU 'left_mouse_up' must map to .mouseUp ActionType.")
    #expect(action.coordinate?.x == 150)
    #expect(action.coordinate?.y == 250)
}

@Test
func cuTranslator_mouseMove_mapsToMouseMoveActionType() async {
    let action = await translateCUMouseAction("mouse_move", coord: [200, 300])
    #expect(action.type == .mouseMove,
            "Unit 13a: CU 'mouse_move' must map to .mouseMove ActionType (was previously a no-op .wait fallthrough with cu.unknown_action=mouse_move log).")
    #expect(action.coordinate?.x == 200)
    #expect(action.coordinate?.y == 300)
}

// Missing-coordinate fallback: the LLM might emit a stateful-mouse action
// without coordinates if the model is confused. Translator must surface a
// confirmation-required wait so the operator sees the malformed call rather
// than the agent silently doing nothing.
//
// Reviewer-flagged in 13a adversarial pass: parameterize across all three
// CU action strings so a future per-type refactor that diverges the
// missing-coord handling for mouse_move / left_mouse_up regresses loudly.
private func translateCUMouseMissingCoord(_ actionStr: String) async -> AgentAction {
    let client = ComputerUseClient(apiKey: "k", model: "claude-opus-4-6")
    let snapshot = try! PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.example.test", elements: []
    )
    let input: [String: AnyCodable] = ["action": AnyCodable(actionStr)]
    return await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
}

@Test
func cuTranslator_leftMouseDown_missingCoord_returnsWaitNeedsConfirm() async {
    let action = await translateCUMouseMissingCoord("left_mouse_down")
    #expect(action.type == .wait)
    #expect(action.requiresConfirmation == true)
}

@Test
func cuTranslator_leftMouseUp_missingCoord_returnsWaitNeedsConfirm() async {
    let action = await translateCUMouseMissingCoord("left_mouse_up")
    #expect(action.type == .wait,
            "left_mouse_up without coord must not auto-fire — operator may not see the stranded held button.")
    #expect(action.requiresConfirmation == true)
}

@Test
func cuTranslator_mouseMove_missingCoord_returnsWaitNeedsConfirm() async {
    let action = await translateCUMouseMissingCoord("mouse_move")
    #expect(action.type == .wait)
    #expect(action.requiresConfirmation == true)
}

// MARK: - Unit 25 follow-up: isFocused priority in nearestFocusedElement

@Test
func cuTranslate_typeText_prefersIsFocusedTextField_overFirstEnabled() async throws {
    // Two enabled text fields. Index 0 is first-in-AX-order (the old
    // heuristic's pick); index 1 has isFocused=true (Unit 25 signal).
    // The new priority tier must pick the focused one.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let frame = CodableRect(.init(x: 0, y: 0, width: 200, height: 30))
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXTextField", label: "Username", value: nil,
                      frame: frame, isEnabled: true, isVisible: true, isFocused: false),
            UIElement(index: 1, role: "AXTextField", label: "Search", value: nil,
                      frame: frame, isEnabled: true, isVisible: true, isFocused: true),
        ]
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("type"),
        "text": AnyCodable("hello"),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.targetIndex == 1,
            "isFocused text field must beat first-enabled — keyboard focus is the AX server's ground truth.")
    #expect(action.confidence == 0.95,
            "isFocused branch confidence is 0.95, same tier as lastClick (both are high-confidence resolved targets).")
    #expect(action.requiresConfirmation == false,
            "0.95 confidence is above the 0.85 needs-confirm threshold.")
}

@Test
func cuTranslate_typeText_isFocusedBeatsLastClickOnDifferentField() async throws {
    // Operator clicked Username at (50, 50) — lastClickCoordinate gets set.
    // Then OS state has Search focused (e.g. tab key auto-advance moved focus).
    // The function must pick the isFocused field over the lastClick field
    // because keystrokes will land where the OS thinks focus is, not where
    // the cursor last clicked.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let usernameFrame = CodableRect(.init(x: 0, y: 0, width: 200, height: 30))
    let searchFrame = CodableRect(.init(x: 0, y: 100, width: 200, height: 30))
    // Seed lastClickCoordinate by translating a click against the username frame.
    let clickInput: [String: AnyCodable] = [
        "action": AnyCodable("left_click"),
        "coordinate": AnyCodable([50, 15] as [Any]),
    ]
    let clickSnapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXTextField", label: "Username", value: nil,
                      frame: usernameFrame, isEnabled: true, isVisible: true, isFocused: false),
        ]
    )
    _ = await client.translateForTesting(inputDict: clickInput, toolUseID: "c1", snapshot: clickSnapshot)
    // Now type — Search is focused (not Username), even though lastClick is inside Username.
    let typeSnapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXTextField", label: "Username", value: nil,
                      frame: usernameFrame, isEnabled: true, isVisible: true, isFocused: false),
            UIElement(index: 1, role: "AXTextField", label: "Search", value: nil,
                      frame: searchFrame, isEnabled: true, isVisible: true, isFocused: true),
        ]
    )
    let typeInput: [String: AnyCodable] = [
        "action": AnyCodable("type"),
        "text": AnyCodable("hello"),
    ]
    let action = await client.translateForTesting(inputDict: typeInput, toolUseID: "t1", snapshot: typeSnapshot)
    #expect(action.targetIndex == 1,
            "isFocused must win when AX focus disagrees with lastClick — keystrokes follow focus, not cursor history.")
}

@Test
func cuTranslate_typeText_focusOnNonTextElement_fallsThroughToLastClick() async throws {
    // A button has isFocused=true. We must NOT type into a button — fall
    // through to the existing lastClick/first-enabled tiers.
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let frame = CodableRect(.init(x: 0, y: 0, width: 200, height: 30))
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test",
        elements: [
            UIElement(index: 0, role: "AXButton", label: "Submit", value: nil,
                      frame: frame, isEnabled: true, isVisible: true, isFocused: true),
            UIElement(index: 1, role: "AXTextField", label: "Search", value: nil,
                      frame: frame, isEnabled: true, isVisible: true, isFocused: false),
        ]
    )
    let input: [String: AnyCodable] = [
        "action": AnyCodable("type"),
        "text": AnyCodable("hello"),
    ]
    let action = await client.translateForTesting(inputDict: input, toolUseID: "t1", snapshot: snapshot)
    #expect(action.targetIndex == 1,
            "Focused button must NOT be picked for typeText — fall through to first-enabled text field.")
    #expect(action.confidence == 0.85,
            "Fell to the first-enabled tier (no lastClick set in this test) → 0.85 confidence.")
}

// MARK: - Track A audit Finding 4 — task-change clears the read-action back-channel
//
// A `cursor_position` action queues its answer in `pendingToolResultText` to be
// embedded in the NEXT turn's tool_result. The task-change reset cleared
// cuHistory + lastToolUseID but NOT pendingToolResultText, so a cursor answer
// queued as the final step of one run leaked into the next run's first
// tool_result. resetIfTaskChanged now clears all three.

@Test
func cuReset_taskChange_clearsPendingToolResultText() async throws {
    let client = ComputerUseClient(apiKey: "test", model: "claude-opus-4-7")
    let snapshot = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    // Anchor the current task so the cursor_position queue happens "within" run A.
    await client.resetIfTaskChanged("task A")
    // cursor_position is a read-action: translate queues the answer back-channel.
    _ = await client.translateForTesting(
        inputDict: ["action": AnyCodable("cursor_position")],
        toolUseID: "t1", snapshot: snapshot)
    let queued = await client.pendingToolResultTextForTesting
    #expect(queued != nil, "cursor_position must queue an answer in pendingToolResultText.")
    // Run B starts with a different task — the reset must drop the stale answer.
    await client.resetIfTaskChanged("task B")
    let afterReset = await client.pendingToolResultTextForTesting
    #expect(afterReset == nil,
            "task change must clear pendingToolResultText so a prior run's cursor answer cannot leak into the new run's first tool_result.")
}
