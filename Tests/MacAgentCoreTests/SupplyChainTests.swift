/// SupplyChainTests.swift
/// Supply-chain and schema integrity tests.
///
/// K — Model-string invariants: default models must be known-good strings, never blank or unknown.
/// L — Receipt schema: ActionLogEntry JSON must contain all required audit fields.
///
/// These tests protect against silent regressions caused by config drift, merge conflicts,
/// or an upstream model rename that leaves the agent talking to a non-existent endpoint.
import Foundation
@testable import MacAgentCore
import Testing

// MARK: - K: Model-string invariants

/// The action-LLM models the agent is allowed to use. Must match
/// AgentModel.all in SettingsView. 2026-05-23 audit removed Haiku 4.5
/// after live-tested all 6 Lane 1 tasks regressed to a click-only loop
/// under the custom multi-tool schema.
private let knownActionModels: Set<String> = [
    "claude-opus-4-6",
    "claude-sonnet-4-6",
]

/// The planner-LLM models the agent is allowed to use. Planner is hardcoded
/// to Haiku in `ClaudeTaskPlanner.init`; the single-tool planning prompt is
/// well within Haiku's capability.
private let knownPlannerModels: Set<String> = [
    "claude-haiku-4-5-20251001",
]

/// The Computer Use models the agent is allowed to use. Must match
/// ComputerUseModel.all in SettingsView. Dual-beta support (J-2):
/// - New beta (`computer-use-2025-11-24`): Opus 4.7, Opus 4.6, Sonnet 4.6.
/// - Old beta (`computer-use-2025-01-24`): Sonnet 4.5, Haiku 4.5, Opus 4.1.
/// Unversioned `claude-sonnet-4` and `claude-opus-4` excluded — both retire
/// 2026-06-15 per Anthropic's deprecation list. ComputerUseClient.cuToolVersion
/// dispatches per model.
private let knownComputerUseModels: Set<String> = [
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-sonnet-4-6",
    "claude-sonnet-4-5-20250929",
    "claude-haiku-4-5-20251001",
    "claude-opus-4-1",
]

// K.1 — ClaudeLLMClient default model is a known valid action model ID
@Test
func llmClientDefaultModelIsValid() throws {
    // Passing a dummy key so the init doesn't throw LLMError.missingAPIKey.
    // We're only checking the model string, not making network calls.
    let client = try ClaudeLLMClient(apiKey: "dummy-key-for-unit-test")
    #expect(knownActionModels.contains(client.model),
            "ClaudeLLMClient default model '\(client.model)' must be a known valid action model ID.")
    #expect(!client.model.isEmpty,
            "ClaudeLLMClient default model must not be empty.")
    // Belt-and-suspenders: Haiku is excluded from the action whitelist as of
    // 2026-05-23 — if a future change re-introduces it here, fail loudly.
    #expect(!client.model.hasPrefix("claude-haiku"),
            "Haiku family must not be the action-LLM default — see 2026-05-23 audit.")
}

// K.2 — Package.swift declares zero external dependencies (zero-deps architecture)
@Test
func packageHasZeroExternalDependencies() throws {
    // Navigate from this test file up to the package root (3 directories up).
    let thisFile = URL(fileURLWithPath: #filePath)
    let packageRoot = thisFile
        .deletingLastPathComponent()  // SupplyChainTests.swift → MacAgentCoreTests/
        .deletingLastPathComponent()  // MacAgentCoreTests/ → Tests/
        .deletingLastPathComponent()  // Tests/ → package root
    let packageSwift = packageRoot.appendingPathComponent("Package.swift")
    let content = try String(contentsOf: packageSwift, encoding: .utf8)
    // The zero-deps invariant: the top-level `dependencies` array must be empty.
    // "dependencies: []" is the canonical form used in this project.
    #expect(content.contains("dependencies: []"),
            "Package.swift must declare zero external dependencies — no third-party libraries.")
}

// K.3 — ClaudeTaskPlanner default model is a known valid planner model ID
@Test
func taskPlannerDefaultModelIsValid() {
    let planner = ClaudeTaskPlanner(apiKey: "dummy-key-for-unit-test")
    #expect(knownPlannerModels.contains(planner.model),
            "ClaudeTaskPlanner default model '\(planner.model)' must be a known valid planner model ID.")
    #expect(!planner.model.isEmpty,
            "ClaudeTaskPlanner default model must not be empty.")
    // Planner intentionally uses Haiku (fast + cheap) — regression guard.
    #expect(planner.model.hasPrefix("claude-haiku"),
            "ClaudeTaskPlanner must use a Haiku model — cost/speed invariant. Got: \(planner.model)")
}

