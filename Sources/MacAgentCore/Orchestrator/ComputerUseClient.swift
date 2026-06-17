import AppKit
import CoreGraphics
import Foundation
import os.log
// `@preconcurrency` softens Swift 6 Sendable-check errors from
// ScreenCaptureKit symbols (notably `SCShareableContent.current` crossing
// the ComputerUseClient actor's isolation boundary). Required on Swift
// 6.2 / Xcode 16.3 (CI macos-latest); transparent on 6.3+ (local) where
// Apple's SDK already declares the conformance.
@preconcurrency import ScreenCaptureKit

private let cuLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.southernreach.macos-agent-v0",
    category: "ComputerUseClient"
)

/// Distance threshold (logical screen points) for AX-element matching. When the
/// closest AX element is more than this many points from the click coordinate,
/// `nearestElement` returns nil so Executor's coordinate fallback + SafetyPolicy's
/// coord-only `.preview` floor activate. Without this threshold, every click on
/// an AX-empty surface (Electron, web content) snaps to an arbitrary distant
/// element and presses the WRONG control.
private let nearestElementMaxDistance: Double = 100
/// Telemetry threshold — logged as a wrong-coord-space signal.
private let nearestElementTelemetryDistance: Double = 200

// MARK: - ComputerUseClient

/// An `ActionThinking` implementation that uses Anthropic's native Computer Use API
/// (anthropic-beta: computer-use-2025-11-24) rather than the custom AgentAction tool.
///
/// Claude sees a screenshot of the screen each step and returns a `computer_20251124`
/// tool call (click, type, key, scroll, etc.). The client translates that back into an
/// `AgentAction` so the rest of the pipeline — SafetyPolicy, Executor, receipts — is
/// unchanged.
///
/// **AX context hybrid:** The AX element tree is injected as a system prompt block so
/// Claude can reason about accessible labels and roles even while acting on pixel coords.
/// This gives the precision of Computer Use with the safety classification of AX.
///
/// **History format:** Computer Use requires alternating tool_use / tool_result messages.
/// This client manages that internal history independently of the `[LLMMessage]` history
/// passed by the Orchestrator.
public actor ComputerUseClient: ActionThinking {

    // MARK: - Config

    private let apiKey: String
    private let model: String
    /// Read-only accessor for the configured model. `internal` (not `public`) so
    /// it's reachable from `@testable import MacAgentCore` in K.4 without widening
    /// the module's external API. Matches the visibility precedent used by
    /// `ClaudeLLMClient.sanitizeForPrompt` and `ClaudeLLMClient.visionSection`.
    var modelForTesting: String { model }

    /// Seed the scale-state pair without running `captureScreen()`. Used by
    /// `ComputerUseCoordRoundTripTests` to exercise `translate()`'s descale path
    /// deterministically — bypasses ScreenCaptureKit which needs a display.
    func setScaleStateForTesting(sent: CGSize, logical: CGSize) {
        self.lastSentImageSize = sent
        self.lastLogicalSize = logical
    }

    /// Direct passthrough to private `translate`, reachable from
    /// `@testable import MacAgentCore`. Matches `coordinateForTesting` etc.
    func translateForTesting(inputDict: [String: AnyCodable], toolUseID: String, snapshot: PerceptionSnapshot) -> AgentAction {
        translate(inputDict: inputDict, toolUseID: toolUseID, snapshot: snapshot)
    }

    /// Read accessor for `pendingToolResultText` — used by the cursor_position
    /// test to verify the read-action seeded the back-channel.
    var pendingToolResultTextForTesting: String? { pendingToolResultText }
    private let endpoint: URL
    private let session: URLSession
    private let maxTokens: Int

    // MARK: - State

    /// Tracks the active task string. When it changes, internal history is reset.
    private var lastTask: String = ""
    /// Computer Use conversation history in the wire format expected by the API.
    private var cuHistory: [CUMessage] = []
    /// The tool_use_id from the most recent Claude response. On subsequent calls we
    /// wrap the new screenshot in a `tool_result` referencing this id.
    private var lastToolUseID: String? = nil
    /// Logical-screen size of the most recent screenshot we sent. The Executor posts
    /// CGEvents in this coordinate space.
    private var lastLogicalSize: CGSize?
    /// Dimensions of the image actually sent to Claude (may be downsampled for
    /// non-Opus-4.7 models per Anthropic's 1568-px cap). Claude returns coords in
    /// this space; we descale back to `lastLogicalSize` before executing.
    private var lastSentImageSize: CGSize?
    /// When Claude emits a `cursor_position` read-action, the answer is queued
    /// here and surfaced on the next request as a text block alongside the
    /// `tool_result` screenshot. Drained on consumption.
    private var pendingToolResultText: String?
    /// Screen coordinate of the most recent click action (logical points).
    /// Used by nearestFocusedElement to pick the text field the user just clicked
    /// rather than defaulting to the first text field in AX order.
    private var lastClickCoordinate: CGPoint?

    /// Anthropic ships two CU beta protocols. Each model accepts exactly one:
    /// - `computer-use-2025-11-24` + `computer_20251124` for Opus 4.7 / 4.6,
    ///   Sonnet 4.6, Opus 4.5 (the modern family with enhanced actions + zoom).
    /// - `computer-use-2025-01-24` + `computer_20250124` for Sonnet 4.5, Haiku 4.5,
    ///   Opus 4.1, Sonnet 4, Opus 4 (older models; ~5× cheaper on Haiku 4.5).
    /// Only Opus 4.7 returns 1:1 coords; every other model requires
    /// client-side 1568-px downsample + inverse rescale.
    enum CUToolVersion: Sendable {
        case v20251124
        case v20250124

        var betaHeader: String {
            switch self {
            case .v20251124: return "computer-use-2025-11-24"
            case .v20250124: return "computer-use-2025-01-24"
            }
        }

        var toolTypeName: String {
            switch self {
            case .v20251124: return "computer_20251124"
            case .v20250124: return "computer_20250124"
            }
        }
    }

    /// Maps model ID to the beta protocol Anthropic accepts. Models not in the
    /// known whitelist default to the new beta (least likely to surprise on
    /// future model releases under the same family).
    var cuToolVersion: CUToolVersion {
        // Old-beta family (per Anthropic docs as of 2026-05-12).
        // `claude-sonnet-4` / `claude-opus-4` are retained here for migration-race
        // defense only — they were dropped from the SettingsView whitelist in
        // commit `ceb3698` and retire 2026-06-15. Keeping them in this routing
        // set ensures any stale-default user still gets the correct beta header
        // during the grace period. Not a current-docs entry.
        let oldBeta: Set<String> = [
            "claude-sonnet-4-5-20250929",
            "claude-haiku-4-5-20251001",
            "claude-opus-4-1",
            "claude-sonnet-4",
            "claude-opus-4",
        ]
        // hasPrefix (not contains) — narrows the substring surface so a future
        // model name like `claude-sonnet-4-50` couldn't accidentally route to
        // old-beta. Anthropic's dated suffixes are appended (-20251001), not
        // prepended, so hasPrefix catches them correctly.
        if oldBeta.contains(model)
            || model.hasPrefix("claude-haiku-4-5")
            || model.hasPrefix("claude-sonnet-4-5") {
            return .v20250124
        }
        return .v20251124
    }

    /// Per Anthropic CU docs: Opus 4.7 supports up to 2576-px long-edge images
    /// at 1:1 coords. Every other supported model — old beta or new — operates
    /// in 1568-px scaled space and needs client-side downsample + inverse
    /// rescale. The condition is per-model, not per-beta.
    private var requiresScaling: Bool {
        !model.contains("opus-4-7")
    }

    // MARK: - Init

    public init(
        apiKey: String,
        model: String,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        session: URLSession = .shared,
        maxTokens: Int = 1024
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.maxTokens = maxTokens
    }

    // MARK: - ActionThinking

    /// Per-run CU state reset. Extracted from `nextAction` so the reset
    /// contract is unit-testable without a live screenshot/network turn: a task
    /// change must clear the conversation history, the pending tool-use id, AND
    /// the queued read-action answer (`pendingToolResultText`). Omitting the
    /// last one let a `cursor_position` answer queued as the final step of one
    /// run leak into the next run's first `tool_result` block.
    func resetIfTaskChanged(_ task: String) {
        guard task != lastTask else { return }
        cuHistory = []
        lastToolUseID = nil
        pendingToolResultText = nil
        lastTask = task
    }

    public func nextAction(
        task: String,
        snapshot: PerceptionSnapshot,
        history: [LLMMessage],
        runningApps: [RunningApp]
    ) async throws -> AgentAction {
        // Reset internal history when the task changes (new run).
        resetIfTaskChanged(task)

        // Capture a screenshot. For Opus 4.7 (no scaling required) we can reuse a
        // cached PNG from the snapshot; for scaled models we always capture fresh
        // because the cached PNG's resolution may not match what we'd capture and
        // we need known sizes for the descale math.
        let screenshotData: Data
        if requiresScaling {
            screenshotData = try await captureScreen()
        } else if let cached = snapshot.screenshotPNG,
                  let bitmap = NSBitmapImageRep(data: cached) {
            // Cached-PNG branch — used by Opus 4.7 (no-scaling models). Pixel
            // dimensions come from the PNG itself (Retina-correct: pixelsWide
            // is the actual image-data dimension); logical size comes from
            // the snapshot's record of the capture-time screen geometry so
            // the descale math doesn't desync if display geometry changes
            // between capture and send.
            screenshotData = cached
            lastSentImageSize = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            if let stored = snapshot.screenshotLogicalSize?.cgSize {
                lastLogicalSize = stored
            } else {
                // Back-compat: snapshot wasn't tagged with capture-time logical size.
                // Fall back to the live screen — same behaviour as pre-Cluster-E,
                // good enough when no display reconfig happened.
                lastLogicalSize = await MainActor.run {
                    NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
                }
            }
        } else {
            // Either no cached PNG, or the cached PNG was undecodable. In the
            // undecodable case, sending the corrupt bytes downstream would also
            // be wrong by ~2x on Retina (the prior fallback used logical points
            // for what is a pixel-space measurement). Capture fresh instead —
            // captureScreen() sets both lastLogicalSize and lastSentImageSize
            // with internally-consistent values.
            if snapshot.screenshotPNG != nil {
                cuLog.error("Cached PNG present but undecodable by NSBitmapImageRep; capturing fresh screen rather than sending corrupt bytes.")
            }
            screenshotData = try await captureScreen()
        }
        let base64Image = screenshotData.base64EncodedString()

        // Build the user message. On the first call it's just a screenshot.
        // On subsequent calls it wraps the screenshot in a tool_result for the
        // previous tool_use_id, then appends a fresh screenshot observation.
        let userContent: [CUContent]
        if let lastID = lastToolUseID {
            // Drain any queued read-action answer (e.g., cursor_position result)
            // and embed it in the tool_result content alongside the screenshot.
            var toolResultBody: [CUContent] = [
                .image(mediaType: "image/png", data: base64Image)
            ]
            if let drained = pendingToolResultText {
                toolResultBody.append(.text(drained))
                pendingToolResultText = nil
            }
            userContent = [
                .toolResult(toolUseID: lastID, content: toolResultBody),
                .text("Current screenshot attached. Continue the task.")
            ]
        } else {
            userContent = [
                .image(mediaType: "image/png", data: base64Image),
                .text("Begin working on the task.")
            ]
        }
        cuHistory.append(CUMessage(role: "user", content: userContent))

        // Cap history. Anthropic API requires conversations start with a `user`
        // message; messages strictly alternate user/assistant after that. A
        // naive `suffix(20)` applied at this point (right after a user append)
        // when the count is 21 would drop the leading user[0] and leave
        // assistant[1] at the front — fires API "first message must be user"
        // rejection at the moment the cap activates (turn 11 onward).
        //
        // Post-user-append count is always odd (even after assistant + 1).
        // Cap to 19 (odd) here so post-assistant the count is at most 20 —
        // matches the documented "10 turns (20 messages)" budget while
        // guaranteeing the first kept message is always a user turn.
        cuHistory = Self.applyHistoryCap(cuHistory, cap: 19)
        // Memory + token-cost hardening: each screenshot is ~500KB base64 inside
        // an `.image` content block. A 20-message history holds ~10MB pinned in
        // actor memory and re-uploaded to Anthropic every turn. The model only
        // needs visual recency, so strip image blocks from every message except
        // the last 6 — text content and tool_use/tool_result wrappers stay
        // intact so the API doesn't reject orphan tool blocks.
        let imagesToKeep = 6
        if cuHistory.count > imagesToKeep {
            let stripUntil = cuHistory.count - imagesToKeep
            for i in 0..<stripUntil {
                cuHistory[i] = CUMessage(
                    role: cuHistory[i].role,
                    content: Self.stripImages(from: cuHistory[i].content)
                )
            }
        }

        // System prompt: task + AX context + running apps.
        let systemPrompt = Self.buildSystemPrompt(
            task: task, snapshot: snapshot, history: history, runningApps: runningApps)

        // Build and send request. Tool definition width/height MUST reflect the
        // dimensions of the image we sent (post-scale), not the logical screen
        // size — Claude returns click coordinates in that space.
        let toolImageSize: CGSize
        if let sent = lastSentImageSize {
            toolImageSize = sent
        } else {
            toolImageSize = await screenLogicalSize()
        }
        let requestBody = CURequest(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: cuHistory,
            tools: [CUTool.computer(version: cuToolVersion, width: Int(toolImageSize.width), height: Int(toolImageSize.height))],
            toolChoice: CUToolChoice(type: "any")
        )

        let response = try await performRequest(body: requestBody)

        // Extract the first tool_use block.
        guard let toolUse = response.content.first(where: { $0.type == "tool_use" }),
              case .toolUse(let toolID, _, let inputDict) = toolUse else {
            // Claude returned text only. Unit 33 — narration becomes a
            // non-pausing .say; only an explicit question (trailing "?")
            // parks the run as a clarification. Pre-33, ALL text-only
            // responses parked as clarify, so a CU model thinking aloud
            // froze the run until the operator answered a non-question.
            let text = response.content.compactMap { $0.text }.joined(separator: " ")
            lastToolUseID = nil
            cuHistory.append(CUMessage(role: "assistant", content: response.content))
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isQuestion = trimmed.hasSuffix("?") || trimmed.isEmpty
            return AgentAction(
                type: isQuestion ? .clarify : .say,
                confidence: 0.9,
                requiresConfirmation: false,
                rationale: trimmed.isEmpty ? "Claude did not return an action." : String(trimmed.prefix(2000))
            )
        }

        // Record assistant message in history.
        lastToolUseID = toolID
        cuHistory.append(CUMessage(role: "assistant", content: response.content))

        // Translate to AgentAction.
        return translate(inputDict: inputDict, toolUseID: toolID, snapshot: snapshot)
    }

    // MARK: - Translation

    private func translate(
        inputDict: [String: AnyCodable],
        toolUseID: String,
        snapshot: PerceptionSnapshot
    ) -> AgentAction {
        guard let actionStr = inputDict["action"]?.value as? String else {
            return AgentAction(type: .wait, confidence: 0.5,
                               requiresConfirmation: false, rationale: "Unknown Computer Use action.")
        }

        switch actionStr {

        case "screenshot":
            return AgentAction(type: .wait, confidence: 1.0,
                               requiresConfirmation: false, rationale: "Taking a screenshot to observe current state.")

        case "left_click", "right_click", "double_click", "triple_click", "middle_click":
            guard let rawCoord = coordinate(from: inputDict["coordinate"]) else {
                return AgentAction(type: .wait, confidence: 0.5,
                                   requiresConfirmation: true,
                                   rationale: "Computer Use: \(actionStr) missing or malformed coordinate.")
            }
            // Descale from Claude's image-pixel space back to logical screen points
            // (no-op for Opus 4.7 where sent==logical). MUST happen before
            // nearestElement so AX frames (in logical points) are compared correctly.
            let coord = descaleClickCoord(rawCoord)
            lastClickCoordinate = coord  // remembered for nearestFocusedElement on the next typeText
            let (nearestIndex, confidence) = nearestElement(to: coord, in: snapshot)
            let actionType: ActionType
            switch actionStr {
            case "right_click":  actionType = .rightClick
            case "double_click": actionType = .doubleClick
            case "triple_click": actionType = .tripleClick
            default:             actionType = .click
            }
            // Per Anthropic docs, `text` on click holds modifier keys (e.g. "shift",
            // "super" for Cmd-click). Normalize via x11KeysToMacOS for the cmd token.
            let modifiers = (inputDict["text"]?.value as? String).map { Self.x11KeysToMacOS($0) }
            return AgentAction(
                type: actionType,
                targetIndex: nearestIndex,
                confidence: confidence,
                requiresConfirmation: confidence < 0.75,
                rationale: "Computer Use: \(actionStr) at (\(Int(coord.x)), \(Int(coord.y)))" + (modifiers.map { " with \($0)" } ?? ""),
                coordinate: CodablePoint(coord),
                modifiers: modifiers
            )

        case "left_click_drag":
            // Anthropic emits `start_coordinate` + `coordinate` (end). Optional
            // `text` carries modifier keys held during the drag.
            guard let rawStart = coordinate(from: inputDict["start_coordinate"]),
                  let rawEnd = coordinate(from: inputDict["coordinate"]) else {
                return AgentAction(type: .wait, confidence: 0.5,
                                   requiresConfirmation: true,
                                   rationale: "Computer Use: left_click_drag missing or malformed start/end coordinate.")
            }
            let start = descaleClickCoord(rawStart)
            let end = descaleClickCoord(rawEnd)
            let modifiers = (inputDict["text"]?.value as? String).map { Self.x11KeysToMacOS($0) }
            return AgentAction(
                type: .drag,
                confidence: 0.85,
                requiresConfirmation: false,
                rationale: "Computer Use: drag from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))" + (modifiers.map { " with \($0)" } ?? ""),
                coordinate: CodablePoint(end),
                modifiers: modifiers,
                startCoordinate: CodablePoint(start)
            )

        case "type":
            let text = inputDict["text"]?.value as? String ?? ""
            let (nearestIndex, confidence) = nearestFocusedElement(in: snapshot)
            // Mark blind typing as confirmation-needed. nearestFocusedElement returns
            // confidence 0.60 with nil index when no text field is visible, and 0.85
            // when picking the first enabled text field heuristically. Either case is
            // "we are not certain this is the right field" — and AutonomyMode + the
            // capability-rule floor predicate use targetIndex == nil to hold .preview.
            // Setting requiresConfirmation here documents the intent on the action /
            // receipt without changing the tier (typeText already floors at .preview
            // in classify()); future safety consumers can rely on the flag.
            let needsConfirm = (nearestIndex == nil) || (confidence < 0.85)
            return AgentAction(
                type: .typeText,
                targetIndex: nearestIndex,
                text: text,
                confidence: confidence,
                requiresConfirmation: needsConfirm,
                rationale: "Computer Use: type text"
            )

        case "key":
            let keys = inputDict["text"]?.value as? String ?? ""
            return AgentAction(
                type: .keyCombo,
                text: x11KeysToMacOS(keys),
                confidence: 0.95,
                requiresConfirmation: false,
                rationale: "Computer Use: key \(keys)"
            )

        case "hold_key":
            // Anthropic CU emits `{action: "hold_key", text: "<key>", duration: <seconds>}`.
            // True-duration implementation: Executor posts keyDown, sleeps
            // `durationMs`, posts keyUp (with defer cleanup on cancellation).
            // The schema-decoder caps durationMs at 30_000ms so a hallucinated
            // huge value can't lock the executor.
            let keys = inputDict["text"]?.value as? String ?? ""
            let duration = inputDict["duration"]?.value as? Double ?? 0
            let durationMs = Int((duration * 1000).rounded())
            return AgentAction(
                type: .holdKey,
                text: x11KeysToMacOS(keys),
                confidence: 0.95,
                requiresConfirmation: false,
                rationale: "Computer Use: hold_key \(keys) for \(duration)s",
                durationMs: durationMs
            )

        case "scroll":
            guard let rawCoord = coordinate(from: inputDict["coordinate"]) else {
                return AgentAction(type: .wait, confidence: 0.5,
                                   requiresConfirmation: true,
                                   rationale: "Computer Use: scroll missing or malformed coordinate.")
            }
            let coord = descaleClickCoord(rawCoord)
            // Anthropic computer_20251124 schema: `scroll_direction` + `scroll_amount`.
            // The pre-fix code read `direction` / `amount` which silently fell through
            // the switch default on every scroll — wrong direction and wrong magnitude.
            let direction = inputDict["scroll_direction"]?.value as? String ?? "down"
            let amount = (inputDict["scroll_amount"]?.value as? Int) ?? 3
            let delta: CodablePoint
            switch direction {
            case "up":    delta = CodablePoint(CGPoint(x: 0, y: Double(amount) * 10))
            case "down":  delta = CodablePoint(CGPoint(x: 0, y: Double(-amount) * 10))
            case "left":  delta = CodablePoint(CGPoint(x: Double(-amount) * 10, y: 0))
            case "right": delta = CodablePoint(CGPoint(x: Double(amount) * 10, y: 0))
            default:      delta = CodablePoint(CGPoint(x: 0, y: -30))
            }
            let (nearestIndex, confidence) = nearestElement(to: coord, in: snapshot)
            // Modifier passthrough on scroll (e.g. Cmd-scroll for zoom in some apps).
            let modifiers = (inputDict["text"]?.value as? String).map { Self.x11KeysToMacOS($0) }
            return AgentAction(
                type: .scroll,
                targetIndex: nearestIndex,
                scrollDelta: delta,
                confidence: confidence,
                requiresConfirmation: false,
                rationale: "Computer Use: scroll \(direction) at (\(Int(coord.x)), \(Int(coord.y)))" + (modifiers.map { " with \($0)" } ?? ""),
                coordinate: CodablePoint(coord),
                modifiers: modifiers
            )

        case "left_mouse_down", "left_mouse_up", "mouse_move":
            // CU stateful mouse: schema + translator landed in Unit 13a, the
            // executor state machine in Unit 13b. These map to the live
            // `.mouseDown`/`.mouseUp`/`.mouseMove` ActionTypes, executed via
            // CGEvent with `MouseHoldState` tracking the held button.
            //
            // Wire format:
            //   left_mouse_down / left_mouse_up — `coordinate: [x, y]` (LMB
            //     only on the current CU tool spec; right_mouse_*/middle
            //     are not yet exposed by Anthropic's tool).
            //   mouse_move — `coordinate: [x, y]`. Behaviour depends on
            //     `mouseDown` state: hold → mouseDragged; no hold → mouseMoved.
            //
            // Coordinate handling is identical to the click path: descale
            // from sent-image space to logical points and stamp `lastClick
            // Coordinate` for downstream `nearestFocusedElement`.
            guard let rawCoord = coordinate(from: inputDict["coordinate"]) else {
                return AgentAction(type: .wait, confidence: 0.5,
                                   requiresConfirmation: true,
                                   rationale: "Computer Use: \(actionStr) missing or malformed coordinate.")
            }
            let coord = descaleClickCoord(rawCoord)
            lastClickCoordinate = coord
            let mappedType: ActionType
            switch actionStr {
            case "left_mouse_down": mappedType = .mouseDown
            case "left_mouse_up":   mappedType = .mouseUp
            default:                mappedType = .mouseMove
            }
            return AgentAction(
                type: mappedType,
                confidence: 0.9,
                requiresConfirmation: false,
                rationale: "Computer Use: \(actionStr) at (\(Int(coord.x)), \(Int(coord.y)))",
                coordinate: CodablePoint(coord)
            )

        case "wait":
            return AgentAction(type: .wait, confidence: 1.0,
                               requiresConfirmation: false, rationale: "Computer Use: wait.")

        case "zoom":
            // We don't set `enable_zoom: true` in the tool definition so Claude
            // shouldn't emit this action — but if it ever does (future schema
            // change, Anthropic-side bug), treat as a no-op observation rather
            // than a vague "Unknown Computer Use action" rationale.
            return AgentAction(type: .wait, confidence: 1.0,
                               requiresConfirmation: false,
                               rationale: "Computer Use: zoom requested but not enabled — observing.")

        case "cursor_position":
            // Read-action: Claude asks where the cursor currently is. We can't
            // return data via AgentAction (which represents what to *do*), so
            // we queue the answer in `pendingToolResultText` to be embedded in
            // the next tool_result content block, alongside the next screenshot.
            // Returning `.wait` keeps the loop moving without executing anything.
            //
            // Pre-fix used NSEvent.mouseLocation (bottom-left origin across all
            // screens) and flipped Y against NSScreen.main.frame.height. On
            // multi-monitor setups the cursor can be on a non-main screen whose
            // height differs from main — the flip would return a Y value off
            // by the height delta. CGEvent(source: nil).location returns coords
            // in top-left global space natively, no flip needed, multi-monitor
            // correct without enumerating NSScreens.
            let cursorPoint = CGEvent(source: nil)?.location ?? .zero
            let answer = "cursor_position: (\(Int(cursorPoint.x)), \(Int(cursorPoint.y)))"
            pendingToolResultText = answer
            return AgentAction(type: .wait, confidence: 1.0,
                               requiresConfirmation: false,
                               rationale: "Computer Use: reported \(answer).")

        default:
            // Schema drift signal: Claude emitted an action we don't recognize.
            // `.error` level (vs `.info` for the expected mouse_move case)
            // because truly-unknown actions imply either Anthropic added a
            // new action type without bumping the beta header, or the model
            // hallucinated a name.
            cuLog.error("cu.unknown_action=\(actionStr, privacy: .public)")
            return AgentAction(type: .wait, confidence: 0.5,
                               requiresConfirmation: true, rationale: "Unknown Computer Use action: \(actionStr).")
        }
    }

    // MARK: - AX element matching

    /// Find the AX element whose frame center is closest to `point`.
    /// Returns (index, confidence) where confidence degrades with distance.
    private func nearestElement(to point: CGPoint, in snapshot: PerceptionSnapshot) -> (Int?, Double) {
        Self.nearestElement(to: point, in: snapshot, modelForTelemetry: model)
    }

    /// Internal static for `@testable` access (`ComputerUseTranslateTests`).
    /// Telemetry only fires when `modelForTelemetry` is non-nil so tests can
    /// exercise the threshold without coupling to log capture.
    static func nearestElementForTesting(_ point: CGPoint, snapshot: PerceptionSnapshot) -> (Int?, Double) {
        nearestElement(to: point, in: snapshot, modelForTelemetry: nil)
    }

    private static func nearestElement(to point: CGPoint, in snapshot: PerceptionSnapshot, modelForTelemetry: String?) -> (Int?, Double) {
        // Pass 1: rect-containment. If the click point is inside an element's bounding
        // rect, that element is the definitive target — no distance guessing needed.
        // This is the primary match strategy used by DOM-based agents (Playwright, browser-use)
        // and eliminates the address-bar miss where center-distance is large but the
        // click clearly lands inside the bar's rect.
        var containedIndex: Int? = nil
        var smallestContainedArea = Double.infinity
        for el in snapshot.elements {
            let frame = el.frame.cgRect
            if frame.contains(point) {
                // Prefer the smallest containing rect (most specific element).
                let area = Double(frame.width * frame.height)
                if area < smallestContainedArea {
                    smallestContainedArea = area
                    containedIndex = el.index
                }
            }
        }
        if let idx = containedIndex {
            return (idx, 0.95)
        }

        // Pass 2: center-distance fallback for elements whose AX rect doesn't cover
        // the click (common in canvas/Electron content with sparse AX trees).
        var bestIndex: Int? = nil
        var bestDist = Double.infinity
        for el in snapshot.elements {
            let frame = el.frame.cgRect
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dist = hypot(point.x - center.x, point.y - center.y)
            if dist < bestDist {
                bestDist = dist
                bestIndex = el.index
            }
        }
        // Confidence degrades with distance from element center.
        let confidence: Double
        if bestDist < 20 { confidence = 0.95 }
        else if bestDist < 50 { confidence = 0.85 }
        else if bestDist < 100 { confidence = 0.75 }
        else if bestDist < 200 { confidence = 0.60 }
        else { confidence = 0.45 }
        // Telemetry signal for wrong-coord-space bugs: when Claude clicks far from
        // any AX element, log so Console.app shows the divergence even if the
        // SafetyPolicy floor catches the action silently.
        if bestDist > nearestElementTelemetryDistance, let model = modelForTelemetry {
            cuLog.error("cu.coord_far_from_ax dist=\(bestDist, privacy: .public) coord=(\(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)) elements=\(snapshot.elements.count, privacy: .public) model=\(model, privacy: .public)")
        }
        // Distance threshold: when the nearest AX element is too far to be
        // plausibly the intended target, return nil so Executor.resolveTarget
        // takes the `.coordinate` fallback and SafetyPolicy.classify floors
        // the action at `.preview` (no auto-execution on coord-only clicks).
        if bestDist > nearestElementMaxDistance {
            return (nil, confidence)
        }
        return (bestIndex, confidence)
    }

    /// For typeText: find the best text input element.
    /// Priority: (1) text-input element with isFocused=true (Unit 25
    /// signal — AX server's ground truth for where keystrokes land),
    /// (2) element whose rect contains the last click coordinate,
    /// (3) first enabled text field in AX order.
    /// Fixes "types into wrong field" when multiple text inputs are visible.
    /// The non-text-role isFocused case (e.g. a button has focus) falls
    /// through to lastClick — we never pick a non-text element to type into.
    private func nearestFocusedElement(in snapshot: PerceptionSnapshot) -> (Int?, Double) {
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        let textElements = snapshot.elements.filter { textRoles.contains($0.role) && $0.isEnabled }
        if let focused = textElements.first(where: { $0.isFocused }) {
            return (focused.index, 0.95)
        }
        if let lastClick = lastClickCoordinate,
           let contained = textElements.first(where: { $0.frame.cgRect.contains(lastClick) }) {
            return (contained.index, 0.95)
        }
        if let first = textElements.first {
            return (first.index, 0.85)
        }
        return (nil, 0.60)
    }

    // MARK: - Helpers

    /// Parse Anthropic's `coordinate: [x, y]` shape. Returns nil on missing or
    /// malformed input (was `.zero` before — a silent top-left-corner misclick).
    /// Int branch is tried first because Anthropic's CU API emits integer pixel
    /// coordinates; Double is a fallback for any non-strict producer.
    private func coordinate(from value: AnyCodable?) -> CGPoint? {
        Self.coordinate(from: value)
    }

    /// Internal static for `@testable` access.
    static func coordinateForTesting(_ value: AnyCodable?) -> CGPoint? {
        coordinate(from: value)
    }

    private static func coordinate(from value: AnyCodable?) -> CGPoint? {
        guard let arr = value?.value as? [Any], arr.count >= 2 else { return nil }
        if let x = arr[0] as? Int, let y = arr[1] as? Int {
            return CGPoint(x: x, y: y)
        }
        if let x = arr[0] as? Double, let y = arr[1] as? Double {
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    /// Convert Anthropic CU key names to macOS key combo strings.
    /// Per Anthropic docs (Modifier keys section), Claude emits `super` for the
    /// Command/Windows key. The prior `ctrl`/`control` → `cmd` remap was a bug:
    /// it silently turned every `ctrl+c` (e.g., SIGINT in a terminal) into a
    /// macOS Copy and every `ctrl+a` into Select-All — semantic corruption with
    /// no signal.
    private func x11KeysToMacOS(_ keys: String) -> String {
        Self.x11KeysToMacOS(keys)
    }

    /// Internal static for `@testable` access.
    static func x11KeysToMacOSForTesting(_ keys: String) -> String {
        x11KeysToMacOS(keys)
    }

    private static func x11KeysToMacOS(_ keys: String) -> String {
        let map: [String: String] = [
            "super": "cmd",
            "Return": "return", "BackSpace": "delete",
            "Tab": "tab", "Escape": "escape",
            "F1": "f1", "F2": "f2", "F3": "f3", "F4": "f4",
            "F5": "f5", "F6": "f6", "F7": "f7", "F8": "f8",
            "Page_Up": "pageup", "Page_Down": "pagedown",
            "Home": "home", "End": "end",
        ]
        return keys.components(separatedBy: "+")
            .map { map[$0] ?? $0.lowercased() }
            .joined(separator: "+")
    }

    /// Async + MainActor-hopped because `NSScreen.main` is @MainActor-isolated.
    /// All call sites are already inside `nextAction` (async).
    private func screenLogicalSize() async -> CGSize {
        await MainActor.run { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }
    }

    /// Inverse of the screenshot downsample: maps a coordinate Claude returned
    /// (in the space of the image we sent) back to logical screen points.
    /// No-op when `lastSentImageSize == lastLogicalSize` (Opus 4.7) or when we
    /// haven't captured yet (first-call guard — uses raw point).
    private func descaleClickCoord(_ raw: CGPoint) -> CGPoint {
        guard let sent = lastSentImageSize, let logical = lastLogicalSize else { return raw }
        return ScreenScaler.descale(raw, sentSize: sent, logicalSize: logical)
    }

    /// Full-screen capture at logical resolution, with optional downsampling for
    /// non-Opus-4.7 models per Anthropic's 1568-px cap (see ScreenScaler). Stores
    /// `lastLogicalSize` and `lastSentImageSize` for the descale path in translate().
    /// Retry pattern mirrors VisionPerception.captureVisualContext().
    ///
    /// **H3 sibling — agent overlay exclusion.** When the agent's launcher /
    /// HUD windows are visible on top of the target app (the normal state
    /// during a run), full-screen capture without exclusion would send the
    /// model a screenshot that includes our own UI obscuring parts of the
    /// target. The model then anchors clicks against pixels that on the
    /// real display sit underneath the agent overlay — CGEvent posts at
    /// those coords hit the agent, not the target. Unit 5 fixed the AX
    /// case (`AXPerception.defaultWalker`); this is the screenshot case.
    /// PID source matches Unit 5 (ProcessInfo.processInfo.processIdentifier).
    private func captureScreen() async throws -> Data {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw LLMError.api("ComputerUseClient: no display available for screen capture.")
        }
        let logical = await MainActor.run { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = Int(logical.width)
        configuration.height = Int(logical.height)
        // Test gap: ScreenCaptureKit (SCShareableContent / SCContentFilter)
        // is not mockable. The exclusion list builder `agentAppsToExclude` is
        // unit-tested in isolation (see Support/AgentIdentity.swift); this
        // call site itself is only covered by build + live-app verification.
        let agentApps = agentAppsToExclude(in: content.applications)
        let filter = SCContentFilter(display: display, excludingApplications: agentApps, exceptingWindows: [])

        var cgImage: CGImage?
        var lastError: Error?
        for attempt in 1...3 {
            do {
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                break
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                }
            }
        }
        guard var cgImage else {
            throw LLMError.api("ComputerUseClient: screen capture failed — \(lastError?.localizedDescription ?? "unknown error")")
        }
        // Downsample for non-Opus-4.7 models. ScreenScaler returns the input
        // unchanged if it's already within the cap.
        let sentSize: CGSize
        if requiresScaling {
            let (scaled, scaledSize) = ScreenScaler.scaleDownIfNeeded(cgImage, maxEdge: ScreenScaler.cuMaxEdgeForScaledModels)
            cgImage = scaled
            sentSize = scaledSize
        } else {
            sentSize = CGSize(width: cgImage.width, height: cgImage.height)
        }
        lastLogicalSize = logical
        lastSentImageSize = sentSize
        guard let pngData = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw LLMError.api("ComputerUseClient: failed to encode screen capture as PNG.")
        }
        return pngData
    }

    /// Strip `.image` content blocks from a CU message body, replacing each
    /// with a small text placeholder so the assistant still sees the position
    /// where a screenshot used to be. Recurses into `.toolResult` so the
    /// tool_use ↔ tool_result pairing the Anthropic API requires is preserved
    /// (orphan tool_use without a matching tool_result is a hard API error).
    /// `internal` so tests can drive it directly without a full client.
    /// Trim `cuHistory` to at most `cap` messages while preserving Anthropic's
    /// API invariants:
    ///   1. The kept window's first message MUST be a `user` (alternation rule).
    ///   2. The kept window's first message MUST NOT contain an orphan
    ///      `tool_result` block. A `tool_result`'s `tool_use_id` must match a
    ///      `tool_use` in the immediately-preceding assistant turn. When the
    ///      trim drops that preceding assistant, the kept-first user's
    ///      `tool_result` becomes orphan → HTTP 400 "unexpected tool_use_id
    ///      found in tool_result blocks." Detected in live use 2026-05-25
    ///      at turn 11 onward of a multi-step CU run.
    ///
    /// Strategy: take `suffix(cap)` for invariant #1 (caller passes an odd cap
    /// after their user-append, so post-assistant the count stays even).
    /// Then if the kept-first user contains any `tool_result` block, replace
    /// the entire content with a single text placeholder describing the
    /// truncation. The model loses one "result of earlier tool_use" hint;
    /// the next observe() ships a fresh screenshot which is the only
    /// recovery signal CU actually needs.
    internal static func applyHistoryCap(_ history: [CUMessage], cap: Int) -> [CUMessage] {
        guard history.count > cap else { return history }
        var trimmed = Array(history.suffix(cap))
        if let first = trimmed.first,
           first.role == "user",
           first.content.contains(where: { if case .toolResult = $0 { return true } else { return false } }) {
            trimmed[0] = CUMessage(
                role: "user",
                content: [
                    .text("[Earlier conversation turns omitted to fit the history cap. Continuing with the next screenshot.]")
                ]
            )
        }
        return trimmed
    }

    internal static func stripImages(from content: [CUContent]) -> [CUContent] {
        content.map { block -> CUContent in
            switch block {
            case .image:
                return .text("[screenshot omitted — older turn]")
            case .toolResult(let toolUseID, let inner):
                return .toolResult(toolUseID: toolUseID, content: stripImages(from: inner))
            case .text, .toolUse:
                return block
            }
        }
    }

    /// Build the CU system prompt. Static so unit tests can verify sanitisation
    /// without constructing a full ComputerUseClient. AX labels, app names, and
    /// prior-turn history content are all untrusted strings — they are passed
    /// through ClaudeLLMClient.sanitizeForPrompt to strip injection codepoints
    /// (newlines, paragraph separators, zero-width / tag chars) before reaching
    /// the LLM. Mirrors the sanitisation already applied in ClaudeLLMClient.nextAction.
    internal static func buildSystemPrompt(
        task: String,
        snapshot: PerceptionSnapshot,
        history: [LLMMessage],
        runningApps: [RunningApp]
    ) -> String {
        let axBlock: String
        if snapshot.elements.isEmpty {
            axBlock = "(No AX elements — use visual coordinates from the screenshot.)"
        } else {
            let lines = snapshot.elements.prefix(80).map { el in
                let role = ClaudeLLMClient.sanitizeForPrompt(el.role)
                let label = ClaudeLLMClient.sanitizeForPrompt(el.label)
                // Unit 25 — surface focus only when true to keep lines short.
                // At most one element per snapshot has isFocused=true.
                let focused = el.isFocused ? " focused:true" : ""
                return "[\(el.index)] \(role) \"\(label)\" enabled:\(el.isEnabled)\(focused)"
            }.joined(separator: "\n")
            axBlock = lines
        }

        let appsBlock = runningApps.isEmpty ? "" :
            "\nRunning apps: " + runningApps.map {
                "\(ClaudeLLMClient.sanitizeForPrompt($0.name)) (\(ClaudeLLMClient.sanitizeForPrompt($0.bundleID)))"
            }.joined(separator: ", ")

        let historyBlock = history.suffix(4).map {
            "\($0.role): \(ClaudeLLMClient.sanitizeForPrompt($0.content))"
        }.joined(separator: "\n")

        // Unit 9/10 — `agentIsOverlaid` true in two scenarios; prompt branches
        // on whether focusedAppBundleID is the agent itself (cold start,
        // Unit 10) or a different app (Unit 8 fallback fired, Unit 9).
        let agentOverlayBlock: String
        if snapshot.agentIsOverlaid && snapshot.focusedAppBundleID == agentBundleID {
            agentOverlayBlock = """

                ⚠️ COLD START — macOS Agent v0's launcher is the only thing currently observable. The AX elements below belong to the launcher itself; do NOT click any of them. Your FIRST action MUST be:
                  • switchApp(text="<bundleID>") to activate a running app OR launch an installed app by bundle ID (e.g. text="com.apple.Notes"). Pick the target from the task text and match against Running Apps below.
                  • clarify(rationale="...") only if the task is ambiguous about which app to act on.
                Do not click, type, or scroll on this snapshot — there is no useful target here yet. The next observation will see the real target after switchApp succeeds.

                """
        } else if snapshot.agentIsOverlaid {
            agentOverlayBlock = "\n⚠️ macOS Agent v0's launcher window is still in front of \(snapshot.focusedAppBundleID). The AX tree below is the target app's, but a pixel click would hit my own overlay. Dispatch switchApp with text=\"\(snapshot.focusedAppBundleID)\" as your FIRST action so the target becomes the real frontmost window before any click.\n"
        } else {
            agentOverlayBlock = ""
        }

        return """
        You are a macOS desktop agent controlling the screen via Computer Use tools.
        Task: \(task)
        \(agentOverlayBlock)\(appsBlock)

        AX element tree (use indices for accessible controls when visible):
        \(axBlock)

        \(historyBlock.isEmpty ? "" : "Conversation so far:\n\(historyBlock)\n")
        Rules:
        - Prefer clicking accessible elements by their visual position on screen.
        - Use the `type` action for entering text; use `key` for keyboard shortcuts.
        - Use `screenshot` action if you need to observe the current state before acting.
        - If you cannot determine what to do, emit a text response explaining why.
        - One action per response. Do not chain multiple tool calls.
        - "send" buttons on email or messages always require extra care.
        - After typing a URL or search query into a browser address bar or search field, you MUST emit a separate `key` action with `Return` to navigate. Never emit `complete` immediately after typing a URL — the page has not loaded yet.
        - After typing into any form field that requires submission (address bar, search box, login field), always follow with `key Return` before considering the task done.
        """
    }

    // MARK: - Network

    private func performRequest(body: CURequest) async throws -> CUResponse {
        return try await performRequest(body: body, retriesRemaining: 3)
    }

    /// Mirrors `ClaudeLLMClient.performRequest`'s retry ladder so CU and
    /// the standard action LLM have identical resilience to transient API
    /// failures. 429/529 → 1/5/30s backoff; 5xx → 2s ×3.
    private func performRequest(body: CURequest, retriesRemaining: Int) async throws -> CUResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(cuToolVersion.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.api("Non-HTTP response from Anthropic.")
        }
        if http.statusCode == 429 || http.statusCode == 529 {
            if retriesRemaining > 0 {
                let delay: Double = retriesRemaining == 3 ? 1 : retriesRemaining == 2 ? 5 : 30
                try await Task.sleep(for: .seconds(delay))
                return try await performRequest(body: body, retriesRemaining: retriesRemaining - 1)
            }
            throw LLMError.rateLimited
        }
        if http.statusCode >= 500 {
            if retriesRemaining > 0 {
                // Match ClaudeLLMClient.performRequest and AGENTS.md §LLM Client:
                // 5xx → 2s flat × 3 retries. Pre-fix this read 800ms — the
                // "mirrors" comment above was wrong, and the divergence meant
                // CU + standard runs had different transient-error recovery
                // characteristics under the same Anthropic backend hiccup.
                try await Task.sleep(for: .seconds(2))
                return try await performRequest(body: body, retriesRemaining: retriesRemaining - 1)
            }
            let bodyText = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw LLMError.api("ComputerUseClient: Anthropic 5xx after retries — \(http.statusCode): \(bodyText.prefix(200))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw LLMError.api("HTTP \(http.statusCode): \(bodyText.prefix(200))")
        }
        return try JSONDecoder().decode(CUResponse.self, from: data)
    }
}

