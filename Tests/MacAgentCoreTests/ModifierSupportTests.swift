/// ModifierSupportTests.swift
///
/// Coverage for `AgentAction.modifiers` (new optional field) and the
/// Executor + ComputerUseClient surfaces that read it.
///
/// Per CLAUDE.md "ActionLogEntry schema is append-only": this test pins
/// the receipt-decode behavior where old receipts (without `modifiers`)
/// decode cleanly (decodeIfPresent → nil) and new receipts include the
/// field when set.
import Foundation
@testable import MacAgentCore
import Testing

@Test
func agentAction_decodesWithoutModifiers_returnsNilField() throws {
    // Old-shape JSON (no `modifiers` key) — append-only safety check.
    let json = """
    {
      "type": "click",
      "targetIndex": 3,
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "click button"
    }
    """
    let action = try JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    #expect(action.type == .click)
    #expect(action.modifiers == nil)
}

@Test
func agentAction_decodesWithModifiers_setsField() throws {
    let json = """
    {
      "type": "click",
      "targetIndex": 3,
      "modifiers": "shift",
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "shift-click for selection extend"
    }
    """
    let action = try JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    #expect(action.modifiers == "shift")
}

@Test
func agentAction_decodesNullModifiers_returnsNilField() throws {
    // Anthropic schema declares `modifiers` as ["string", "null"] — null must be
    // accepted and decode to nil so the type=keyCombo / wait / etc. paths work
    // when Claude declares the required key but no modifier applies.
    let json = """
    {
      "type": "keyCombo",
      "targetIndex": null,
      "modifiers": null,
      "text": "cmd+s",
      "confidence": 0.95,
      "requiresConfirmation": false,
      "rationale": "save"
    }
    """
    let action = try JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    #expect(action.modifiers == nil)
}

@Test
func agentAction_modifiersField_capsAt64Chars() throws {
    let oversize = String(repeating: "x", count: 200)
    let json = """
    {
      "type": "click",
      "targetIndex": 0,
      "modifiers": "\(oversize)",
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "test"
    }
    """
    let action = try JSONDecoder().decode(AgentAction.self, from: Data(json.utf8))
    #expect(action.modifiers?.count == 64,
            "modifiers field must be capped to prevent LLM-bloat exhausting receipts")
}

@Test
func agentAction_initDefaultsModifiersToNil() {
    // Old call sites (84 in test suite per audit) must keep compiling. The new
    // `modifiers:` parameter has a default value, making the schema bump
    // source-compatible.
    let action = AgentAction(
        type: .click,
        targetIndex: 0,
        confidence: 0.9,
        requiresConfirmation: false,
        rationale: "test"
    )
    #expect(action.modifiers == nil)
}

@Test
func agentAction_decodesDurationMs_andCapsAt30k() throws {
    // F7 schema bump: durationMs is decodeIfPresent with a 30_000ms cap so a
    // hallucinated huge value can't lock the executor.
    let normal = """
    {
      "type": "holdKey",
      "targetIndex": null,
      "text": "shift",
      "durationMs": 2500,
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "hold shift"
    }
    """
    let n = try JSONDecoder().decode(AgentAction.self, from: Data(normal.utf8))
    #expect(n.type == .holdKey)
    #expect(n.durationMs == 2500)

    let huge = """
    {
      "type": "holdKey",
      "durationMs": 99999999,
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "hold forever"
    }
    """
    let h = try JSONDecoder().decode(AgentAction.self, from: Data(huge.utf8))
    #expect(h.durationMs == 30_000,
            "hallucinated huge durationMs must clamp to 30_000ms")

    let negative = """
    {
      "type": "holdKey",
      "durationMs": -5,
      "confidence": 0.9,
      "requiresConfirmation": false,
      "rationale": "negative"
    }
    """
    let neg = try JSONDecoder().decode(AgentAction.self, from: Data(negative.utf8))
    #expect(neg.durationMs == 0, "negative durationMs clamps to 0")
}

@Test
func agentAction_holdKeyRoundTripPreservesDurationMs() throws {
    let original = AgentAction(
        type: .holdKey, text: "shift", confidence: 0.95,
        requiresConfirmation: false, rationale: "hold shift 2s",
        durationMs: 2000
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AgentAction.self, from: encoded)
    #expect(decoded.durationMs == 2000)
    #expect(decoded == original)
}

@Test
func agentAction_roundTripCodableWithModifiers() throws {
    let original = AgentAction(
        type: .click,
        targetIndex: 5,
        confidence: 0.92,
        requiresConfirmation: false,
        rationale: "cmd-shift-click",
        modifiers: "cmd+shift"
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AgentAction.self, from: encoded)
    #expect(decoded.modifiers == "cmd+shift")
    #expect(decoded == original)
}