// K.4 — ComputerUseClient accepts every model in the CU whitelist.
// Structural store check only — does not verify the model ID appears in the
// outgoing HTTP request body. A rename of the actor's `model` field would
// break this test, but a regression that drops the field from the request
// builder would not. Live-API coverage requires the smoke harness.
@Test
func computerUseClientAcceptsKnownComputerUseModels() async throws {
    for id in knownComputerUseModels {
        let client = ComputerUseClient(apiKey: "dummy-key-for-unit-test", model: id)
        let storedModel = await client.modelForTesting
        #expect(storedModel == id,
                "ComputerUseClient must store the model id it was constructed with. Expected \(id), got \(storedModel).")
    }
}

// K.5 — Action-model picker source-of-truth must not contain Haiku.
// SupplyChainTests can't import the MacOSAgentV0 target (it's the app
// shell, not a library), so verify by reading SettingsView.swift directly.
// The source-string check is intentional — a future "while I was here"
// re-introduction of Haiku to AgentModel.all would slip past
// llmClientDefaultModelIsValid (which only checks the default) without
// this guard.
@Test
func actionModelWhitelistExcludesHaiku() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let packageRoot = thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let settingsView = packageRoot
        .appendingPathComponent("Sources/MacOSAgentV0/SettingsView.swift")
    let src = try String(contentsOf: settingsView, encoding: .utf8)

    // Locate the AgentModel.all block (delimited by `static let all` and the
    // closing `]`). Restrict the substring check to that block so unrelated
    // mentions of "claude-haiku" elsewhere in the file (comments, the CU
    // whitelist) don't false-positive.
    guard let allStart = src.range(of: "static let all: [AgentModel] = ["),
          let allEnd = src.range(of: "]", range: allStart.upperBound..<src.endIndex) else {
        Issue.record("Could not locate AgentModel.all block in SettingsView.swift")
        return
    }
    let block = src[allStart.upperBound..<allEnd.lowerBound]
    #expect(!block.contains("claude-haiku"),
            "AgentModel.all must not contain any claude-haiku model — see 2026-05-23 audit.")
}

// MARK: - M: AuDHD confirmation-affordance invariants

// Package-root lookup helper shared by the M tests.
private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

// M.1 — Exactly one PulsingDot definition exists in the codebase.
// AGENTS.md §AuDHD-First Defaults allows a single named confirmation
// affordance. The 2026-05-23 audit found a SECOND PulsingDot in
// LauncherView.swift that lacked the reduceMotion guard — extraction
// to a shared component (PulsingDot.swift) plus this lint prevents the
// regression class.
@Test
func onlyOnePulsingDotDefinitionExists() throws {
    let sourcesRoot = packageRoot().appendingPathComponent("Sources")
    let enumerator = FileManager.default.enumerator(at: sourcesRoot,
                                                     includingPropertiesForKeys: nil)!
    var hits: [String] = []
    for case let url as URL in enumerator
        where url.pathExtension == "swift" {
        let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // `\b` word boundary after `PulsingDot` so `PulsingDotPro` /
        // `PulsingDotSmall` etc. don't false-positive into the "extra
        // definition" count. PR-4 adversarial sev-3 fix.
        if src.range(of: #"struct\s+PulsingDot\b\s*:"#, options: .regularExpression) != nil {
            hits.append(url.lastPathComponent)
        }
    }
    #expect(hits.count == 1,
            "Exactly one `struct PulsingDot:` must exist in Sources/. Found: \(hits)")
    #expect(hits.first == "PulsingDot.swift",
            "The single PulsingDot definition must live at Sources/MacAgentCore/Overlay/PulsingDot.swift")
}

