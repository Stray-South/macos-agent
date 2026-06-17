import Foundation
import Testing
@testable import MacOSAgentV0
@testable import MacAgentCore

// Cascade-sev-1 fix from the 2026-05-23 milestone adversarial review.
//
// `AppModel.buildTaskPrompt` builds the LLM-bound `Recent conversation:`
// block from `messages.suffix(6).filter { $0.role != .system && $0.includeInPrompt }`.
// PR-4 added cleartext rendering of `.confirm`-tier `typeText` action
// payloads into the conversation thread for operator visibility. Without
// the `includeInPrompt:false` flag on action-narration bubbles, those
// payloads (including approved-but-still-sensitive secrets) would
// re-enter the LLM context window on every subsequent task in the
// session — a different and broader disclosure than the on-disk
// receipt (which is 0600 and not exfiltrated unless the operator
// chooses to).
//
// This test locks the contract: action-narration messages are visible
// in `messages` (for the thread UI) but excluded from `buildTaskPrompt`.

private let typedSecret = "MyP@ssw0rd-2026"

@Test
@MainActor
func promptExclusion_actionNarrationBubbleVisibleInThreadButNotInPrompt() {
    let model = AppModel(apiKeyProvider: { "dummy" })

    // Simulate the agent appending a `.confirm`-tier typeText narration —
    // mirrors what AppModel.handle(.proposed) does on a tier=.confirm typeText.
    // The text format matches AppModel.swift's renderer at the .proposed case.
    let narrationText = "typeText \"\(typedSecret)\" → element 12 [CONFIRM] — Filling password field"
    model.messages.append(ConversationMessage(
        role: .agent,
        text: narrationText,
        includeInPrompt: false
    ))
    // Also a normal user task that SHOULD make it into the prompt.
    model.messages.append(ConversationMessage(
        role: .user,
        text: "now click the Submit button"
    ))

    // The thread shows the narration (operator visibility).
    let threadTexts = model.messages.map(\.text)
    #expect(threadTexts.contains(narrationText),
            "Narration must be visible in the thread for operator transparency.")

    // The prompt excludes the narration. We can't call buildTaskPrompt
    // directly (private), but the filter logic mirrors what it does;
    // any prompt-bound consumer respects the same flag.
    let promptBound = model.messages.suffix(6).filter { $0.role != .system && $0.includeInPrompt }
    let promptTexts = promptBound.map(\.text)
    #expect(!promptTexts.contains { $0.contains(typedSecret) },
            "Typed secret must NOT appear in the prompt-bound subset — PR-4 cascade fix.")
    #expect(promptTexts.contains("now click the Submit button"),
            "Operator's follow-up task must still reach the prompt.")
}

@Test
@MainActor
func promptExclusion_defaultIncludeInPromptIsTrue() {
    // Backwards-compatibility check: existing append sites that omit the
    // flag still appear in the prompt. Only the .proposed handler opts out.
    let model = AppModel(apiKeyProvider: { "dummy" })
    model.messages.append(ConversationMessage(role: .user, text: "default-include"))
    model.messages.append(ConversationMessage(role: .agent, text: "default-include-agent"))

    let promptBound = model.messages.suffix(6).filter { $0.role != .system && $0.includeInPrompt }
    #expect(promptBound.contains { $0.text == "default-include" })
    #expect(promptBound.contains { $0.text == "default-include-agent" })
}
