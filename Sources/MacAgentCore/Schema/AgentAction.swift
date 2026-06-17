import CoreGraphics
import Foundation

public enum ActionType: String, Codable, Sendable {
    case click
    case doubleClick
    case tripleClick
    case rightClick
    case typeText
    case scroll
    case keyCombo
    case menuSelect
    case wait
    case undo
    case complete
    case clarify
    /// Unit 35 — read the user's clipboard text into the agent's context.
    /// Floors at .preview (the operator sees the card before it fires) and
    /// autonomous mode does NOT widen it: clipboard content leaves the
    /// machine (it is sent to the model API), which is a privacy boundary,
    /// not a UI action. Content is capped before entering history; replay
    /// redacts the receipt's executionResult unless --show-text.
    case readClipboard
    /// Unit 36 — write text to a file inside the opt-in agent workspace
    /// (`~/Library/Application Support/MacAgent/workspace/`). `filePath` is
    /// the workspace-RELATIVE path; `text` is the contents (≤2000 chars).
    /// ALWAYS .confirm; never auto, never widened by autonomy; alwaysAllow is
    /// forbidden. Disabled unless the operator enables the workspace.
    case writeFile
    /// Unit 33 — speak to the operator WITHOUT pausing the run. The message
    /// lives in `rationale`; the executor performs no OS action. Renders as
    /// a chat bubble (.agentSaid). Use `clarify` only when an ANSWER is
    /// required — clarify parks the run, say never does.
    case say
    case switchApp
    /// Click-and-drag from `startCoordinate` to `coordinate`. Composes a
    /// mouseDown at start, intermediate mouseDragged events along the
    /// straight-line path, and a mouseUp at end. Used for text selection,
    /// slider manipulation, drag-and-drop.
    case drag
    /// Hold a single key down for `durationMs` milliseconds, then release.
    /// Distinct from `.keyCombo` (instant down+up tap) and from the `text`
    /// modifier on `.click`/`.scroll` (modifier held during another action).
    /// Used for Sticky Keys-aware accessibility tasks and long-press menus.
    case holdKey
    /// Unit 13 (Path C) — stateful mouse: press a mouse button down at
    /// `coordinate` and HOLD until a matching `.mouseUp` or terminal event
    /// fires. Composes with `.mouseMove` for drag-select, rubber-band,
    /// slider grab. Use cases the LLM can't express with stateless `.drag`
    /// (single straight-line move).
    /// Shipped in Unit 13b: `Executor.performMouseDown` presses and holds via
    /// CGEvent, registering the held button with `MouseHoldState`.
    case mouseDown
    /// Unit 13 (Path C) — release the currently held mouse button. Throws
    /// if no button is held. Shipped in Unit 13b
    /// (`Executor.performMouseUp` + `MouseHoldState` release).
    case mouseUp
    /// Unit 13 (Path C) — move the mouse cursor to `coordinate` without
    /// emitting click events. Posts a mouseMoved (no button) or
    /// mouseDragged (button held) CGEvent depending on `heldMouse` state.
    /// Shipped in Unit 13b (`Executor.performMouseMove`).
    case mouseMove
}

public struct CodablePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    public static let zero = CodablePoint(.zero)
}

public struct AgentAction: Codable, Equatable, Sendable {
    public let type: ActionType
    public let targetIndex: Int?
    public let text: String?
    public let scrollDelta: CodablePoint?
    public let confidence: Double
    public let requiresConfirmation: Bool
    public let rationale: String
    /// Absolute screen coordinate (logical points) set by ComputerUseClient when no
    /// AX element index is available. Executor uses this as a fallback click target
    /// when targetIndex is nil. Not present in the AgentAction tool JSON schema —
    /// only populated by the Computer Use translation layer.
    public let coordinate: CodablePoint?
    /// Modifier keys (kebab-string like `"shift"` or `"cmd+shift"`) to hold while
    /// performing click or scroll. Set by ComputerUseClient when Anthropic emits
    /// `text` on a click/scroll action; also available to ClaudeLLMClient via the
    /// tool JSON schema. Executor applies as CGEventFlags. Optional + default nil;
    /// receipt schema remains append-only-safe (decodeIfPresent on old receipts).
    public let modifiers: String?
    /// Drag start point (in logical screen points). Used only by `.drag` —
    /// `coordinate` is the end point. Optional + default nil; append-only-safe.
    public let startCoordinate: CodablePoint?
    /// Duration in milliseconds. Used only by `.holdKey` (sleep between keyDown
    /// and keyUp). Optional + default nil; capped at 30_000ms in the decoder so
    /// a hallucinated huge value can't lock the executor for minutes.
    public let durationMs: Int?
    /// Unit 36 — workspace-relative target path for `.writeFile`. Optional +
    /// default nil + Codable back-compat; capped at 1024 chars in the decoder.
    public let filePath: String?

    public init(
        type: ActionType,
        targetIndex: Int? = nil,
        text: String? = nil,
        scrollDelta: CodablePoint? = nil,
        confidence: Double,
        requiresConfirmation: Bool,
        rationale: String,
        coordinate: CodablePoint? = nil,
        modifiers: String? = nil,
        startCoordinate: CodablePoint? = nil,
        durationMs: Int? = nil,
        filePath: String? = nil
    ) {
        self.type = type
        self.targetIndex = targetIndex
        self.text = text
        self.scrollDelta = scrollDelta
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
        self.rationale = rationale
        self.coordinate = coordinate
        self.modifiers = modifiers
        self.startCoordinate = startCoordinate
        self.durationMs = durationMs
        self.filePath = filePath
    }

    private enum CodingKeys: String, CodingKey {
        case type, targetIndex, text, scrollDelta, confidence, requiresConfirmation, rationale, coordinate, modifiers, startCoordinate, durationMs, filePath
    }

    // Custom decoder caps string fields to prevent unbounded LLM output from
    // bloating the receipt log, LLM history, and UI conversation thread.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type                 = try c.decode(ActionType.self, forKey: .type)
        targetIndex          = try c.decodeIfPresent(Int.self, forKey: .targetIndex)
        text                 = try c.decodeIfPresent(String.self, forKey: .text)
                                   .map { String($0.prefix(2000)) }
        scrollDelta          = try c.decodeIfPresent(CodablePoint.self, forKey: .scrollDelta)
        confidence           = try c.decode(Double.self, forKey: .confidence)
        requiresConfirmation = try c.decode(Bool.self, forKey: .requiresConfirmation)
        rationale            = String((try c.decode(String.self, forKey: .rationale)).prefix(2000))
        coordinate           = try c.decodeIfPresent(CodablePoint.self, forKey: .coordinate)
        modifiers            = try c.decodeIfPresent(String.self, forKey: .modifiers)
                                   .map { String($0.prefix(64)) }
        startCoordinate      = try c.decodeIfPresent(CodablePoint.self, forKey: .startCoordinate)
        // Cap at 30_000ms so a hallucinated `durationMs: 99999999` can't lock
        // the executor for minutes. Matches the future item-4 mouse-held
        // watchdog ceiling for consistency.
        durationMs           = try c.decodeIfPresent(Int.self, forKey: .durationMs)
                                   .map { min(max($0, 0), 30_000) }
        filePath             = try c.decodeIfPresent(String.self, forKey: .filePath)
                                   .map { String($0.prefix(1024)) }
    }
}