// M.2 — Confirmation affordances all reference reduceMotion.
// Every site that creates a transient overlay MUST honor system
// reduceMotion. Grep-style guard; if a future regression re-introduces
// the pattern this test screams.
@Test
func confirmationAffordancesAllRespectReduceMotion() throws {
    let candidates: [String] = [
        "Sources/MacAgentCore/Overlay/PulsingDot.swift",
        "Sources/MacAgentCore/Overlay/CursorFeedbackController.swift",
    ]
    for relative in candidates {
        let url = packageRoot().appendingPathComponent(relative)
        let src = try String(contentsOf: url, encoding: .utf8)
        let mentionsReduceMotion = src.contains("reduceMotion")
            || src.contains("accessibilityDisplayShouldReduceMotion")
        #expect(mentionsReduceMotion,
                "\(relative) must reference reduceMotion — confirmation affordances must respect AuDHD opt-out (AGENTS.md §AuDHD-First Defaults).")
    }
}

// M.3 — KeystrokeOverlayController has been deleted.
// The third confirmation affordance was removed 2026-05-23; its text
// payload now renders in the conversation thread. If a future change
// re-introduces a KeystrokeOverlayController (or any other
// auto-dismiss toast for typed-text feedback), this test fires.
@Test
func keystrokeOverlayControllerDeleted() {
    let url = packageRoot()
        .appendingPathComponent("Sources/MacAgentCore/Overlay/KeystrokeOverlayController.swift")
    #expect(!FileManager.default.fileExists(atPath: url.path),
            "KeystrokeOverlayController.swift was removed PR-4 — see AGENTS.md §AuDHD carve-out. If re-adding a keystroke surface, update the carve-out first.")
}

// MARK: - L: Receipt schema

// L.1 — ActionLogEntry JSON contains all required audit fields
@Test
func actionLogEntrySchemaIsComplete() throws {
    let sampleAction = AgentAction(
        type: .click, targetIndex: 0, text: nil,
        confidence: 0.9, requiresConfirmation: false, rationale: "schema test"
    )
    let entry = ActionLogEntry(
        action: sampleAction,
        tier: "preview",
        approved: true,
        executionResult: "clicked element",
        durationMs: 142,
        snapshotHash: "abc123"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    let requiredFields = [
        "id", "timestamp", "action", "tier", "approved",
        "executionResult", "durationMs", "snapshotHash",
    ]
    for field in requiredFields {
        #expect(json[field] != nil,
                "Receipt JSON must contain required field '\(field)'.")
    }
    // Validate types for the fields most likely to drift
    #expect(json["approved"] is Bool, "Receipt 'approved' field must be a Bool.")
    #expect(json["durationMs"] is Int || json["durationMs"] is NSNumber,
            "Receipt 'durationMs' field must be a numeric type.")
    #expect(json["action"] is [String: Any],
            "Receipt 'action' field must be a JSON object (the full AgentAction struct).")
}

// L.1b — AgentAction's optional schema-bump fields (modifiers, startCoordinate,
// coordinate) appear in the receipt JSON when non-nil. Guards against a Codable
// CodingKey accidentally being omitted for a new optional field, which would
// silently drop the field from receipts without the L.1 type-set check noticing.
@Test
func actionLogEntryEncodesOptionalSchemaBumpFields() throws {
    let dragAction = AgentAction(
        type: .drag,
        confidence: 0.9,
        requiresConfirmation: false,
        rationale: "drag for text selection with shift",
        coordinate: CodablePoint(.init(x: 300, y: 400)),
        modifiers: "shift",
        startCoordinate: CodablePoint(.init(x: 100, y: 200))
    )
    let entry = ActionLogEntry(
        action: dragAction,
        tier: "preview",
        approved: true,
        executionResult: "dragged",
        durationMs: 234,
        snapshotHash: "abc123"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let actionJSON = json["action"] as! [String: Any]
    #expect(actionJSON["modifiers"] != nil,
            "modifiers must encode into receipt JSON when set; missing CodingKey would silently drop it")
    #expect(actionJSON["startCoordinate"] != nil,
            "startCoordinate must encode into receipt JSON when set")
    #expect(actionJSON["coordinate"] != nil,
            "coordinate must encode into receipt JSON when set")
    #expect(actionJSON["type"] as? String == "drag",
            "ActionType .drag must encode as raw-string 'drag'")

    // Roundtrip: re-encode the action sub-object and decode back to AgentAction.
    // Guards against a future `decodeIfPresent` removal on any of the optional
    // fields — encode side would stay green but decode side would silently drop
    // the value to nil. The roundtrip catches that.
    let actionData = try JSONSerialization.data(withJSONObject: actionJSON)
    let decoded = try JSONDecoder().decode(AgentAction.self, from: actionData)
    #expect(decoded.modifiers == "shift",
            "modifiers must survive decode roundtrip — missing decodeIfPresent would set to nil")
    #expect(decoded.startCoordinate?.cgPoint == CGPoint(x: 100, y: 200),
            "startCoordinate must survive decode roundtrip")
    #expect(decoded.coordinate?.cgPoint == CGPoint(x: 300, y: 400),
            "coordinate must survive decode roundtrip")
    #expect(decoded.type == .drag,
            ".drag ActionType must survive decode roundtrip")
}

