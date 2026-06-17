import Foundation

public struct ActionLogEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: AgentAction
    public let tier: String
    public let approved: Bool
    public let executionResult: String
    public let durationMs: Int
    public let snapshotHash: String
    /// Unit 13a — stateful-mouse audit flag. True when a `.mouseDown`
    /// was active at the moment this action was classified. Lets a
    /// post-hoc receipt audit explain why an otherwise-safe action was
    /// tiered to `.confirm` during a held-mouse run (13b's held-mouse
    /// invariant). Optional/nullable so old receipts decode unchanged
    /// — append-only per CLAUDE.md hard rule. Defaults to `false` /
    /// missing on the 13a build because no executor state machine
    /// yet exists; 13b's executor sets it from `MouseHoldState`.
    public let heldMouseAtStart: Bool?
    /// H1 — closed-loop outcome verification. After a verifiable action
    /// executes, the orchestrator re-perceives and checks whether the
    /// action's intended post-condition holds. Tri-state: `true` = verified,
    /// `false` = checked and the post-condition did NOT hold (likely a no-op),
    /// `nil` = not checked (unverifiable type, AX-blind screen, or a pre-H1
    /// receipt). Diagnostic only — it drives no gating. Optional so old
    /// receipts decode unchanged (append-only per CLAUDE.md).
    public let outcomeVerified: Bool?
    /// Human-readable reason for `outcomeVerified`. Never contains typed text.
    public let outcomeDetail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        action: AgentAction,
        tier: String,
        approved: Bool,
        executionResult: String,
        durationMs: Int,
        snapshotHash: String,
        heldMouseAtStart: Bool? = nil,
        outcomeVerified: Bool? = nil,
        outcomeDetail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.tier = tier
        self.approved = approved
        self.executionResult = executionResult
        self.durationMs = durationMs
        self.snapshotHash = snapshotHash
        self.heldMouseAtStart = heldMouseAtStart
        self.outcomeVerified = outcomeVerified
        self.outcomeDetail = outcomeDetail
    }
}