// MARK: - Wire types

private struct CURequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [CUMessage]
    let tools: [CUTool]
    let toolChoice: CUToolChoice

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
    }
}

private struct CUToolChoice: Encodable {
    let type: String
}

private struct CUTool: Encodable {
    let type: String
    let name: String
    let displayWidthPx: Int
    let displayHeightPx: Int

    enum CodingKeys: String, CodingKey {
        case type, name
        case displayWidthPx = "display_width_px"
        case displayHeightPx = "display_height_px"
    }

    static func computer(version: ComputerUseClient.CUToolVersion, width: Int, height: Int) -> CUTool {
        CUTool(type: version.toolTypeName, name: "computer",
               displayWidthPx: width, displayHeightPx: height)
    }
}

// `internal` so unit tests can construct fake histories and exercise
// `applyHistoryCap` directly. The struct is not exported from MacAgentCore
// because it's only used in the CU request/response shape.
internal struct CUMessage: Codable {
    let role: String
    let content: [CUContent]
}

// `internal` (not `private`) so `ComputerUseTranslateTests` can assert
// `tool_result` decode behavior via `@testable import`.
enum CUContent: Codable {
    case text(String)
    case image(mediaType: String, data: String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(toolUseID: String, content: [CUContent])

    var type: String? {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .toolUse: return "tool_use"
        case .toolResult: return "tool_result"
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKey2.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let mt, let data):
            try c.encode("image", forKey: .type)
            var src = c.nestedContainer(keyedBy: CodingKey2.self, forKey: .source)
            try src.encode("base64", forKey: .type)
            try src.encode(mt, forKey: .mediaType)
            try src.encode(data, forKey: .data)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseID, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKey2.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            // Responses rarely include raw images; minimal impl.
            self = .text("<image>")
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = (try? c.decode([String: AnyCodable].self, forKey: .input)) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        case "tool_result":
            // Anthropic's API normally puts tool_result blocks in user
            // messages, not assistant responses. We round-trip them anyway
            // so re-encoding history doesn't lossily-degrade to text if an
            // assistant message ever echoes one back.
            let id = try c.decode(String.self, forKey: .toolUseId)
            let content = (try? c.decode([CUContent].self, forKey: .content)) ?? []
            self = .toolResult(toolUseID: id, content: content)
        default:
            self = .text("(unknown content type: \(type))")
        }
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    enum CodingKey2: String, CodingKey {
        case type, text, source, mediaType = "media_type"
        case data, id, name, input, toolUseId = "tool_use_id", content
    }
}

private struct CUResponse: Decodable {
    let content: [CUContent]
}

// MARK: - AnyCodable (local copy, mirrors the one in LLMClient)

/// `@unchecked Sendable` is safe here because: `value` is `Any` carrying only
/// Codable scalars / collections built at decode time and never mutated. Sending
/// an `AnyCodable` across actor boundaries (which ComputerUseClient does when
/// decoding Anthropic responses inside an async actor) cannot expose mutation
/// because there is no mutating API. Per AGENTS.md "Document why the invariant
/// is safe".
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Mirror LLMClient.AnyDecodable order exactly: decodeNil → Int → Double →
        // Bool → String → Array → Dict → throw. Int before Bool/Double matches
        // Foundation's strict-typed decoding (Foundation's JSONDecoder does NOT
        // coerce 1↔true; the order is for performance and predictability parity
        // with the LLM-side decoder so future copy-paste bugs stay aligned.
        if c.decodeNil() { value = NSNull(); return }
        if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues(\.value) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]:  try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