// L.1c — holdKey + durationMs round-trip through ActionLogEntry.
@Test
func actionLogEntryEncodesHoldKeyWithDurationMs() throws {
    let holdAction = AgentAction(
        type: .holdKey, text: "shift", confidence: 0.95,
        requiresConfirmation: false, rationale: "hold shift 2s",
        durationMs: 2000
    )
    let entry = ActionLogEntry(
        action: holdAction, tier: "preview", approved: true,
        executionResult: "held key", durationMs: 2010, snapshotHash: "abc"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let actionJSON = json["action"] as! [String: Any]
    #expect(actionJSON["type"] as? String == "holdKey")
    #expect(actionJSON["durationMs"] as? Int == 2000)
    // Decode roundtrip
    let actionData = try JSONSerialization.data(withJSONObject: actionJSON)
    let decoded = try JSONDecoder().decode(AgentAction.self, from: actionData)
    #expect(decoded.type == .holdKey)
    #expect(decoded.durationMs == 2000)
    #expect(decoded.text == "shift")
}

// L.2 — ReceiptWriter produces valid JSONL (one JSON object per line, no blank lines)
@Test
func receiptWriterProducesValidJSONL() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let count = 4
    for i in 0..<count {
        let entry = ActionLogEntry(
            action: AgentAction(
                type: .click, targetIndex: i, text: nil,
                confidence: 0.9, requiresConfirmation: false, rationale: "step \(i)"
            ),
            tier: "auto", approved: true,
            executionResult: "clicked", durationMs: i * 10, snapshotHash: "hash\(i)"
        )
        try await writer.write(entry)
    }

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    #expect(files.count == 1, "ReceiptWriter must write a single JSONL file per day.")
    let content = try String(contentsOf: files[0])
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == count,
            "JSONL file must have exactly \(count) lines — one JSON object per receipt entry.")
    for (i, line) in lines.enumerated() {
        let decoded = try decoder.decode(ActionLogEntry.self, from: Data(line.utf8))
        #expect(decoded.approved == true,
                "Line \(i) must decode cleanly and match original 'approved' value.")
        #expect(decoded.durationMs == i * 10,
                "Line \(i) must decode cleanly and match original 'durationMs' value.")
    }
}

// MARK: - M: Info.plist ↔ agentBundleID drift guard (Unit 11)

/// Unit 11 — defense against silent drift between `App/Info.plist`'s
/// CFBundleIdentifier and the hardcoded fallback string in 11 source/test
/// sites (most importantly `AgentIdentity.swift:agentBundleID`).
///
/// Production: `Bundle.main.bundleIdentifier` reads from Info.plist at
/// runtime → matches whatever CFBundleIdentifier is set to.
///
/// Tests / smoke targets: `Bundle.main` is the xctest harness or the
/// smoke binary; `bundleIdentifier` does NOT match the agent's Info.plist.
/// All 11 fallback sites use `?? "com.southernreach.macos-agent-v0"` to
/// land on the production string.
///
/// Failure mode this test catches: a future rebrand changes Info.plist
/// CFBundleIdentifier without updating the 11 hardcoded fallbacks.
/// Production runs correctly; tests + non-app contexts silently use the
/// stale string. The TCC self-exclusion guards (Unit 5/10) compare
/// `info.bundleID == agentBundleID` — a stale `agentBundleID` would
/// silently miss agent's-own-tree detection.
@Test
func infoPlist_CFBundleIdentifier_matchesHardcodedFallback() throws {
    // Locate App/Info.plist relative to this test file.
    let here = URL(fileURLWithPath: #filePath)
    // Tests/MacAgentCoreTests/SupplyChainTests.swift → <repo root>/App/Info.plist
    let plistURL = here
        .deletingLastPathComponent()  // Tests/MacAgentCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // <repo root>/
        .appendingPathComponent("App/Info.plist")

    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    guard let dict = plist as? [String: Any] else {
        Issue.record("App/Info.plist must decode as a top-level dictionary")
        return
    }
    guard let bundleIDFromPlist = dict["CFBundleIdentifier"] as? String else {
        Issue.record("App/Info.plist must contain CFBundleIdentifier")
        return
    }

    // Lock the canonical string. Unit 5/10's PID-based agent identity is
    // robust against bundle-ID drift, but the cold-start prompt directive
    // (Unit 10), the Executor self-switch guard (Unit 10), and the
    // menuSelect agent-guard (Unit 11) all key off `agentBundleID` which
    // falls through to this hardcoded value in non-app contexts.
    let hardcodedFallback = "com.southernreach.macos-agent-v0"
    #expect(bundleIDFromPlist == hardcodedFallback,
            "Info.plist CFBundleIdentifier (\(bundleIDFromPlist)) must match the hardcoded fallback (\(hardcodedFallback)) used in AgentIdentity.swift + 10 other source/test sites. A drift here means non-app contexts silently use the stale ID.")

    // Sanity: in the test environment (xctest harness), Bundle.main IS
    // the harness, so agentBundleID lands on the hardcoded fallback —
    // which now equals Info.plist. Lock that invariant explicitly.
    #expect(agentBundleID == hardcodedFallback,
            "agentBundleID (\(agentBundleID)) in test context must equal the hardcoded fallback.")
}

