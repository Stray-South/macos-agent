/// LLMClientDecodeTests.swift
///
/// Decoder regression tests for `ClaudeLLMClient.decodeAgentAction(fromMessagesResponse:)`.
///
/// The AgentAction tool schema declares `targetIndex` as `["integer", "null"]` AND lists
/// it in `required` (LLMClient.swift:386-411). The system prompt explicitly instructs
/// Claude to pass null for keyCombo/wait/complete/clarify/switchApp/undo (line 226), so
/// the response decoder MUST handle JSON null inside the tool_use input dictionary.
///
/// Before the fix, `AnyDecodable.init` had no `decodeNil()` branch and every null-bearing
/// response threw `dataCorrupted("Unsupported JSON value")`, which surfaced as
/// `LLMError.malformedResponse` and broke the smoke binary plus any clarify/complete/
/// switchApp flow in the main app.
import Foundation
@testable import MacAgentCore
import Testing

private func messagesResponse(input: String) -> Data {
    Data("""
    {
      "id": "msg_test",
      "type": "message",
      "role": "assistant",
      "content": [
        {
          "type": "tool_use",
          "id": "toolu_test",
          "name": "AgentAction",
          "input": \(input)
        }
      ]
    }
    """.utf8)
}

@Test
func agentActionResponseWithNullTargetIndexDecodes() throws {
    let data = messagesResponse(input: """
        {
          "type": "clarify",
          "targetIndex": null,
          "confidence": 0.95,
          "requiresConfirmation": false,
          "rationale": "Need user input."
        }
        """)
    let action = try ClaudeLLMClient.decodeAgentAction(fromMessagesResponse: data)
    #expect(action.type == .clarify)
    #expect(action.targetIndex == nil)
    #expect(action.confidence == 0.95)
}

@Test
func agentActionResponseWithIntegerTargetIndexStillDecodes() throws {
    let data = messagesResponse(input: """
        {
          "type": "click",
          "targetIndex": 7,
          "confidence": 0.9,
          "requiresConfirmation": false,
          "rationale": "Click the New Note button."
        }
        """)
    let action = try ClaudeLLMClient.decodeAgentAction(fromMessagesResponse: data)
    #expect(action.type == .click)
    #expect(action.targetIndex == 7)
}

@Test
func agentActionResponseWithSwitchAppAndNullTargetIndexDecodes() throws {
    let data = messagesResponse(input: """
        {
          "type": "switchApp",
          "targetIndex": null,
          "text": "com.apple.Notes",
          "confidence": 1.0,
          "requiresConfirmation": false,
          "rationale": "Switch to Notes."
        }
        """)
    let action = try ClaudeLLMClient.decodeAgentAction(fromMessagesResponse: data)
    #expect(action.type == .switchApp)
    #expect(action.targetIndex == nil)
    #expect(action.text == "com.apple.Notes")
}

// The extracted decode helper makes the no-tool-use guard path testable. Claude
// occasionally returns a text-only content block when its tool_use is rejected
// upstream (e.g. content-policy hits); the guard at LLMClient.swift must throw
// LLMError.malformedResponse rather than crash or return a default action.
@Test
func messagesResponseWithoutToolUseBlockThrowsMalformedResponse() throws {
    let data = Data("""
        {
          "id": "msg_test",
          "type": "message",
          "role": "assistant",
          "content": [
            {
              "type": "text",
              "text": "I cannot perform this action."
            }
          ]
        }
        """.utf8)
    do {
        _ = try ClaudeLLMClient.decodeAgentAction(fromMessagesResponse: data)
        Issue.record("expected LLMError.malformedResponse but decode returned normally")
    } catch LLMError.malformedResponse {
        // expected
    } catch {
        Issue.record("expected LLMError.malformedResponse but got \(error)")
    }
}
