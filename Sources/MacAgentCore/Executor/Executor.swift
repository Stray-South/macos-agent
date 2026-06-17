import AppKit
import ApplicationServices
import Foundation

public enum ExecutorError: Error, LocalizedError, Sendable {
    /// The action is malformed — no targetIndex and no coordinate. There's
    /// nothing to act on; the LLM emitted an incoherent action. Distinct
    /// from `.targetStale` so the Orchestrator's recovery loop can branch
    /// on the cause (the recovery prompt for malformed is different from
    /// the prompt for "your index is stale, re-observe").
    case missingTarget
    /// Unit 14 — the LLM emitted a targetIndex that no longer points to a
    /// real element. Carries the context the Orchestrator's recovery
    /// prompt needs to give the LLM a specific hint:
    ///   - requestedIndex: what the LLM picked
    ///   - elementCount: how many elements the current snapshot has
    ///     (AX path) or the vision-observations count if the index
    ///     pointed into the vision range
    ///   - lastKnownLabel: if the requested AX-index was once valid in a
    ///     prior snapshot, the label we can hint at. Vision-index path
    ///     leaves this nil — observation text is the "label" equivalent
    ///     but we don't carry prior-snapshot history here.
    case targetStale(actionType: ActionType, requestedIndex: Int, elementCount: Int, lastKnownLabel: String?)
    /// Unit 18B — the LLM emitted an action against an element that
    /// IS in the current snapshot (or menu hierarchy) but is currently
    /// disabled (greyed out, modal loading, required-field-not-filled,
    /// etc.). Distinct from `.targetStale` because the element exists
    /// and may become interactable once a precondition is satisfied —
    /// the recovery prompt should suggest "pick a different element OR
    /// satisfy the enabling condition," not "the element is gone."
    ///
    ///   - actionType: what the LLM tried to do (.click, .menuSelect, …)
    ///   - requestedIndex: the AX index (nil for menu-path disabled —
    ///     menus are addressed by label path, not index)
    ///   - label: the element label OR the menu-item title that was
    ///     disabled. Always populated so the recovery prompt can name it.
    case targetDisabled(actionType: ActionType, requestedIndex: Int?, label: String?)
    case unsupportedAction
    case invalidKeyCombo
    /// Unit 40 — the operator clicked into a different app between the
    /// snapshot and this keystroke action, so the frontmost app no longer
    /// matches the app the snapshot was perceived against. A typeText /
    /// keyCombo / holdKey lands in whatever is frontmost, so executing now
    /// would inject keystrokes into the operator's app. The agent YIELDS:
    /// the orchestrator re-observes against the new reality and never
    /// re-asserts focus (it does not steal the app back from the operator).
    case frontmostDrifted(actionType: ActionType, expectedApp: String, liveApp: String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingTarget:
            return "The requested target element could not be resolved."
        case .targetStale(let actionType, let idx, let count, let label):
            let labelHint = label.map { " (previously labelled '\($0)')" } ?? ""
            return "Element at index \(idx) is no longer in the snapshot (current snapshot has \(count) elements)\(labelHint). The action '\(actionType.rawValue)' cannot proceed against a stale index — re-observe before retrying."
        case .targetDisabled(let actionType, let idx, let label):
            let labelPart = label.map { "'\($0)'" } ?? "(unlabelled)"
            if let idx {
                return "Element at index \(idx) labelled \(labelPart) is in the snapshot but currently disabled (greyed out, not yet interactable). The action '\(actionType.rawValue)' cannot proceed — pick a different element OR satisfy the enabling condition first (e.g. fill required fields before pressing Submit)."
            } else {
                return "Menu item \(labelPart) is disabled. Pick a different menu path OR satisfy the enabling condition first."
            }
        case .unsupportedAction:
            return "The requested action is not supported."
        case .invalidKeyCombo:
            return "The key combo format is invalid."
        case .frontmostDrifted(let actionType, let expectedApp, let liveApp):
            return "The user switched the frontmost app from \(expectedApp) to \(liveApp) before the \(actionType.rawValue) could run. Yielding instead of typing into their app."
        case .executionFailed(let message):
            return message
        }
    }
}

/// Protocol for the action executor — enables test injection without coupling
/// callers to the concrete `Executor` struct.
public protocol ActionPerforming: Sendable {
    func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String
}

public struct Executor: ActionPerforming, Sendable {
    // Injected for tests; production default is 1 second.
    let waitDuration: Duration
    // Optional click-feedback hook — called after each click so the UI can
    // show cursor ripples without coupling the executor to a specific overlay
    // implementation. The mirrored `onKeystrokeAction` hook was removed
    // 2026-05-23 when `KeystrokeOverlayController` was deleted; typed-text
    // surfacing now goes through the conversation thread directly from
    // `AppModel.handle(.proposed)`.
    let onCursorAction: (@Sendable (CGPoint) async -> Void)?
    /// Opt-in fast paste path for typeText > 20 characters. When true the
    /// executor writes the payload to NSPasteboard.general and emits cmd+v,
    /// restoring the user's clipboard after a ~150ms paste window. Default
    /// false — typing all keystrokes via CGEventKeyboardSetUnicodeString is
    /// slower (~3-5x for long text) but never touches the system clipboard,
    /// so other apps and clipboard-monitor tools can't observe the payload.
    let useFastPasteForLongText: Bool
    /// Unit 36/36a — resolves the sandbox root at EACH write (nil = writeFile
    /// disabled, the opt-in default). A provider, not a captured value: the
    /// Executor is reused across runs, so capturing the flag would let a
    /// write keep working after the operator disabled the workspace until an
    /// unrelated orchestrator rebuild. Read live, the toggle takes effect on
    /// the very next write.
    let workspaceRootProvider: @Sendable () -> URL?

    public init(
        waitDuration: Duration = .seconds(1),
        onCursorAction: (@Sendable (CGPoint) async -> Void)? = nil,
        useFastPasteForLongText: Bool = false,
        workspaceRoot: URL? = nil,
        workspaceRootProvider: (@Sendable () -> URL?)? = nil
    ) {
        self.waitDuration = waitDuration
        self.onCursorAction = onCursorAction
        self.useFastPasteForLongText = useFastPasteForLongText
        // Back-compat: a static workspaceRoot (used by tests) becomes a
        // constant provider; production passes a live provider.
        self.workspaceRootProvider = workspaceRootProvider ?? { workspaceRoot }
    }

