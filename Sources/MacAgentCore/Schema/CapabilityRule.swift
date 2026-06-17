import Foundation

/// A user-defined rule that adjusts whether an action type is auto-approved, requires
/// confirmation, or is refused — scoped to an optional app and/or label pattern.
///
/// Rules layer between AutonomyMode and the gate step (Option C placement).
/// SafetyPolicy remains the hard floor: no rule can widen a destructive/sensitive action.
public struct CapabilityRule: Codable, Sendable, Identifiable, Equatable {

    // MARK: - Verdict

    public enum Verdict: String, Codable, Sendable {
        /// Auto-execute if SafetyPolicy permits (non-destructive/non-sensitive actions only).
        case allow
        /// Force at least .preview confirmation — surfaced in HUD but can auto-pass in autonomous mode.
        case ask
        /// Refuse the action — treated as a rejected CONFIRM tier, writes rejection receipt.
        case deny
    }

    // MARK: - Fields

    public let id: UUID
    public let verdict: Verdict
    /// nil = matches any action type.
    public let actionType: ActionType?
    /// nil = matches any app.
    public let appBundleID: String?
    /// Glob-style pattern matched against the action's target element label (case-insensitive).
    /// Supports '*' wildcard. nil = matches any label.
    public let labelPattern: String?
    public let createdAt: Date
    public var lastTriggered: Date?
    public var triggerCount: Int

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        verdict: Verdict,
        actionType: ActionType? = nil,
        appBundleID: String? = nil,
        labelPattern: String? = nil,
        createdAt: Date = Date(),
        lastTriggered: Date? = nil,
        triggerCount: Int = 0
    ) {
        self.id = id
        self.verdict = verdict
        self.actionType = actionType
        self.appBundleID = appBundleID
        self.labelPattern = labelPattern
        self.createdAt = createdAt
        self.lastTriggered = lastTriggered
        self.triggerCount = triggerCount
    }

    // MARK: - Matching

    /// True when this rule applies to the given action in the given snapshot context.
    public func matches(_ action: AgentAction, _ snapshot: PerceptionSnapshot) -> Bool {
        if let requiredType = actionType, action.type != requiredType { return false }
        if let requiredBundle = appBundleID,
           snapshot.focusedAppBundleID != requiredBundle { return false }
        if let pattern = labelPattern {
            let label = resolvedLabel(action, snapshot)
            if !CapabilityRule.globMatches(pattern: pattern.lowercased(), input: label.lowercased()) { return false }
        }
        return true
    }

    /// Extracts the target element's label for pattern matching, or "" if none available.
    private func resolvedLabel(_ action: AgentAction, _ snapshot: PerceptionSnapshot) -> String {
        guard let idx = action.targetIndex, idx >= 0 else { return action.text ?? "" }
        if idx < snapshot.visionIndexOffset {
            guard idx < snapshot.elements.count else { return "" }
            return snapshot.elements[idx].label
        } else {
            let vIdx = idx - snapshot.visionIndexOffset
            guard vIdx < snapshot.visionObservations.count else { return "" }
            return snapshot.visionObservations[vIdx].text
        }
    }

    /// Simple glob matching: '*' matches any sequence of characters, '?' matches one character.
    /// Implemented iteratively to avoid regex overhead.
    static func globMatches(pattern: String, input: String) -> Bool {
        var pIdx = pattern.startIndex
        var iIdx = input.startIndex
        var starPIdx = pattern.startIndex
        var starIIdx = input.startIndex
        var hasStar = false

        while iIdx < input.endIndex {
            if pIdx < pattern.endIndex {
                let pc = pattern[pIdx]
                if pc == "*" {
                    hasStar = true
                    starPIdx = pIdx
                    starIIdx = iIdx
                    pIdx = pattern.index(after: pIdx)
                    continue
                }
                if pc == "?" || pc == input[iIdx] {
                    pIdx = pattern.index(after: pIdx)
                    iIdx = input.index(after: iIdx)
                    continue
                }
            }
            guard hasStar else { return false }
            pIdx = pattern.index(after: starPIdx)
            starIIdx = input.index(after: starIIdx)
            iIdx = starIIdx
        }
        while pIdx < pattern.endIndex, pattern[pIdx] == "*" {
            pIdx = pattern.index(after: pIdx)
        }
        return pIdx == pattern.endIndex
    }

    // MARK: - Human description

    /// Plain-language summary for the Settings panel.
    public var humanDescription: String {
        var parts: [String] = []
        parts.append(verdict.rawValue.uppercased())
        if let t = actionType { parts.append(t.rawValue) } else { parts.append("any action") }
        if let p = labelPattern { parts.append("matching \"\(p)\"") }
        if let b = appBundleID {
            let name = b.split(separator: ".").last.map(String.init) ?? b
            parts.append("in \(name)")
        }
        return parts.joined(separator: " · ")
    }
}