// MARK: - N: Production factories on Support/ types (Unit 11)

@Test
func receiptWriter_productionFactory_constructsSuccessfully() {
    let _: ReceiptWriter = ReceiptWriter.production()
}

@Test
func throughlineStore_productionFactory_constructsSuccessfully() {
    let _: ThroughlineStore = ThroughlineStore.production()
}

// MARK: - O: ActionLogEntry append-only schema growth — heldMouseAtStart (Unit 13a)

// Unit 13a adds an OPTIONAL `heldMouseAtStart: Bool?` field. Append-only
// invariant: old receipts (no field) decode unchanged → nil; new
// receipts encode with `false` or `true` and round-trip. If a future
// PR ever removes this field or makes it non-optional, this test
// catches it — same defense as the K-series model-string invariants.

@Test
func actionLogEntry_heldMouseAtStart_isOptionalAndDefaultsToNil() {
    let action = AgentAction(type: .click, confidence: 0.9,
                             requiresConfirmation: false, rationale: "t")
    let entry = ActionLogEntry(
        action: action, tier: "auto", approved: true,
        executionResult: "clicked", durationMs: 5, snapshotHash: "x"
    )
    #expect(entry.heldMouseAtStart == nil,
            "Unit 13a: heldMouseAtStart defaults to nil when omitted — old code paths construct entries without the new field.")
}

@Test
func actionLogEntry_heldMouseAtStart_codableRoundTrip_preservesValue() throws {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let action = AgentAction(type: .mouseDown, confidence: 0.9,
                             requiresConfirmation: false, rationale: "t")
    let original = ActionLogEntry(
        action: action, tier: "preview", approved: true,
        executionResult: "stub", durationMs: 1, snapshotHash: "x",
        heldMouseAtStart: true
    )
    let data = try enc.encode(original)
    let decoded = try dec.decode(ActionLogEntry.self, from: data)
    #expect(decoded.heldMouseAtStart == true,
            "Codable round-trip must preserve heldMouseAtStart so the receipt audit trail works.")
}

// Old-format receipts (pre-13a) JSON has no `heldMouseAtStart` key. Synthesize
// such JSON and confirm it decodes to nil rather than throwing — append-only
// invariant.
@Test
func actionLogEntry_decodesOldReceiptsWithoutHeldMouseField() throws {
    // Synthesize a receipt that lacks heldMouseAtStart (pre-13a shape).
    let json = """
    {
      "id": "\(UUID().uuidString)",
      "timestamp": "2026-05-26T12:00:00Z",
      "action": {
        "type": "click",
        "confidence": 0.9,
        "requiresConfirmation": false,
        "rationale": "old receipt"
      },
      "tier": "auto",
      "approved": true,
      "executionResult": "clicked",
      "durationMs": 5,
      "snapshotHash": "abc123"
    }
    """
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let decoded = try dec.decode(ActionLogEntry.self, from: Data(json.utf8))
    #expect(decoded.heldMouseAtStart == nil,
            "Append-only invariant: receipts written before Unit 13a (no heldMouseAtStart field) MUST decode to nil rather than throw.")
}