    public func perform(_ action: AgentAction, snapshot: ObservedSnapshot) async throws -> String {
        // Fetch the display scale factor on the main thread once per action.
        // NSScreen.main is @MainActor-isolated; reading it off-thread is a data race in Swift 6.
        let displayScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1.0 }
        // Unit 28 — agent-frontmost backstop for keystroke-injecting actions.
        // menuSelect already guards (performMenuSelect); typeText/keyCombo/
        // holdKey synthesize CGEvents that land in whatever is frontmost, so
        // if the agent itself is frontmost (e.g. right after an in-window
        // approval that stole focus) the keystrokes would corrupt the agent's
        // own composer instead of the target app. Block and tell the LLM to
        // switchApp first. Test-safe: agentProcessID is the agent's real PID,
        // never the `swift test` harness's frontmost process.
        if Self.isFrontmostSensitive(action.type) {
            let front = await MainActor.run { () -> (pid: pid_t, bundleID: String?)? in
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return (app.processIdentifier, app.bundleIdentifier)
            }
            if let front, let guardErr = Self.agentFrontmostGuardError(actionType: action.type, frontPID: front.pid) {
                throw guardErr
            }
            // Unit 40/40a — operator-drift guard. The snapshot was perceived
            // against `snapshot.snapshot.focusedAppBundleID`; if the operator
            // switched into a DIFFERENT app since, this keystroke / positional
            // click would land in their app. Yield (the orchestrator
            // re-observes; it never steals focus back). Gated on the expected
            // app STILL RUNNING: in production the operator switched away from
            // but didn't quit it (running → guard fires); a test fixture
            // ("com.example.app") is not running (guard inert) — same
            // test-safety strategy as the agent-frontmost guard.
            let expectedRunning = await MainActor.run(body: {
                Self.isAppRunning(bundleID: snapshot.snapshot.focusedAppBundleID)
            })
            if let err = Self.frontmostDriftError(
                actionType: action.type,
                expectedApp: snapshot.snapshot.focusedAppBundleID,
                liveBundle: front?.bundleID,
                expectedRunning: expectedRunning) {
                throw err
            }
        }
        switch action.type {
        case .click:
            let point = try await performClick(action, snapshot: snapshot, scale: displayScale, clickState: .leftMouseDown, upState: .leftMouseUp)
            await onCursorAction?(point)
            return "clicked"
        case .doubleClick:
            let point = try await performMultiClick(action, snapshot: snapshot, scale: displayScale, clickCount: 2)
            await onCursorAction?(point)
            return "double-clicked"
        case .tripleClick:
            let point = try await performMultiClick(action, snapshot: snapshot, scale: displayScale, clickCount: 3)
            await onCursorAction?(point)
            return "triple-clicked"
        case .rightClick:
            let point = try await performClick(action, snapshot: snapshot, scale: displayScale, clickState: .rightMouseDown, upState: .rightMouseUp)
            await onCursorAction?(point)
            return "right-clicked"
        case .typeText:
            try await performType(action, snapshot: snapshot, scale: displayScale)
            return "typed text"
        case .scroll:
            try performScroll(action, snapshot: snapshot, scale: displayScale)
            return "scrolled"
        case .keyCombo:
            try performKeyCombo(action)
            return "key combo sent"
        case .menuSelect:
            try await performMenuSelect(action)
            return "menu item selected"
        case .wait:
            try await Task.sleep(for: waitDuration)
            return "waited"
        case .undo:
            // Synthesize cmd+z via the existing performKeyCombo path — no new key event code.
            let undoAction = AgentAction(type: .keyCombo, text: "cmd+z",
                                         confidence: 1.0, requiresConfirmation: false,
                                         rationale: "Undo last action")
            try performKeyCombo(undoAction)
            return "undo sent (cmd+z)"
        case .complete:
            return "task complete"
        case .clarify:
            return "clarification requested"
        case .readClipboard:
            let content = NSPasteboard.general.string(forType: .string) ?? ""
            if content.isEmpty { return "clipboard is empty" }
            // Cap before the content enters receipts + conversation history —
            // a multi-megabyte clipboard would blow up the prompt and the
            // audit file. 4000 chars is plenty for the read-then-use flows.
            let capped = content.count > 4000
                ? String(content.prefix(4000)) + "\n…(clipboard truncated at 4000 chars)"
                : content
            return "clipboard contents:\n\(capped)"
        case .say:
            // No OS action — the message (in rationale) is surfaced by the
            // orchestrator as .agentSaid; the receipt records the action.
            return "said"
        case .writeFile:
            return try performWriteFile(action)
        case .switchApp:
            return try await performSwitchApp(action)
        case .drag:
            try await performDrag(action)
            return "dragged"
        case .holdKey:
            try await performHoldKey(action)
            return "held key"
        case .mouseDown:
            let point = try await performMouseDown(action)
            await onCursorAction?(point)
            return "mouse button pressed (held)"
        case .mouseUp:
            let point = try await performMouseUp(action)
            await onCursorAction?(point)
            return "mouse button released"
        case .mouseMove:
            let (point, wasDrag) = try await performMouseMove(action)
            await onCursorAction?(point)
            return wasDrag ? "mouse dragged" : "mouse moved"
        }
    }

    /// N-click via mouseEventClickState. Used by .doubleClick (count=2) and
    /// .tripleClick (count=3). macOS's text-selection state machine reads the
    /// clickState field to escalate from word → line selection, etc.
    @discardableResult
    private func performMultiClick(_ action: AgentAction, snapshot: ObservedSnapshot, scale: CGFloat, clickCount: Int) async throws -> CGPoint {
        // 13b chokepoint — release any prior hold before posting a new
        // leftMouseDown. See `releasePriorHoldIfAny` rationale.
        await releasePriorHoldIfAny()
        let point: CGPoint
        switch try resolveTarget(action, snapshot: snapshot, scale: scale) {
        case .ax(_, let frame): point = frame.cgRect.center
        case .vision(let p, _): point = p
        case .coordinate(let p): point = p
        }
        for state in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw ExecutorError.executionFailed("Failed to create multi-click event at state \(state).")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(state))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(state))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return point
    }

    // Returns the screen point used for the click (for cursor ripple feedback).
    // Throws on failure; always returns a valid point on success.
    @discardableResult
    private func performClick(
        _ action: AgentAction,
        snapshot: ObservedSnapshot,
        scale: CGFloat,
        clickState: CGEventType,
        upState: CGEventType
    ) async throws -> CGPoint {
        // 13b chokepoint — release any prior hold before posting a new
        // mouseDown (left or right). See `releasePriorHoldIfAny` rationale.
        // Safe to run even when the AX press path is taken: release is
        // idempotent when nothing's held.
        await releasePriorHoldIfAny()
        let button: CGMouseButton = clickState == .rightMouseDown ? .right : .left
        // Per Anthropic CU docs, a click can hold modifier keys via action.modifiers
        // (e.g. "shift" for shift-click, "cmd+shift" for cmd-shift-click). Applied to
        // both down and up events; nil = no modifiers (existing behavior).
        let flags = action.modifiers.map { modifierFlags(for: $0.split(separator: "+").map { String($0).lowercased() }) }
        switch try resolveTarget(action, snapshot: snapshot, scale: scale) {
        case .ax(let element, let frame):
            let point = frame.cgRect.center
            // Try the accessibility action first when no modifiers (AX press doesn't
            // carry modifier state). With modifiers, fall through to CGEvent path so
            // flags apply.
            if clickState == .leftMouseDown && flags == nil {
                // AXUIElementPerformAction must run on the main thread on macOS 26+.
                // SwiftUI button callbacks use MainActor.assumeIsolated internally;
                // calling from a background actor triggers EXC_BREAKPOINT (dispatch_assert_queue_fail).
                let result = await MainActor.run { AXUIElementPerformAction(element, kAXPressAction as CFString) }
                if result == .success { return point }
                // AX press error class handling — see
                // `axPressFallthroughSafe` for the full classification.
                // `.actionUnsupported` / `.noValue` / `.attributeUnsupported`
                // fall through to CGEvent click at the element frame;
                // all other codes throw.
                if !Self.axPressFallthroughSafe(code: result) {
                    // Unit 14 — AX codes -25200 (illegalArgument) and -25202
                    // (invalidUIElement) signal that the AXUIElement handle
                    // is stale: the element existed when the snapshot was
                    // taken, but the UI has reflowed and the handle no
                    // longer addresses anything live. Receipt analysis
                    // (2026-05-23) shows these are the dominant runtime
                    // failure class alongside `.targetStale` from
                    // resolveTarget — bucket them into the same error so
                    // the Orchestrator's recovery prompt gives the LLM the
                    // specific "re-observe, your index is stale" hint
                    // rather than the generic recovery loop's vague text.
                    //
                    // `.cannotComplete` (-25201) intentionally NOT bucketed
                    // here: Apple docs describe it as "the action could not
                    // be completed at this moment" which is transient
                    // (AX server busy, animation in progress) — discarding
                    // the valid index would over-correct. Falls through to
                    // `.executionFailed` so the generic recovery retries.
                    if result == .invalidUIElement || result == .illegalArgument {
                        // Invariant: this branch is only reachable from the
                        // `.ax(...)` arm of `resolveTarget`, which requires
                        // `action.targetIndex` to be non-nil and in-bounds.
                        // The guard surfaces the invariant — if a future
                        // refactor reaches this code without an index, fail
                        // loudly rather than emit a nonsense "-1" receipt.
                        guard let idx = action.targetIndex else {
                            throw ExecutorError.executionFailed(
                                "Internal invariant: AX press error \(result.rawValue) with nil targetIndex (should not be reachable)."
                            )
                        }
                        let label: String? = (idx < snapshot.snapshot.elements.count)
                            ? snapshot.snapshot.elements[idx].label
                            : nil
                        throw ExecutorError.targetStale(
                            actionType: action.type,
                            requestedIndex: idx,
                            elementCount: snapshot.snapshot.elements.count,
                            lastKnownLabel: label
                        )
                    }
                    throw ExecutorError.executionFailed("Accessibility press failed with code \(result.rawValue).")
                }
            }
            guard let down = CGEvent(mouseEventSource: nil, mouseType: clickState, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upState, mouseCursorPosition: point, mouseButton: button) else {
                throw ExecutorError.executionFailed("Failed to create mouse click event.")
            }
            if let flags { down.flags = flags; up.flags = flags }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return point
        case .vision(let point, _):
            guard let down = CGEvent(mouseEventSource: nil, mouseType: clickState, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upState, mouseCursorPosition: point, mouseButton: button) else {
                throw ExecutorError.executionFailed("Failed to create vision click event.")
            }
            if let flags { down.flags = flags; up.flags = flags }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return point
        case .coordinate(let point):
            guard let down = CGEvent(mouseEventSource: nil, mouseType: clickState, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upState, mouseCursorPosition: point, mouseButton: button) else {
                throw ExecutorError.executionFailed("Failed to create coordinate click event.")
            }
            if let flags { down.flags = flags; up.flags = flags }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return point
        }
    }

    // Type `action.text` via CGEvent. Returns Void as of 2026-05-23 — the
    // truncated display string was previously consumed by the now-deleted
    // `onKeystrokeAction` callback. The conversation thread now renders
    // typed-text payloads directly from `AppModel.handle(.proposed)`.
    private func performType(_ action: AgentAction, snapshot: ObservedSnapshot, scale: CGFloat) async throws {
        guard let text = action.text else {
            throw ExecutorError.executionFailed("Missing text payload for typeText action.")
        }
        // For vision targets there is no AXUIElement to focus; text is typed into whatever
        // currently has keyboard focus. This is intentional: Electron apps with no AX tree
        // rely on the user having clicked the field first (or the agent having done so).
        if let resolved = try? resolveTarget(action, snapshot: snapshot, scale: scale) {
            switch resolved {
            case .ax(let element, _):
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                // Let the focus change settle before keystrokes fire.
                try? await Task.sleep(for: .milliseconds(50))
            case .coordinate(let point):
                // WARNING: focus is best-effort. We click the coordinate to try to focus
                // the underlying control, but if the click lands on a non-focusable region
                // the keystrokes that follow will go to whatever already has key-window
                // focus. CU pipelines should prefer typeText with a resolved targetIndex
                // (AX path sets kAXFocusedAttribute directly) when an element is known.
                //
                // 13b chokepoint — release any prior hold before posting
                // the focus-click's leftMouseDown. Defense-in-depth for
                // the case where .typeText reaches this branch while a
                // `.mouseDown` is still held; the held-mouse safety
                // invariant already escalates this to .confirm, but the
                // chokepoint is the actual OS-side cleanup.
                await releasePriorHoldIfAny()
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                   let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                // Let the click-focus settle before keystrokes fire.
                try? await Task.sleep(for: .milliseconds(50))
            case .vision:
                break
            }
        }

        if text.count > 20 && useFastPasteForLongText {
            // OPT-IN fast paste path. Disabled by default because the payload
            // briefly inhabits NSPasteboard.general where any clipboard-monitor
            // app (Paste, Maccy, screen readers, malware) can read it during
            // the ~150ms paste window. The save/restore dance below limits
            // user-visible disruption but not exfiltration risk.
            //
            // Intra-process serialization isn't needed: Executor.perform is
            // awaited sequentially per Orchestrator, and there is one
            // Orchestrator per AppModel. The prior NSLock was defensive
            // against a multi-executor topology that doesn't exist.

            // Deep-copy all pasteboard items so we can restore them after paste.
            let savedItems = NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            } ?? []

            defer {
                NSPasteboard.general.clearContents()
                if !savedItems.isEmpty { NSPasteboard.general.writeObjects(savedItems) }
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            try performKeyCombo(AgentAction(type: .keyCombo, text: "cmd+v", confidence: 1, requiresConfirmation: false, rationale: "Paste text"))

            // Wait for the paste to land before the defer restores the clipboard.
            // Task.sleep, not Thread.sleep — don't block the cooperative pool.
            try? await Task.sleep(for: .milliseconds(150))
        } else {
            // Default path: type every character via CGEventKeyboardSetUnicodeString.
            // ~3-5x slower than the paste path for long text but never touches the
            // system clipboard, so passwords / 2FA codes / personal text typed
            // via the agent are not observable by clipboard-monitor processes.
            //
            // 1ms intra-char yield: Terminal, vim insert-mode, and TextEdit on
            // macOS 14+ drop characters under sustained back-to-back HID posts
            // with no inter-event delay. The sleep is cheap (cooperative pool,
            // no thread block) and an order of magnitude smaller than the paste
            // path's settle window — long-text typing remains usable.
            for scalar in text.unicodeScalars {
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                    throw ExecutorError.executionFailed("Failed to create keyboard events.")
                }
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar.value].map(UniChar.init))
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [scalar.value].map(UniChar.init))
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

    }

    private func performScroll(_ action: AgentAction, snapshot: ObservedSnapshot, scale: CGFloat) throws {
        // If the action targets a specific element, warp the cursor to its centre first
        // so the scroll is delivered to the right view (scroll events are position-sensitive on macOS).
        if let resolved = try? resolveTarget(action, snapshot: snapshot, scale: scale) {
            let centre: CGPoint
            switch resolved {
            case .ax(_, let frame): centre = frame.cgRect.center
            case .vision(let point, _): centre = point
            case .coordinate(let point): centre = point
            }
            // Find the display that contains the target element and warp the cursor
            // to it, so the scroll event is delivered to the correct screen on
            // multi-monitor setups. Falls back to the main display.
            var displayID: CGDirectDisplayID = CGMainDisplayID()
            var displayCount: UInt32 = 0
            if CGGetDisplaysWithPoint(centre, 1, &displayID, &displayCount) != .success || displayCount == 0 {
                displayID = CGMainDisplayID()
            }
            CGDisplayMoveCursorToPoint(displayID, centre)
        }
        let delta = action.scrollDelta?.cgPoint ?? .zero
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(delta.y),
            wheel2: Int32(delta.x),
            wheel3: 0
        ) else {
            throw ExecutorError.executionFailed("Failed to create scroll event.")
        }
        if let mods = action.modifiers {
            event.flags = modifierFlags(for: mods.split(separator: "+").map { String($0).lowercased() })
        }
        event.post(tap: .cghidEventTap)
    }

    // Post a key-combo CGEvent. Returns Void as of 2026-05-23 — same
    // rationale as `performType` above (display-string consumer deleted).
    private func performKeyCombo(_ action: AgentAction) throws {
        guard let combo = action.text?.lowercased() else {
            throw ExecutorError.invalidKeyCombo
        }
        let parts = combo.split(separator: "+").map(String.init)
        guard let key = parts.last, let keyCode = keyMap[key] else {
            throw ExecutorError.invalidKeyCombo
        }

        let flags = modifierFlags(for: Array(parts.dropLast()))
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw ExecutorError.executionFailed("Failed to create key combo events.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func performMenuSelect(_ action: AgentAction) async throws {
        guard let text = action.text else {
            throw ExecutorError.executionFailed("Missing menu path.")
        }
        // Path components separated by ">": e.g. "File > New Note" → ["file", "new note"]
        let path = text.split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !path.isEmpty else { throw ExecutorError.executionFailed("Menu path is empty.") }
        // NSWorkspace.shared.frontmostApplication is @MainActor-isolated; hop
        // and snapshot just the PID.
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard let frontPID else {
            throw ExecutorError.executionFailed("No frontmost app available.")
        }
        // Unit 11 — sibling of Unit 10's self-switch guard. If the agent is
        // frontmost, walking its own menu bar produces no useful result
        // (SwiftUI MenuBarExtra doesn't expose standard AX menus → "Could
        // not resolve menu bar"). Surface an actionable error that the
        // orchestrator's recovery prompt can route the LLM to switchApp
        // first, instead of looping on menu-bar lookups against ourselves.
        if let blockingError = Self.menuSelectAgentGuardError(frontPID: frontPID) {
            throw blockingError
        }
        let appElement = AXUIElementCreateApplication(frontPID)
        guard let menuBar = attributeElement(kAXMenuBarAttribute as CFString, on: appElement) else {
            throw ExecutorError.executionFailed("Could not resolve menu bar.")
        }

        // Traverse the menu hierarchy level by level.
        // path[0] matches a top-level menu bar item; path[1] matches its child; etc.
        var current: AXUIElement = menuBar
        var traversed: [String] = []
        for (level, component) in path.enumerated() {
            // For levels > 0, press the current item to open its submenu, then poll
            // until children are populated (up to 1 second, checking every 50 ms).
            if level > 0 {
                AXUIElementPerformAction(current, kAXPressAction as CFString)
                var waited = 0.0
                while waited < 1.0 {
                    try? await Task.sleep(for: .milliseconds(50))
                    waited += 0.05
                    let kids = attributeArray(kAXChildrenAttribute as CFString, on: current) ?? []
                    if !kids.isEmpty { break }
                }
            }

            let children = attributeArray(kAXChildrenAttribute as CFString, on: current) ?? []

            // Exact match against the normalised title — affordance markers ("…",
            // "...", "▸", trailing whitespace) are trimmed from both sides before
            // comparison so "File > New" still matches "New…" but "Edit > delete"
            // no longer fuzzy-matches "Delete All". Substring fallback removed:
            // ambiguous LLM paths now force a replan rather than silently picking
            // the first child whose label contains the requested token.
            func titleOf(_ child: AXUIElement) -> String {
                (attributeString(kAXTitleAttribute as CFString, on: child)
                    ?? attributeString(kAXDescriptionAttribute as CFString, on: child)
                    ?? "").lowercased()
            }
            let titles = children.map { titleOf($0) }
            guard let matchIdx = Self.matchMenuItem(component: component, titles: titles) else {
                AXUIElementPerformAction(menuBar, kAXCancelAction as CFString)
                let walked = (traversed + [component]).joined(separator: " > ")
                throw ExecutorError.executionFailed(
                    "Menu item '\(component)' not found at level \(level). Path walked: \(walked). Available: \(titles.joined(separator: ", "))"
                )
            }
            let match = children[matchIdx]

            let matchedTitle = titleOf(match)
            traversed.append(matchedTitle)

            if level == path.count - 1 {
                // Final component — press it.
                let isEnabled = attributeBool(kAXEnabledAttribute as CFString, on: match) ?? true
                guard isEnabled else {
                    AXUIElementPerformAction(menuBar, kAXCancelAction as CFString)
                    // Unit 18B — distinct error class so Orchestrator
                    // recovery prompt names the disabled menu item and
                    // tells the LLM to either satisfy the enabling
                    // condition (fill required fields, etc.) OR pick a
                    // different menu path. Generic recovery prompt
                    // ("retry") would not help — the menu item won't
                    // become enabled just by retrying.
                    throw ExecutorError.targetDisabled(
                        actionType: .menuSelect,
                        requestedIndex: nil,
                        label: matchedTitle
                    )
                }
                let result = AXUIElementPerformAction(match, kAXPressAction as CFString)
                if result != .success {
                    throw ExecutorError.executionFailed(
                        "Menu press failed for '\(matchedTitle)' (AX code \(result.rawValue))."
                    )
                }
            } else {
                // Intermediate component — descend into it.
                current = match
            }
        }
    }

    /// Click-and-drag from `action.startCoordinate` to `action.coordinate`.
    /// Composes mouseDown(start) → 10 intermediate mouseDragged samples along
    /// the straight-line path → mouseUp(end). 10 samples is a reasonable
    /// median for smoothness vs. throughput; tunable via `dragSampleCount`.
    private func performDrag(_ action: AgentAction) async throws {
        guard let start = action.startCoordinate?.cgPoint,
              let end = action.coordinate?.cgPoint else {
            throw ExecutorError.executionFailed("drag requires startCoordinate and coordinate (got start=\(String(describing: action.startCoordinate)), end=\(String(describing: action.coordinate)))")
        }
        // 13b chokepoint — release any prior hold before posting a new
        // leftMouseDown. See `releasePriorHoldIfAny` rationale.
        await releasePriorHoldIfAny()
        let flags = action.modifiers.map { modifierFlags(for: $0.split(separator: "+").map { String($0).lowercased() }) }
        let dragSampleCount = 10
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw ExecutorError.executionFailed("Failed to create drag mouseDown event.")
        }
        if let flags { down.flags = flags }
        down.post(tap: .cghidEventTap)
        for step in 1...dragSampleCount {
            let t = Double(step) / Double(dragSampleCount)
            let p = CGPoint(x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t)
            guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) else {
                throw ExecutorError.executionFailed("Failed to create drag intermediate event at step \(step).")
            }
            if let flags { drag.flags = flags }
            drag.post(tap: .cghidEventTap)
            // ~20ms between drag samples gives macOS's DnD state machine time
            // to engage (Finder, between-app drag-and-drop) and yields the
            // cooperative pool so other actor work isn't starved during the
            // ~200ms total drag duration.
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            throw ExecutorError.executionFailed("Failed to create drag mouseUp event.")
        }
        if let flags { up.flags = flags }
        up.post(tap: .cghidEventTap)
        await onCursorAction?(end)
    }

    /// Hold a single key down for `action.durationMs` milliseconds, then release.
    /// The keyUp is in a `defer` block so a task cancellation mid-sleep still
    /// releases the key — load-bearing for not leaving the user's keyboard
    /// stuck in a modifier-held state. Duration is clamped to [0, 30000].
    private func performHoldKey(_ action: AgentAction) async throws {
        guard let combo = action.text?.lowercased() else {
            throw ExecutorError.invalidKeyCombo
        }
        // Same parse path as performKeyCombo — split on "+" to support
        // modifier-prefixed holds (`shift+a`, `cmd+option+w`) even though the
        // common case is a single key.
        let parts = combo.split(separator: "+").map(String.init)
        guard let key = parts.last, let keyCode = keyMap[key] else {
            throw ExecutorError.invalidKeyCombo
        }
        let flags = modifierFlags(for: Array(parts.dropLast()))
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw ExecutorError.executionFailed("Failed to create holdKey events.")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        // defer fires before any subsequent throw OR on task cancellation,
        // guaranteeing keyUp posts regardless of how the function exits.
        defer { up.post(tap: .cghidEventTap) }
        let duration = max(0, min(action.durationMs ?? 0, 30_000))
        // `try await` (not `try?`) so a cancellation during the held-key sleep
        // throws CancellationError and propagates to the Orchestrator's
        // checkCancellation loop. Pre-fix `try?` swallowed the cancel, the
        // defer still released the key, but the function returned normally —
        // the orchestrator couldn't tell the action was cut short, so the
        // receipt was written as a successful held-key for whatever duration
        // had elapsed. Now: receipt reflects the cancellation outcome.
        try await Task.sleep(for: .milliseconds(duration))
    }

    /// Unit 13b — stateful mouse. Press the left mouse button at
    /// `action.coordinate` and HOLD until a matching `.mouseUp`, the
    /// 30 s watchdog inside `MouseHoldState`, or an Orchestrator
    /// terminal-event cleanup releases it. The CGEvent is posted first;
    /// only on successful allocation do we mark the singleton held —
    /// so a CGEvent failure can't leave the tracker out of sync with
    /// the OS-side button state.
    private func performMouseDown(_ action: AgentAction) async throws -> CGPoint {
        guard let point = action.coordinate?.cgPoint else {
            throw ExecutorError.executionFailed("mouseDown requires a coordinate.")
        }
        // Reviewer-caught Sev-1: see `releasePriorHoldIfAny()` for the
        // full rationale. Same chokepoint applies to performDrag /
        // performClick / performMultiClick — any CGEvent leftMouseDown
        // post must first release a prior hold.
        await releasePriorHoldIfAny()
        let flags = action.modifiers.map {
            modifierFlags(for: $0.split(separator: "+").map { String($0).lowercased() })
        }
        // LMB only — Anthropic CU exposes left_mouse_down only on the
        // current tool spec. Right/middle paths are wired in MouseHoldState
        // for forward-compat but not reachable from the translator yet.
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw ExecutorError.executionFailed("Failed to create mouseDown event.")
        }
        if let flags { down.flags = flags }
        down.post(tap: .cghidEventTap)
        // markHeld AFTER post — if CGEvent allocation had thrown above
        // the tracker would be unchanged, matching reality.
        await MouseHoldState.shared.markHeld(button: .left, at: point)
        return point
    }

    /// Unit 13b — release the currently held button. We delegate
    /// posting the up-event to `MouseHoldState.release()` so the
    /// watchdog and the Orchestrator cleanup share one path. If the
    /// LLM emits mouseUp with a different coordinate than the original
    /// press, we update the tracker first so the released up-event
    /// lands at the LLM's chosen point.
    private func performMouseUp(_ action: AgentAction) async throws -> CGPoint {
        guard let point = action.coordinate?.cgPoint else {
            throw ExecutorError.executionFailed("mouseUp requires a coordinate.")
        }
        guard await MouseHoldState.shared.isHeld() else {
            throw ExecutorError.executionFailed(
                "mouseUp called with no button held. Emit mouseDown first, " +
                "or use .click for a single-shot press+release."
            )
        }
        await MouseHoldState.shared.updateCoordinate(point)
        _ = await MouseHoldState.shared.release()
        return point
    }

    /// Unit 13b — move the cursor. When a button is held, posts a
    /// `mouseDragged` event so drag-aware UIs (Finder, slider grabs,
    /// text-selection) see the in-flight drag; the held-button identity
    /// is preserved via the tracker. When no button is held, posts a
    /// `mouseMoved` event so hover-state UIs (tooltips, menu submenus)
    /// fire correctly. Returns the point + whether it was a drag for
    /// the caller's executionResult label.
    private func performMouseMove(_ action: AgentAction) async throws -> (CGPoint, Bool) {
        guard let point = action.coordinate?.cgPoint else {
            throw ExecutorError.executionFailed("mouseMove requires a coordinate.")
        }
        let heldButton = await MouseHoldState.shared.currentHeldButton()
        let isDrag = heldButton != nil
        let mouseType: CGEventType
        if let heldButton {
            switch heldButton {
            case .right: mouseType = .rightMouseDragged
            case .center: mouseType = .otherMouseDragged
            default:     mouseType = .leftMouseDragged
            }
        } else {
            mouseType = .mouseMoved
        }
        guard let move = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: point,
            mouseButton: heldButton ?? .left
        ) else {
            throw ExecutorError.executionFailed("Failed to create mouseMove event.")
        }
        move.post(tap: .cghidEventTap)
        if isDrag {
            // Update the tracker so the watchdog's eventual mouseUp (if it
            // fires) posts at the most-recent cursor position rather than
            // the original press point.
            await MouseHoldState.shared.updateCoordinate(point)
        }
        return (point, isDrag)
    }

    /// Unit 13b — Orchestrator terminal-cleanup chokepoint. Called from
    /// `run()`'s defer on every exit path (success, failure, abort,
    /// cancellation, step limit, stall) so a held mouse button cannot
    /// outlive the run. Idempotent via `MouseHoldState.release()`.
    public func releaseHeldInputs() async {
        _ = await MouseHoldState.shared.release()
    }

    /// Unit 13b — bug-class-fix chokepoint. Any code path that posts a
    /// CGEvent `leftMouseDown` (or `rightMouseDown` / `otherMouseDown`)
    /// MUST call this first. Without it, a `.drag` / `.click` / `.doubleClick`
    /// / `.tripleClick` / `.rightClick` action that runs while a prior
    /// `.mouseDown` is still held will post a phantom second down-event
    /// to the OS with no matching up-event for the first press —
    /// orphan held button, the OS-level user-lockout failure mode this
    /// subsystem exists to prevent.
    ///
    /// `MouseHoldState.release()` posts the up-event for the prior press
    /// at its tracked coordinate, then clears state. Cheap when nothing
    /// is held (the `isHeld()` guard makes the call a no-op + actor hop).
    ///
    /// Note: the held-mouse safety invariant (`heldMouseAdjusted`)
    /// already escalates every cross-cutting action to `.confirm`
    /// during a held session, so reaching this helper with a held state
    /// requires explicit user approval. The helper is defense-in-depth
    /// for the post-approval path.
    private func releasePriorHoldIfAny() async {
        if await MouseHoldState.shared.isHeld() {
            _ = await MouseHoldState.shared.release()
        }
    }

    /// Unit 36 — write `action.text` to `action.filePath`, confined to the
    /// opt-in workspace sandbox. Every escape vector is rejected BEFORE any
    /// write: feature disabled, missing/empty path, absolute path, parent
    /// traversal, and (after resolving symlinks) any path whose real location
    /// is outside the workspace root. The receipt records the path + a
    /// content hash, never the contents.
    private func performWriteFile(_ action: AgentAction) throws -> String {
        guard let root = workspaceRootProvider() else {
            throw ExecutorError.executionFailed("File writing is disabled. Enable the agent workspace in Settings to allow it.")
        }
        guard let rawPath = action.filePath, !rawPath.isEmpty else {
            throw ExecutorError.executionFailed("writeFile requires a filePath (relative to the agent workspace)")
        }
        // Reject absolute paths and any component that could climb out.
        guard !rawPath.hasPrefix("/"), !rawPath.hasPrefix("~") else {
            throw ExecutorError.executionFailed("writeFile path must be relative to the workspace, not absolute: \(rawPath)")
        }
        let components = rawPath.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw ExecutorError.executionFailed("writeFile path may not contain '..': \(rawPath)")
        }
        let rootStd = root.standardizedFileURL
        let target = rootStd.appendingPathComponent(rawPath).standardizedFileURL
        // Final containment check on the standardized path: the resolved
        // target must live under the workspace root. Compare path prefixes
        // with a trailing separator so "/workspace-evil" can't pass as
        // "/workspace".
        let rootPath = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"
        guard target.path.hasPrefix(rootPath) else {
            throw ExecutorError.executionFailed("writeFile path escapes the workspace: \(rawPath)")
        }
        let contents = action.text ?? ""
        let data = Data(contents.utf8)

        let dir = target.deletingLastPathComponent()
        // createDirectory does not follow a pre-existing symlink at `dir`;
        // but a symlinked ancestor could still redirect. Re-resolve symlinks
        // on the parent and re-check containment after creating it.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let resolvedDir = dir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = rootStd.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard (resolvedDir.path + "/").hasPrefix(resolvedRootPath) else {
            throw ExecutorError.executionFailed("writeFile path resolves outside the workspace via a symlink: \(rawPath)")
        }
        // 36a — reject a symlink AT THE LEAF. The parent re-check above does
        // not resolve the final component; a pre-existing leaf symlink
        // (workspace/evil.txt -> /outside/victim) was only blocked
        // accidentally by .atomic's temp+rename replacing the link. lstat the
        // target and refuse if it is a symlink, so the safety no longer rests
        // on the write mode. (O_NOFOLLOW is not reachable via Data.write.)
        if let isSymlink = try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
           isSymlink {
            throw ExecutorError.executionFailed("writeFile target is a symlink; refusing to follow it out of the workspace: \(rawPath)")
        }
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let hash = Hashing.sha256Hex(data)
        return "wrote \(data.count) bytes to workspace/\(rawPath) (sha256:\(hash.prefix(12)))"
    }

    private func performSwitchApp(_ action: AgentAction) async throws -> String {
        guard let bundleID = action.text, !bundleID.isEmpty else {
            throw ExecutorError.executionFailed("switchApp requires a bundle ID in the text field")
        }

        // Unit 10 — reject self-switch. If the LLM emits switchApp with the
        // agent's own bundleID (e.g. it ignored the cold-start prompt
        // directive and tried to "switch to itself"), bringing ourselves
        // frontmost is a no-op and the recovery loop will keep re-emitting.
        // Surface a clear error so the orchestrator's recovery prompt steers
        // the LLM to pick a real target from Running Apps.
        if bundleID == agentBundleID {
            throw ExecutorError.executionFailed(
                "Cannot switchApp to the agent itself (\(bundleID)). " +
                "Pick a different app from the Running Apps list — " +
                "switchApp is for activating the TARGET app."
            )
        }

        // Capture running state before any branch so both the launch path and the timeout
        // message use the same value.
        // safe: NSRunningApplication class methods are thread-safe per Cocoa
        // Thread Safety Summary (class itself, not instances). The .activate
        // call below IS @MainActor-isolated; we hop for that.
        let isAlreadyRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).isEmpty

        if isAlreadyRunning {
            // Fresh lookup inside the branch — handles the rare TOCTOU where the app quit
            // between the check above and the activate call.
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else {
                throw ExecutorError.executionFailed("App disappeared: \(bundleID)")
            }
            // activate(from:options:) mutates focus state via the WindowServer
            // and is @MainActor-isolated in Swift 6 AppKit annotations. The
            // return Bool is intentionally discarded — frontmost-app polling
            // below is the source of truth for "did activation succeed."
            _ = await MainActor.run {
                app.activate(from: NSRunningApplication.current, options: [])
            }
        } else {
            // Not running — look it up on disk and launch. urlForApplication
            // and openApplication are both @MainActor-isolated; combine into
            // one hop that returns the launched-bool.
            let launchOutcome: Bool? = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let appURL = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: bundleID) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    NSWorkspace.shared.openApplication(
                        at: appURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, error in
                        continuation.resume(returning: error == nil)
                    }
                }
            }
            guard let launched = launchOutcome else {
                throw ExecutorError.executionFailed(
                    "No application found with bundle ID: \(bundleID). " +
                    "Use a bundle ID from the Running Apps list.")
            }
            guard launched else {
                throw ExecutorError.executionFailed("Failed to launch \(bundleID)")
            }
        }

        // Poll until frontmost. Cold launches get the full 10 s. Already-running
        // apps used to get 2 s — too aggressive for browsers with many tabs,
        // chat apps with active background work, or any app whose window-server
        // path is slow. Live smoke (2026-05-23) caught Chrome timing out
        // repeatedly at the 2s mark even though it was running and would have
        // come forward ~500-1500ms later. 5s is long enough to absorb that
        // tail without unduly waiting on a truly stuck app.
        let timeout: Duration = isAlreadyRunning ? .seconds(5) : .seconds(10)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let frontID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            if frontID == bundleID {
                return isAlreadyRunning ? "switched to \(bundleID)" : "launched \(bundleID)"
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ExecutorError.executionFailed(
            "Timeout waiting for \(bundleID) to become frontmost")
    }

    // Helper used by performMenuSelect — reads a Bool AX attribute.
    private func attributeBool(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// Outcome of target resolution. Separates AX-element targets (use AXUIElement + frame)
    /// from vision targets (use pre-computed screen point; no AXUIElement available).
    /// `.coordinate` is the Computer Use fallback when no AX element matches — Claude
    /// returned an absolute pixel point with no nearest-element confidence.
    private enum ResolvedTarget {
        case ax(element: AXUIElement, frame: CodableRect)
        case vision(point: CGPoint, frame: CodableRect)
        case coordinate(point: CGPoint)
    }

    /// Decide whether an AX `kAXPressAction` failure code is safe to fall
    /// through to a CGEvent click at the element frame, or whether the
    /// failure indicates a stale handle / unknown state where the CGEvent
    /// would land on a reflowed UI element.
    ///
    /// **Documented `AXUIElementPerformAction` failure codes** (per the AX
    /// headers): `.illegalArgument`, `.invalidUIElement`, `.cannotComplete`,
    /// `.actionUnsupported`, `.notImplemented`. Of these:
    ///
    /// - `.actionUnsupported` (-25208): element doesn't expose press; coords
    ///   valid. Safe to fall through unconditionally.
    /// - `.noValue` (-25212): not documented for `PerformAction` but
    ///   semantically aligned with `.actionUnsupported`; observed
    ///   pre-2026-05-23 from some IOKit-backed AX elements. Safe.
    /// - `.illegalArgument`, `.invalidUIElement`, `.cannotComplete`,
    ///   `.notImplemented`: stale handle or unknown state; refuse.
    ///
    /// **Undocumented but observed:** `.attributeUnsupported` (-25205).
    /// Apple's headers document this code only for `CopyAttributeValue` /
    /// `SetAttributeValue`, not `PerformAction`. Empirically equivalent to
    /// `.actionUnsupported` (element exists, press not supported) — observed
    /// in the 2026-05-23 audit on Settings-Sidebar AXOutlineRow elements,
    /// and again in live production use 2026-05-25 on real multi-step runs.
    /// Fall through unconditionally, same as `.actionUnsupported`.
    ///
    /// **Earlier design (PR-3) gated `-25205` fallthrough on
    /// `snapshotAge < 200 ms`** as defense against a hypothetical future
    /// OS semantic shift. That design was wrong: the snapshot is captured
    /// at observe(), then the orchestrator's think() makes a 2-5s live LLM
    /// call before the executor dispatches. By the time `performClick`
    /// reads `snapshot.timestamp`, the snapshot is ALWAYS several seconds
    /// old. The gate therefore never fired the fallthrough — every
    /// `-25205` re-throws → "Accessibility press failed with code -25205"
    /// → orchestrator recovery exhausts → run fails. Found 2026-05-25 by
    /// live use. The original PR-3 reviewer flagged the asymmetric gate;
    /// they were right. Snapshot age is the wrong invariant here — the
    /// right invariant is "we observed, then thought, then act, and no
    /// action has fired since observe" — which the orchestrator already
    /// guarantees by setting `needsFreshPerception=true` after every
    /// non-wait action. The snapshot represents a coherent UI moment for
    /// the duration of one loop iteration; the AX frame is good to click.
    static func axPressFallthroughSafe(code: AXError) -> Bool {
        switch code {
        case .actionUnsupported, .noValue, .attributeUnsupported:
            return true
        default:
            return false
        }
    }

    private func resolveTarget(_ action: AgentAction, snapshot: ObservedSnapshot, scale: CGFloat) throws -> ResolvedTarget {
        guard let index = action.targetIndex, index >= 0 else {
            // No AX index — fall back to the absolute coordinate set by ComputerUseClient
            // for vision-only apps. SafetyPolicy floors coordinate-only clicks at .preview
            // so the user sees the action card before this path executes.
            if let coord = action.coordinate?.cgPoint {
                return .coordinate(point: coord)
            }
            // Malformed — LLM emitted an action with neither index nor coord.
            // Distinct from `.targetStale` (which has a known-but-OOB index)
            // so the Orchestrator's recovery prompt can give the right hint.
            throw ExecutorError.missingTarget
        }
        let offset = snapshot.snapshot.visionIndexOffset
        if index < offset {
            // AX path: look up the element in the AX hierarchy snapshot.
            guard let element = snapshot.lookup.element(at: index) else {
                // Index past the snapshot's AX-element count, or lookup returned
                // nil for the index. Either way the index is stale — emit the
                // rich error so Orchestrator can give the LLM a specific recovery
                // hint. lastKnownLabel: the snapshot still holds the ElementInfo
                // at this index when index is in-bounds; lookup failure is the
                // rarer case. Read defensively.
                let label: String? = (index < snapshot.snapshot.elements.count)
                    ? snapshot.snapshot.elements[index].label
                    : nil
                throw ExecutorError.targetStale(
                    actionType: action.type,
                    requestedIndex: index,
                    elementCount: snapshot.snapshot.elements.count,
                    lastKnownLabel: label
                )
            }
            let info = snapshot.snapshot.elements[index]
            guard info.isEnabled else {
                // Unit 18B — distinct error class so Orchestrator
                // recovery prompt names the index + label and tells the
                // LLM to pick a different element OR satisfy the
                // enabling condition. The element exists in the
                // snapshot (vs. .targetStale where it doesn't) — the
                // recovery strategy is different.
                throw ExecutorError.targetDisabled(
                    actionType: action.type,
                    requestedIndex: index,
                    label: info.label
                )
            }
            return .ax(element: element, frame: info.frame)
        } else {
            // Vision path: convert the bounding box to screen coordinates.
            // scale was fetched from NSScreen.main on @MainActor by perform() before this call.
            let visionIdx = index - offset
            let observations = snapshot.snapshot.visionObservations
            guard visionIdx < observations.count else {
                // Vision index past the OCR observation count — stale by the
                // same mechanism as the AX path. lastKnownLabel stays nil
                // because vision observations carry OCR text, not labels;
                // surfacing the text as a "label" would be misleading.
                // elementCount here is the vision-observation count (what the
                // LLM actually addresses past visionIndexOffset).
                throw ExecutorError.targetStale(
                    actionType: action.type,
                    requestedIndex: index,
                    elementCount: observations.count,
                    lastKnownLabel: nil
                )
            }
            let box = observations[visionIdx].boundingBox
            // G1 — the descale + centre math is PURE; extracted to a static
            // testable seam so a wrong conversion is caught by a unit matrix
            // rather than only surfacing as a misplaced live click.
            let (point, rect) = Self.visionBoxToScreen(
                box: box, captureOrigin: snapshot.snapshot.captureOrigin.cgPoint, scale: scale)
            return .vision(point: point, frame: CodableRect(rect))
        }
    }

    private func modifierFlags(for parts: [String]) -> CGEventFlags {
        Self.modifierFlags(for: parts)
    }

    /// G1 — vision OCR bounding box → screen geometry. Vision pixels are at
    /// the display's backing scale and relative to the capture origin
    /// (`.zero` full-screen, window-union origin app-scoped). Convert:
    /// divide by scale, offset by origin; the click point is the box centre.
    /// Pure + static so the descale a misplaced click would expose is pinned
    /// by a unit matrix (scales 1/2/3, non-zero origins, off-origin boxes).
    static func visionBoxToScreen(
        box: CodableRect, captureOrigin: CGPoint, scale: CGFloat
    ) -> (point: CGPoint, rect: CGRect) {
        let s = scale == 0 ? 1 : scale  // defensive: never divide by zero
        let x = captureOrigin.x + box.x / s
        let y = captureOrigin.y + box.y / s
        let w = box.width / s
        let h = box.height / s
        return (CGPoint(x: x + w / 2, y: y + h / 2), CGRect(x: x, y: y, width: w, height: h))
    }

    /// G1 — key-combo modifier parsing extracted to a pure static seam.
    static func modifierFlags(for parts: [String]) -> CGEventFlags {
        parts.reduce(into: CGEventFlags()) { flags, part in
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
    }

    /// Trim trailing affordance markers ("…", "...", "▸") and whitespace from a
    /// menu-item title so equality matching survives "New" vs "New…" cosmetic
    /// differences without falling back to substring matching (which was the
    /// pre-Cluster-C source of "Edit > delete" silently hitting "Delete All").
    ///
    /// `internal` so unit tests can exercise the matcher without driving the
    /// AXUIElement-bound `performMenuSelect` path.
    /// Unit 11 — testable seam for the menuSelect agent-frontmost guard.
    /// Returns the operator-facing error to throw when frontmost is the
    /// agent itself, or nil to proceed with the AX menu-bar walk. Pulled
    /// out of `performMenuSelect` so tests can verify the guard logic
    /// deterministically without depending on the swift-test process's
    /// actual `NSWorkspace.shared.frontmostApplication` (which is whichever
    /// app launched `swift test`, not the agent — so the guard never
    /// fires in the harness).
    internal static func menuSelectAgentGuardError(
        frontPID: pid_t,
        agentPID: pid_t = agentProcessID
    ) -> ExecutorError? {
        guard frontPID == agentPID else { return nil }
        return ExecutorError.executionFailed(
            "Cannot menuSelect when the agent itself is frontmost. " +
            "Dispatch switchApp(text=\"<bundleID>\") first to bring " +
            "the target app forward, then retry menuSelect."
        )
    }

    /// Unit 28 — generalised agent-frontmost backstop for the
    /// keystroke-injecting action types (typeText / keyCombo / holdKey).
    /// Sibling of `menuSelectAgentGuardError`: where that one protects the
    /// menuSelect AX-tree walk, this protects against synthesized CGEvents
    /// landing in the agent's own window when the agent is frontmost (the
    /// focus-steal failure mode — e.g. immediately after an in-window
    /// approval). Returns nil (allow) unless the frontmost PID is the
    /// agent's own. Test-safe for the same reason: `agentProcessID` is the
    /// agent binary's PID, not the `swift test` harness's frontmost app.
    internal static func agentFrontmostGuardError(
        actionType: ActionType,
        frontPID: pid_t,
        agentPID: pid_t = agentProcessID
    ) -> ExecutorError? {
        guard frontPID == agentPID else { return nil }
        return ExecutorError.executionFailed(
            "Cannot \(actionType.rawValue) when the agent itself is frontmost — " +
            "the keystrokes would land in the agent's own window. Dispatch " +
            "switchApp(text=\"<bundleID>\") first to bring the target app " +
            "forward, then retry."
        )
    }

    /// Unit 40a — the action types that act at the current frontmost app or
    /// absolute screen position, so an operator app-switch between snapshot
    /// and execution would land them in the operator's app. Keystrokes go to
    /// frontmost; clicks + drag post CGEvents at absolute coordinates. Held-
    /// mouse stream actions (mouseDown/Move/Up) are excluded — interrupting a
    /// live drag mid-stream is worse, and the held-mouse invariant governs
    /// them; scroll is benign; menuSelect/switchApp self-handle.
    internal static func isFrontmostSensitive(_ type: ActionType) -> Bool {
        switch type {
        case .typeText, .keyCombo, .holdKey,
             .click, .doubleClick, .tripleClick, .rightClick, .drag:
            return true
        default:
            return false
        }
    }

    /// Unit 40a — pure, testable drift decision. Returns a frontmostDrifted
    /// error when the live frontmost app differs from the app the snapshot
    /// was perceived against AND that app is still running. A nil live bundle
    /// (frontmost app reports no bundle ID) is treated AS drift: we cannot
    /// confirm it matches the snapshot, so the safe move is to yield.
    internal static func frontmostDriftError(
        actionType: ActionType,
        expectedApp: String,
        liveBundle: String?,
        expectedRunning: Bool
    ) -> ExecutorError? {
        guard expectedApp != "unknown", !expectedApp.isEmpty, expectedRunning else { return nil }
        // nil live bundle → unconfirmable → drift. Otherwise compare.
        if let liveBundle, liveBundle.caseInsensitiveCompare(expectedApp) == .orderedSame {
            return nil
        }
        return ExecutorError.frontmostDrifted(
            actionType: actionType, expectedApp: expectedApp, liveApp: liveBundle ?? "(unknown app)")
    }

    /// Unit 40 — is an app with this bundleID currently running? Used to gate
    /// the operator-drift guard so it fires only against a real app the
    /// operator switched away from (still running), never against a test
    /// fixture's synthetic bundleID (not running).
    @MainActor
    internal static func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    internal static func normalizeMenuTitle(_ s: String) -> String {
        var t = s
        while true {
            if t.hasSuffix("...") {
                t = String(t.dropLast(3))
            } else if let last = t.last, last == "…" || last == "▸" || last.isWhitespace {
                t = String(t.dropLast())
            } else {
                break
            }
        }
        return t
    }

    /// Returns the index of the menu child whose normalised title equals the
    /// normalised `component`, or nil if none. Exact equality only — no
    /// substring fallback. Ambiguous LLM paths force a replan on the next
    /// snapshot rather than silently picking a "close" item.
    internal static func matchMenuItem(component: String, titles: [String]) -> Int? {
        let target = normalizeMenuTitle(component)
        return titles.firstIndex { normalizeMenuTitle($0) == target }
    }
}

private let keyMap: [String: CGKeyCode] = [
    // Letters
    "a": 0, "s": 1, "d": 2, "f": 3, "g": 5, "h": 4, "j": 38, "k": 40, "l": 37,
    "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "n": 45, "m": 46,
    "q": 12, "w": 13, "e": 14, "r": 15, "t": 17, "y": 16, "u": 32, "i": 34, "o": 31, "p": 35,
    // Numbers
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    // Special
    "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53,
    "delete": 51, "backspace": 51, "forwarddelete": 117,
    // Arrows
    "left": 123, "right": 124, "down": 125, "up": 126,
    // Navigation
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    // Function keys
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

private func attributeElement(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
}

private func attributeString(_ attribute: CFString, on element: AXUIElement) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let value else { return nil }
    return value as? String
}

private func attributeArray(_ attribute: CFString, on element: AXUIElement) -> [AXUIElement]? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success, let array = value as? [AXUIElement] else { return nil }
    return array
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
