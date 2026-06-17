import Testing
@testable import MacOSAgentV0

// Unit 34 — chat-first transcript folding. The simple interface folds
// consecutive .activity messages into one expandable group; .chat messages
// (conversation, questions, approvals, outcomes) always render individually.
@Suite struct TranscriptBuilderTests {
    private func msg(_ text: String, kind: ConversationMessage.Kind) -> ConversationMessage {
        ConversationMessage(role: .agent, text: text, kind: kind)
    }

    @Test func foldsConsecutiveActivityIntoOneGroup() {
        let items = TranscriptBuilder.fold([
            msg("you: do the thing", kind: .chat),
            msg("click [3]", kind: .activity),
            msg("clicked", kind: .activity),
            msg("typeText", kind: .activity),
            msg("Agent says: done with step one", kind: .chat),
        ], detailed: false)
        #expect(items.count == 3, "chat + one folded group + chat")
        guard case .activityGroup(let group) = items[1] else {
            Issue.record("middle item must be the folded activity group")
            return
        }
        #expect(group.count == 3)
    }

    @Test func chatMessagesNeverFold() {
        let items = TranscriptBuilder.fold([
            msg("❓ Question for you", kind: .chat),
            msg("Waiting for confirm approval", kind: .chat),
            msg("Task stopped safely", kind: .chat),
        ], detailed: false)
        #expect(items.count == 3)
        #expect(items.allSatisfy { if case .message = $0 { return true }; return false },
                "safety-relevant chat messages must render individually, never folded")
    }

    @Test func detailedModeRendersEverythingInline() {
        let items = TranscriptBuilder.fold([
            msg("a", kind: .activity),
            msg("b", kind: .activity),
        ], detailed: true)
        #expect(items.count == 2)
        #expect(items.allSatisfy { if case .message = $0 { return true }; return false },
                "detailed mode folds nothing")
    }

    @Test func trailingActivityRunFolds() {
        let items = TranscriptBuilder.fold([
            msg("start", kind: .chat),
            msg("step", kind: .activity),
            msg("step", kind: .activity),
        ], detailed: false)
        #expect(items.count == 2)
        guard case .activityGroup(let group) = items[1] else {
            Issue.record("trailing activity must fold")
            return
        }
        #expect(group.count == 2)
    }
}

extension TranscriptBuilderTests {
    // 34a — a trailing activity group's identity must be STABLE as new
    // activity extends it, or SwiftUI loses the row (and its expansion
    // state) on every appended step.
    @Test func groupIdentityStableAcrossGrowth() {
        let a = ConversationMessage(role: .agent, text: "step 1", kind: .activity)
        let before = TranscriptBuilder.fold([a], detailed: false)
        let b = ConversationMessage(role: .agent, text: "step 2", kind: .activity)
        let after = TranscriptBuilder.fold([a, b], detailed: false)
        #expect(before.first?.id == after.first?.id,
                "group id is the first message's id — growth must not change it")
    }
}
