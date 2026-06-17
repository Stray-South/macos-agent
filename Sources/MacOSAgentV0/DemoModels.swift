import Foundation

struct DemoPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let task: String
    let supportedApp: String  // human-readable display label
    let bundleID: String      // app bundle ID used for launch and frontmost-app validation

    static let presets: [DemoPreset] = [
        DemoPreset(
            id: "notes-new-note",
            title: "New Note",
            subtitle: "Golden path",
            task: "In Notes, create a new note and stop when the editor is focused.",
            supportedApp: "Notes",
            bundleID: "com.apple.Notes"
        ),
        DemoPreset(
            id: "finder-continue",
            title: "Click Continue",
            subtitle: "Single-step safe action",
            task: "Click the Continue button if it is available, otherwise clarify what is missing.",
            supportedApp: "Finder",
            bundleID: "com.apple.finder"
        ),
        DemoPreset(
            id: "safari-search",
            title: "Focus Search",
            subtitle: "Typed interaction",
            task: "In Safari, focus the search field and stop before typing anything destructive.",
            supportedApp: "Safari",
            bundleID: "com.apple.Safari"
        ),
    ]
}

enum RunOutcome: Equatable {
    case idle
    case success(String)
    case failure(String)
    case needsVerification(String)
}

struct ReceiptSummary: Equatable {
    let fileURL: URL
    let headline: String
    let updatedAt: Date
}

struct ActionPreview: Equatable {
    let typeLabel: String
    let targetLabel: String
    let rationale: String
    let tierLabel: String
}

enum LiveActivityState: Equatable {
    case idle
    case observing
    case deciding
    case waitingApproval(String)
    case executing
    case clarifying

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .observing: return "Observing the current app"
        case .deciding: return "Deciding the next safest step"
        case .waitingApproval(let tier): return "Waiting for \(tier) approval"
        case .executing: return "Executing approved action"
        case .clarifying: return "Waiting for your clarification"
        }
    }
}

struct ConversationMessage: Identifiable, Equatable {
    /// Unit 34 — chat-first transcript. `.chat` is conversation (you, agent
    /// speech, questions, approvals, outcomes); `.activity` is machinery
    /// (action narrations, execution results, app switches) that the simple
    /// interface folds into expandable step groups, like a thinking
    /// disclosure. Safety-relevant messages are ALWAYS `.chat`: approval
    /// prompts, questions, warnings, and failures may never be folded away.
    enum Kind {
        case chat
        case activity
    }

    enum Role {
        case user
        case agent
        case system
        /// Unit 33a — model-authored speech (the `say` action). A DISTINCT
        /// role so spoken text can never render identically to app-authored
        /// .agent lines ("Task finished.", execution results): the model
        /// controls the words but not the bubble identity. Spoof-resistance
        /// is structural, not cosmetic — a prompt-injected say cannot
        /// impersonate system truth or a real clarify template.
        case agentSpeech
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
    /// When true, `AppModel.buildTaskPrompt` excludes this message from the
    /// `Recent conversation:` block sent to the LLM. Used for agent-internal
    /// action narrations (proposed-action bubbles): the operator sees them
    /// in the thread, but they aren't conversational context the next LLM
    /// call needs — and they may carry `.typeText` payloads which would
    /// otherwise be re-sent to Anthropic on every subsequent task in the
    /// session. PR-4 cumulative adversarial review (sev-1 cascade finding).
    let includeInPrompt: Bool
    let kind: Kind

    init(role: Role, text: String, timestamp: Date = .now, includeInPrompt: Bool = true, kind: Kind = .chat) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.includeInPrompt = includeInPrompt
        self.kind = kind
    }
}

/// Unit 34 — folds a transcript for the simple interface: consecutive
/// `.activity` messages collapse into one expandable group; `.chat`
/// messages always render individually. Pure function for testability.
enum TranscriptBuilder {
    enum Item: Identifiable, Equatable {
        case message(ConversationMessage)
        case activityGroup([ConversationMessage])

        private static let emptyGroupID = UUID()

        var id: UUID {
            switch self {
            case .message(let m): return m.id
            // Fallback is a STABLE sentinel — a fresh UUID per access would
            // break Identifiable. Unreachable today: fold never emits empty
            // groups.
            case .activityGroup(let group): return group.first?.id ?? Self.emptyGroupID
            }
        }
    }

    static func fold(_ messages: [ConversationMessage], detailed: Bool) -> [Item] {
        guard !detailed else { return messages.map { .message($0) } }
        var items: [Item] = []
        var pendingActivity: [ConversationMessage] = []
        for message in messages {
            if message.kind == .activity {
                pendingActivity.append(message)
            } else {
                if !pendingActivity.isEmpty {
                    items.append(.activityGroup(pendingActivity))
                    pendingActivity = []
                }
                items.append(.message(message))
            }
        }
        if !pendingActivity.isEmpty {
            items.append(.activityGroup(pendingActivity))
        }
        return items
    }
}
