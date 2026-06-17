import Foundation
import Testing
@testable import MacOSAgentV0
@testable import MacAgentCore

// MARK: - In-window approval surface
//
// LauncherView's approval card calls AppModel.approve/alwaysAllow/reject/neverAllow.
// These must:
//  1. Set `pendingApprovalAction` on `.proposed` events when tier != .auto.
//  2. NOT set `pendingApprovalAction` on `.proposed` with tier == .auto.
//  3. Clear `pendingApprovalAction` and dispatch through the overlay when called.
//  4. No-op when called with no pending action (idempotent re-click).

@MainActor
private func makeAppModel() -> AppModel {
    AppModel(apiKeyProvider: { "dummy" })
}

private func makeAction() -> AgentAction {
    AgentAction(
        type: .click,
        targetIndex: 0,
        confidence: 0.9,
        requiresConfirmation: false,
        rationale: "test click"
    )
}

@MainActor @Test
func proposedEventWithPreviewTierMirrorsPendingApprovalAction() {
    let model = makeAppModel()
    let action = makeAction()
    model.handle(event:.proposed(action: action, tier: .preview))
    #expect(model.pendingApprovalAction != nil,
            "pendingApprovalAction must be set on .proposed when tier ≠ .auto")
    #expect(model.pendingApprovalAction?.type == .click)
}

@MainActor @Test
func proposedEventWithAutoTierDoesNotSetPendingApproval() {
    let model = makeAppModel()
    let action = makeAction()
    model.handle(event:.proposed(action: action, tier: .auto))
    #expect(model.pendingApprovalAction == nil,
            "auto-tier actions must not surface the in-window approval card")
}

@MainActor @Test
func proposedEventWithConfirmTierMirrorsPendingApprovalAction() {
    let model = makeAppModel()
    let action = makeAction()
    model.handle(event:.proposed(action: action, tier: .confirm))
    #expect(model.pendingApprovalAction != nil,
            ".confirm tier must surface the approval card")
}

@MainActor @Test
func approveClearsPendingApprovalAction() {
    let model = makeAppModel()
    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    #expect(model.pendingApprovalAction != nil, "preconditions: pending action set")
    model.approve()
    #expect(model.pendingApprovalAction == nil,
            "approve() must clear the mirror so the card disappears")
}

@MainActor @Test
func rejectClearsPendingApprovalAction() {
    let model = makeAppModel()
    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.reject()
    #expect(model.pendingApprovalAction == nil)
}

@MainActor @Test
func alwaysAllowAndNeverAllowClearPendingApprovalAction() {
    let model = makeAppModel()
    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.alwaysAllow()
    #expect(model.pendingApprovalAction == nil, "alwaysAllow must clear the mirror")

    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.neverAllow()
    #expect(model.pendingApprovalAction == nil, "neverAllow must clear the mirror")
}

@MainActor @Test
func approveWithNoPendingActionIsNoOp() {
    let model = makeAppModel()
    #expect(model.pendingApprovalAction == nil, "preconditions: no pending action")
    // Should not crash, not append a bubble, not throw.
    let beforeCount = model.messages.count
    model.approve()
    model.reject()
    model.alwaysAllow()
    model.neverAllow()
    #expect(model.pendingApprovalAction == nil)
    #expect(model.messages.count == beforeCount,
            "approval methods with no pending action must not append conversation messages")
}

// Guards against a regression where dispatchApproval drops its guard and
// invokes overlay.applyDecision on a nil continuation. The spy never receives
// any call when no pending action exists.
@MainActor @Test
func approveWithNoPendingActionDoesNotDispatchToOverlay() {
    let spy = SpyOverlay()
    let model = AppModel(apiKeyProvider: { "dummy" }, overlayForTesting: spy)
    #expect(model.pendingApprovalAction == nil)
    model.approve()
    model.reject()
    model.alwaysAllow()
    model.neverAllow()
    #expect(spy.decisions.isEmpty,
            "overlay.applyDecision must NOT be called when no action is pending; received \(spy.decisions)")
}

@MainActor @Test
func approveWithPendingActionDispatchesToOverlay() {
    let spy = SpyOverlay()
    let model = AppModel(apiKeyProvider: { "dummy" }, overlayForTesting: spy)
    model.handle(event: .proposed(action: makeAction(), tier: .preview))
    model.approve()
    #expect(spy.decisions == [.approveOnce],
            "approve() must dispatch exactly one .approveOnce to the overlay")
}

// MARK: - Spy

@MainActor
private final class SpyOverlay: OverlayControlling, @unchecked Sendable {
    var decisions: [ApprovalDecision] = []
    func highlight(frame: CGRect) {}
    func clearHighlight() {}
    func setPendingAction(_ action: AgentAction, completion: @escaping (ApprovalDecision) -> Void) {}
    func updateStatus(task: String, tier: SafetyTier, isRunning: Bool) {}
    func setAbortHandler(_ handler: @escaping @Sendable () -> Void) {}
    func applyDecision(_ decision: ApprovalDecision) {
        decisions.append(decision)
    }
}

@MainActor @Test
func recoveringEventClearsPendingApprovalAction() {
    // R5 audit: .recovering was the one mid-run event that left the approval
    // mirror set, so a failed-and-retried step kept the LauncherView card bound
    // to the failed action. Now clears on .recovering.
    let model = makeAppModel()
    model.handle(event: .proposed(action: makeAction(), tier: .preview))
    #expect(model.pendingApprovalAction != nil, "preconditions: pending action set")
    model.handle(event: .recovering(message: "transient failure"))
    #expect(model.pendingApprovalAction == nil,
            ".recovering must clear the approval mirror")
}

@MainActor @Test
func terminalEventsClearPendingApprovalAction() {
    // .finished, .failed, .stepLimitReached, .executionFinished all clear the mirror
    // so the card disappears when the run ends — verified individually.
    let model = makeAppModel()

    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.handle(event:.finished)
    #expect(model.pendingApprovalAction == nil, ".finished must clear")

    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.handle(event:.failed(message: "test"))
    #expect(model.pendingApprovalAction == nil, ".failed must clear")

    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.handle(event:.stepLimitReached(stepCount: 50))
    #expect(model.pendingApprovalAction == nil, ".stepLimitReached must clear")

    model.handle(event:.proposed(action: makeAction(), tier: .preview))
    model.handle(event:.executionFinished(result: "clicked"))
    #expect(model.pendingApprovalAction == nil, ".executionFinished must clear")
}
