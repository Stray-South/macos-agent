import ApplicationServices
import Foundation
@testable import MacAgentCore
import Testing

// Executor vision dispatch (resolveTarget → CGPoint → CGEvent) is tested here.
// CGEvent synthesis can be verified without a real display: in a headless environment
// CGEvent(mouseEventSource:…) returns nil and the executor throws executionFailed.
// The key assertion is that missingTarget is NOT thrown — meaning the vision routing
// itself succeeded (correct index math, observation lookup, coordinate computation).
@Test
func executorVisionDispatchRoutesToVisionPathNotMissingTarget() async throws {
    let obs = VisionObservation(
        text: "Submit",
        boundingBox: CodableRect(CGRect(x: 200, y: 400, width: 100, height: 40))
    )
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [obs],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .click,
        targetIndex: 0,
        confidence: 1,
        requiresConfirmation: false,
        rationale: "Click Submit"
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
    } catch ExecutorError.missingTarget, ExecutorError.targetStale {
        // Unit 14: catch both — `.missingTarget` (malformed) and `.targetStale`
        // (index OOB) are both "resolveTarget refused to route" outcomes; either
        // means vision routing failed, which is the regression this test guards.
        Issue.record("resolveTarget took AX/resolve-fail path instead of vision path")
    } catch {
        // executionFailed (CGEvent nil in headless env) or any other error is acceptable —
        // it means vision routing succeeded.
    }
}

// Computer Use produces actions with targetIndex == nil and an absolute coordinate
// when the click point doesn't map to any AX element (vision-only / Electron apps).
// Before the fallback existed, resolveTarget threw missingTarget and the agent stalled.
@Test
func executorCoordinateFallbackRoutesPastMissingTarget() async throws {
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .click,
        targetIndex: nil,
        confidence: 1,
        requiresConfirmation: false,
        rationale: "CU coordinate click",
        coordinate: CodablePoint(CGPoint(x: 420, y: 360))
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
    } catch ExecutorError.missingTarget, ExecutorError.targetStale {
        Issue.record("Coordinate fallback failed: resolveTarget threw missingTarget/targetStale despite action.coordinate being set")
    } catch {
        // executionFailed in headless env is acceptable; coordinate routing succeeded.
    }
}

@Test
func executorDrag_requiresStartAndEndCoordinates() async throws {
    // .drag requires both startCoordinate AND coordinate. Missing either
    // throws executionFailed (NOT missingTarget — drag bypasses resolveTarget).
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let executor = Executor(waitDuration: .seconds(0))

    // No start: throws executionFailed
    let noStart = AgentAction(
        type: .drag, confidence: 1, requiresConfirmation: false,
        rationale: "drag without start",
        coordinate: CodablePoint(CGPoint(x: 300, y: 400))
    )
    do {
        _ = try await executor.perform(noStart, snapshot: observed)
        Issue.record("expected executionFailed for missing startCoordinate")
    } catch ExecutorError.executionFailed { /* expected */ }
    catch { Issue.record("expected executionFailed, got \(error)") }

    // No end: throws executionFailed
    let noEnd = AgentAction(
        type: .drag, confidence: 1, requiresConfirmation: false,
        rationale: "drag without end",
        startCoordinate: CodablePoint(CGPoint(x: 100, y: 200))
    )
    do {
        _ = try await executor.perform(noEnd, snapshot: observed)
        Issue.record("expected executionFailed for missing endCoordinate")
    } catch ExecutorError.executionFailed { /* expected */ }
    catch { Issue.record("expected executionFailed, got \(error)") }
}

@Test
func executorDrag_withBothCoordinates_doesNotThrowMissingTarget() async throws {
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .drag,
        confidence: 1,
        requiresConfirmation: false,
        rationale: "drag for text selection",
        coordinate: CodablePoint(CGPoint(x: 300, y: 400)),
        startCoordinate: CodablePoint(CGPoint(x: 100, y: 200))
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
    } catch ExecutorError.missingTarget, ExecutorError.targetStale {
        Issue.record("drag with both coordinates must not throw missingTarget/targetStale")
    } catch {
        // executionFailed in headless env is acceptable; the drag routing succeeded.
    }
}

@Test
func executorTripleClick_routesPastMissingTarget() async throws {
    // Pin .tripleClick routing through the existing multi-click executor path.
    // Mirrors the double-click pattern: CGEvent posts in a headless test
    // environment return nil and throw executionFailed — what we care about is
    // that resolveTarget does NOT raise missingTarget (i.e. .tripleClick is
    // wired into perform's switch).
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .tripleClick,
        targetIndex: nil,
        confidence: 1,
        requiresConfirmation: false,
        rationale: "triple-click for line-select",
        coordinate: CodablePoint(CGPoint(x: 200, y: 200))
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
    } catch ExecutorError.missingTarget, ExecutorError.targetStale {
        Issue.record("tripleClick should route through coordinate fallback, not throw missingTarget/targetStale")
    } catch {
        // executionFailed in headless env is acceptable; the multi-click routing succeeded.
    }
}

@Test
func executorHoldKey_withMissingTextThrowsInvalidKeyCombo() async throws {
    let snap = PerceptionSnapshot(
        timestamp: Date(), focusedAppBundleID: "com.test", elements: [],
        hash: "test", visionObservations: [], visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .holdKey, text: nil, confidence: 1,
        requiresConfirmation: false, rationale: "hold no key",
        durationMs: 100
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("expected invalidKeyCombo for missing text")
    } catch ExecutorError.invalidKeyCombo { /* expected */ }
    catch { Issue.record("expected invalidKeyCombo, got \(error)") }
}

@Test
func executorHoldKey_withValidTextDoesNotThrowMissingTarget() async throws {
    // holdKey doesn't need targetIndex (it operates on whatever has key focus).
    // Confirms routing doesn't accidentally go through resolveTarget.
    let snap = PerceptionSnapshot(
        timestamp: Date(), focusedAppBundleID: "com.test", elements: [],
        hash: "test", visionObservations: [], visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .holdKey, text: "a", confidence: 1,
        requiresConfirmation: false, rationale: "tap a",
        durationMs: 0  // 0ms duration = effectively immediate down+up
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
    } catch ExecutorError.missingTarget, ExecutorError.targetStale {
        Issue.record("holdKey must not require a target — got missingTarget/targetStale")
    } catch {
        // executionFailed in headless env is acceptable; routing succeeded.
    }
}

@Test
func executorStillThrowsMissingTargetWhenIndexAndCoordinateBothNil() async throws {
    let snap = PerceptionSnapshot(
        timestamp: Date(),
        focusedAppBundleID: "com.test",
        elements: [],
        hash: "test",
        visionObservations: [],
        visionIndexOffset: 0,
        captureOrigin: .zero
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .click,
        targetIndex: nil,
        confidence: 1,
        requiresConfirmation: false,
        rationale: "incoherent click — no index, no coord"
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("expected ExecutorError.missingTarget but perform() returned normally")
    } catch ExecutorError.missingTarget {
        // expected
    } catch {
        Issue.record("expected ExecutorError.missingTarget but got \(error)")
    }
}

// MARK: - Unit 14 — stale-targetIndex recovery (Path D Candidate 1)
//
// The 2026-05-23 receipts showed targetIndex=216 fail against 4 distinct
// snapshot hashes — fresh perception wasn't enough; the LLM kept re-picking
// the same dead index. `.targetStale` carries the specific context the
// Orchestrator's recovery prompt needs to give the LLM a labelled hint.

@Test
func executor_targetStale_axBoundsFail_carriesIndexLabelAndCount() async throws {
    // Snapshot with one element at index 0; ObservedSnapshot's default
    // lookup is empty so any requested AX index returns nil from lookup —
    // simulating the "snapshot still has the entry but the live handle is
    // gone" failure mode that resolveTarget surfaces as `.targetStale`.
    let element = UIElement(
        index: 0, role: "AXButton", label: "Submit", value: nil,
        frame: CodableRect(CGRect(x: 100, y: 100, width: 80, height: 30)),
        isEnabled: true, isVisible: true
    )
    let snap = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: [element]
    )
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .click, targetIndex: 0,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "click the (now-stale) submit button"
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("expected .targetStale for stale AX lookup")
    } catch let error as ExecutorError {
        guard case .targetStale(let actionType, let idx, let count, let label) = error else {
            Issue.record("expected .targetStale, got \(error)")
            return
        }
        #expect(actionType == .click)
        #expect(idx == 0)
        #expect(count == 1, "elementCount must reflect the snapshot's actual element count, not 0")
        #expect(label == "Submit", "lastKnownLabel must carry the element's label so the recovery prompt can hint at it")
    }
}

@Test
func executor_targetStale_visionBoundsFail_carriesCountAndNilLabel() async throws {
    // Vision path: index past visionObservations.count → `.targetStale`
    // with nil label (vision observations don't have labels, only OCR text;
    // we don't synthesize a label to avoid misleading the recovery prompt).
    let snap = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: []
    )
    // visionIndexOffset = min(0, 80) = 0, so any non-negative index falls
    // into the vision branch. visionObservations is empty → OOB → stale.
    let observed = ObservedSnapshot(snapshot: snap)
    let action = AgentAction(
        type: .click, targetIndex: 5,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "click vision-index 5 that doesn't exist"
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("expected .targetStale for vision OOB")
    } catch let error as ExecutorError {
        guard case .targetStale(let actionType, let idx, let count, let label) = error else {
            Issue.record("expected .targetStale, got \(error)")
            return
        }
        #expect(actionType == .click)
        #expect(idx == 5)
        #expect(count == 0, "elementCount on vision path = visionObservations.count")
        #expect(label == nil, "vision path does NOT carry a label hint — OCR text would be misleading as 'label'")
    }
}

@Test
func executor_errorDescriptions_distinguishMissingFromStale() {
    // The Orchestrator's recovery prompt branches on the error type, but
    // also reads `error.localizedDescription` for receipts and for the
    // generic non-stale fallback. The two descriptions must differ so a
    // post-hoc audit can tell them apart from receipt text alone.
    let missing = ExecutorError.missingTarget
    let stale = ExecutorError.targetStale(
        actionType: .click, requestedIndex: 216, elementCount: 42,
        lastKnownLabel: "Search field"
    )
    #expect(missing.errorDescription != stale.errorDescription)
    #expect(stale.errorDescription?.contains("216") == true)
    #expect(stale.errorDescription?.contains("42") == true)
    #expect(stale.errorDescription?.contains("Search field") == true)
}

// MARK: - Unit 18B — disabled-element recovery
//
// Adjacent to Unit 14's `.targetStale`: the element exists in the
// current snapshot (or menu hierarchy) but is currently disabled.
// Distinct error class so Orchestrator's recovery prompt tells the
// LLM to satisfy the enabling condition, not just re-observe.

@Test
func executor_targetDisabled_axPath_carriesIndexAndLabel() async throws {
    // Disabled element at index 0 — resolveTarget AX branch throws
    // .targetDisabled (not the prior .executionFailed).
    //
    // Implementation note: `resolveTarget` checks `lookup.element(at:)`
    // BEFORE checking `info.isEnabled`. Default `ObservedSnapshot` init
    // gives an empty lookup → throws `.targetStale` first, never
    // reaching the disabled check. To exercise the disabled path we
    // need a non-nil AXUIElement in the lookup. The test process's
    // own AX application element is the easiest source — it's a real
    // AXUIElement; resolveTarget treats it as opaque (it only checks
    // for nil from the lookup).
    let testProcessAXElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let disabledElement = UIElement(
        index: 0, role: "AXButton", label: "Submit", value: nil,
        frame: CodableRect(CGRect(x: 10, y: 10, width: 80, height: 28)),
        isEnabled: false, isVisible: true
    )
    let snap = try PerceptionSnapshot.make(
        timestamp: .now, focusedAppBundleID: "com.test", elements: [disabledElement]
    )
    let lookup = AXElementLookup(storage: [0: testProcessAXElement])
    let observed = ObservedSnapshot(snapshot: snap, lookup: lookup)
    let action = AgentAction(
        type: .click, targetIndex: 0,
        confidence: 0.9, requiresConfirmation: false,
        rationale: "click submit before form filled"
    )
    let executor = Executor(waitDuration: .seconds(0))
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("expected .targetDisabled for disabled element")
    } catch let error as ExecutorError {
        guard case .targetDisabled(let actionType, let idx, let label) = error else {
            Issue.record("expected .targetDisabled, got \(error)")
            return
        }
        #expect(actionType == .click)
        #expect(idx == 0)
        #expect(label == "Submit",
                "label must be carried through so the recovery prompt can name the disabled element")
    }
}

@Test
func executor_errorDescriptions_distinguishStaleFromDisabled() {
    // Recovery prompt branches on error TYPE, but receipts encode
    // `error.localizedDescription` (string). Stale and disabled must
    // produce different strings so post-hoc audit can disambiguate.
    let stale = ExecutorError.targetStale(
        actionType: .click, requestedIndex: 5, elementCount: 10,
        lastKnownLabel: "Submit"
    )
    let disabled = ExecutorError.targetDisabled(
        actionType: .click, requestedIndex: 5, label: "Submit"
    )
    #expect(stale.errorDescription != disabled.errorDescription,
            "Stale and disabled have different recovery strategies — error strings must differ")
    #expect(disabled.errorDescription?.contains("disabled") == true,
            "Disabled error string must say 'disabled' so a log scrape can tell them apart")
    #expect(stale.errorDescription?.contains("no longer") == true,
            "Stale error string says 'no longer in the snapshot' — disjoint vocabulary")
}

@Test
func executor_targetDisabled_menuPath_carriesLabelNoIndex() {
    // Menu-path disabled has no index — only a label. Construct the
    // case directly to assert the schema accommodates it cleanly.
    let err = ExecutorError.targetDisabled(
        actionType: .menuSelect,
        requestedIndex: nil,
        label: "Save"
    )
    guard case .targetDisabled(let t, let idx, let label) = err else {
        Issue.record("could not destructure")
        return
    }
    #expect(t == .menuSelect)
    #expect(idx == nil, "Menu-disabled path has no index — schema must accommodate")
    #expect(label == "Save")
    let desc = err.errorDescription ?? ""
    #expect(desc.contains("Menu item"),
            "Menu-disabled description must use 'Menu item' phrasing so the recovery prompt branches correctly")
    #expect(!desc.contains("at index"),
            "Menu-disabled description must NOT mention indices — they don't apply to menu paths")
}

@Test
func receiptWriterCreatesParseableJSONLFile() async throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let writer = ReceiptWriter(baseURL: tmp)
    let entry = ActionLogEntry(
        action: AgentAction(type: .complete, confidence: 1, requiresConfirmation: false, rationale: "Done"),
        tier: "auto",
        approved: true,
        executionResult: "success",
        durationMs: 5,
        snapshotHash: "abc123"
    )

    try await writer.write(entry)

    let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let contents = try String(contentsOf: files[0])
    let line = try #require(contents.split(separator: "\n").first)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ActionLogEntry.self, from: Data(line.utf8))
    #expect(decoded.executionResult == "success")
}

// MARK: - Cluster C: menuSelect exact-match-only with affordance normalisation

@Test
func executorMenuMatch_trailingEllipsisNormalisesToExactMatch() {
    // "File > New" must match "New…" — the affordance ellipsis is a UI artefact
    // not part of the logical menu name. Trimmed before equality compare.
    let titles = ["new…", "save…", "save as"]
    #expect(Executor.matchMenuItem(component: "new", titles: titles) == 0,
            "'new' should match 'new…' after ellipsis trim.")
    #expect(Executor.matchMenuItem(component: "save", titles: titles) == 1,
            "'save' should match 'save…' (not 'save as').")
}

@Test
func executorMenuMatch_threeDotEllipsisAndSubmenuMarker_normalise() {
    let titles = ["export...", "settings ▸"]
    #expect(Executor.matchMenuItem(component: "export", titles: titles) == 0,
            "'export' should match 'export...' (three-dot affordance).")
    #expect(Executor.matchMenuItem(component: "settings", titles: titles) == 1,
            "'settings' should match 'settings ▸' (submenu marker).")
}

@Test
func executorMenuMatch_ambiguousLLMPathNoLongerSubstringMatches() {
    // Pre-Cluster-C: "delete" against ["Delete All", "Delete Selected"] silently
    // hit "Delete All" via the substring fallback even though the LLM did not
    // request the specific menu item. Now: no exact match → nil → caller throws
    // and the LLM must replan with a precise name.
    let titles = ["delete all", "delete selected"]
    #expect(Executor.matchMenuItem(component: "delete", titles: titles) == nil,
            "Substring fallback removed — ambiguous 'delete' against multiple Delete* items must not silently match.")
}

@Test
func executorMenuMatch_exactStillMatches() {
    let titles = ["new", "save", "close window"]
    #expect(Executor.matchMenuItem(component: "new", titles: titles) == 0)
    #expect(Executor.matchMenuItem(component: "close window", titles: titles) == 2)
}

@Test
func executorMenuMatch_emptyStringDoesNotInfiniteLoop() {
    // Defensive: normaliseMenuTitle's trim loop must terminate on empty input.
    // No menu in production should be empty, but a degraded AX query could
    // return an empty title — must not hang the executor.
    #expect(Executor.normalizeMenuTitle("") == "")
    #expect(Executor.matchMenuItem(component: "", titles: ["", "save"]) == 0,
            "empty component should exactly match empty title at index 0.")
}

@Test
func executorMenuMatch_repeatedTrailingAffordances_allStripped() {
    // Double-ellipsis or mixed-affordance suffixes — the trim loop must keep
    // peeling until a non-affordance character is reached.
    #expect(Executor.normalizeMenuTitle("new……") == "new")
    #expect(Executor.normalizeMenuTitle("export...…") == "export")
    #expect(Executor.normalizeMenuTitle("settings ▸ …") == "settings")
}

// MARK: - Cluster D: typeText default path + holdKey cancellation

@Test
func executorTypeText_defaultsToNonPasteboardPath() {
    // Default Executor must NOT have the opt-in fast paste enabled. Tests the
    // property wiring — production AppModel never explicitly passes true unless
    // the operator has flipped the UserDefaults flag.
    let executor = Executor()
    #expect(executor.useFastPasteForLongText == false,
            "Default Executor must keep useFastPasteForLongText=false. Long typeText payloads route through CGEventKeyboardSetUnicodeString, never NSPasteboard.")
}

@Test
func executorTypeText_fastPasteFlagPropagatesWhenOpted() {
    let executor = Executor(useFastPasteForLongText: true)
    #expect(executor.useFastPasteForLongText == true,
            "Explicit opt-in must be honored — production AppModel reads UserDefaults.agentSuite.useFastPasteForLongText and passes it through.")
}

@Test
func executorHoldKey_propagatesCancellationDuringSleep() async throws {
    // The Cluster D fix changed `try? await Task.sleep` to `try await Task.sleep`
    // in performHoldKey. Cancelling the task during the held-key sleep must now
    // throw CancellationError so Orchestrator's loop sees the cancel and the
    // receipt reflects the abort. Pre-fix the function returned normally after
    // a cancel and the receipt looked like a clean held-key.
    //
    // performHoldKey is private; we exercise it via Executor.perform which
    // dispatches to it on `.holdKey`. 5-second hold; cancel after 50ms.
    let executor = Executor()
    let action = AgentAction(
        type: .holdKey, text: "a", confidence: 0.9,
        requiresConfirmation: false, rationale: "test long hold",
        durationMs: 5000
    )
    // Build a minimal observed snapshot — holdKey doesn't consult AX targets.
    let snapshot = ObservedSnapshot(
        snapshot: try PerceptionSnapshot.make(
            timestamp: .now, focusedAppBundleID: "com.test", elements: []
        )
    )
    let task = Task<Bool, Error> {
        do {
            _ = try await executor.perform(action, snapshot: snapshot)
            return false  // ran to completion — pre-fix behaviour
        } catch is CancellationError {
            return true   // propagated — post-fix behaviour
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    let propagated = try await task.value
    #expect(propagated,
            "performHoldKey must throw CancellationError when its task is cancelled mid-sleep — pre-fix `try?` swallowed it.")
}

@Test
func executorMenuMatch_affordanceCharsMidStringNotStripped() {
    // Trim is suffix-only. An affordance character in the middle (extremely
    // unlikely but defensive) must NOT be stripped, otherwise "ne…w" would
    // collapse to "new" and silently match a different menu item.
    #expect(Executor.normalizeMenuTitle("ne…w") == "ne…w")
    #expect(Executor.normalizeMenuTitle("file...x") == "file...x")
}

// Unit 11 — menuSelect agent-guard. Sibling of Unit 10's self-switch
// guard. Real `performMenuSelect` can't be exercised from a test (the
// swift-test process's `NSWorkspace.shared.frontmostApplication` is
// whatever launched the test, not the agent). Test the extracted
// `menuSelectAgentGuardError` helper directly — same pattern as
// `AXPerception.isAgentProcess` and `ComputerUseClient.agentAppsToExclude`.

@Test
func menuSelectAgentGuardError_returnsNilForNonAgentPID() {
    let agentPID = pid_t(12345)
    let frontPID = pid_t(99999)
    #expect(Executor.menuSelectAgentGuardError(frontPID: frontPID, agentPID: agentPID) == nil,
            "guard must allow menuSelect to proceed when frontmost ≠ agent")
}

@Test
func menuSelectAgentGuardError_throwsActionableErrorWhenAgentFrontmost() {
    let agentPID = pid_t(12345)
    guard let error = Executor.menuSelectAgentGuardError(frontPID: agentPID, agentPID: agentPID) else {
        Issue.record("guard must fire when frontPID == agentPID")
        return
    }
    guard case .executionFailed(let message) = error else {
        Issue.record("Expected .executionFailed, got \(error)")
        return
    }
    #expect(message.contains("agent itself is frontmost"),
            "error message must name the bug class so the LLM's recovery prompt has context")
    #expect(message.contains("switchApp"),
            "error must direct the LLM to switchApp first as the recovery action")
}

// Default `agentPID` argument resolves to `agentProcessID` — confirms
// the production call site (which omits `agentPID`) gets the right value.
@Test
func menuSelectAgentGuardError_defaultPIDIsCurrentProcess() {
    let myPID = ProcessInfo.processInfo.processIdentifier
    // Helper with no agentPID arg must compare against agentProcessID,
    // which equals the test process's PID. So guard fires when
    // frontPID == myPID, doesn't fire otherwise.
    #expect(Executor.menuSelectAgentGuardError(frontPID: myPID) != nil,
            "default agentPID must equal ProcessInfo.processInfo.processIdentifier")
    #expect(Executor.menuSelectAgentGuardError(frontPID: myPID + 1) == nil,
            "non-matching PID must allow menuSelect to proceed")
}

// Unit 28 — agentFrontmostGuardError: the keystroke-injection backstop
// (typeText/keyCombo/holdKey). Same direct-helper test pattern as the
// menuSelect guard above; perform() consults it before any CGEvent-posting
// action so an approved keystroke can't land in the agent's own window.

@Test
func agentFrontmostGuardError_allowsWhenFrontmostIsNotAgent() {
    let agentPID = pid_t(12345)
    let frontPID = pid_t(99999)
    for actionType in [ActionType.typeText, .keyCombo, .holdKey] {
        #expect(Executor.agentFrontmostGuardError(actionType: actionType, frontPID: frontPID, agentPID: agentPID) == nil,
                "guard must allow \(actionType.rawValue) when frontmost ≠ agent")
    }
}

@Test
func agentFrontmostGuardError_firesForEachKeystrokeActionWhenAgentFrontmost() {
    let agentPID = pid_t(12345)
    for actionType in [ActionType.typeText, .keyCombo, .holdKey] {
        guard let error = Executor.agentFrontmostGuardError(actionType: actionType, frontPID: agentPID, agentPID: agentPID) else {
            Issue.record("guard must fire for \(actionType.rawValue) when frontPID == agentPID")
            continue
        }
        guard case .executionFailed(let message) = error else {
            Issue.record("Expected .executionFailed for \(actionType.rawValue), got \(error)")
            continue
        }
        #expect(message.contains(actionType.rawValue),
                "error must name the blocked action type so the recovery prompt has context")
        #expect(message.contains("agent itself is frontmost"),
                "error must name the focus-steal failure class")
        #expect(message.contains("switchApp"),
                "error must direct the LLM to switchApp first")
    }
}

@Test
func agentFrontmostGuardError_defaultPIDIsCurrentProcess() {
    let myPID = ProcessInfo.processInfo.processIdentifier
    #expect(Executor.agentFrontmostGuardError(actionType: .typeText, frontPID: myPID) != nil,
            "default agentPID must equal the current process PID")
    #expect(Executor.agentFrontmostGuardError(actionType: .typeText, frontPID: myPID + 1) == nil,
            "non-matching PID must allow the action to proceed")
}

// Unit 10 — self-switch guard. If the LLM (in any autonomy mode) ignores
// the cold-start prompt directive and emits switchApp(text=agentBundleID),
// performSwitchApp must reject. Without this guard, switchApp would silently
// re-activate the agent itself (no-op visually) and the LLM might enter a
// retry loop emitting the same useless action. The error message routes
// through the orchestrator's recovery prompt to steer the LLM to a real
// target from Running Apps.
@Test
func performSwitchApp_rejectsAgentSelfBundleID() async throws {
    let executor = Executor()
    let action = AgentAction(
        type: .switchApp, text: agentBundleID, confidence: 0.9,
        requiresConfirmation: false, rationale: "switch to self (testing guard)"
    )
    // Use a minimal observed snapshot; performSwitchApp doesn't need element data.
    let observed = ObservedSnapshot(
        snapshot: try PerceptionSnapshot.make(
            timestamp: .now, focusedAppBundleID: "com.example.test", elements: []
        )
    )
    do {
        _ = try await executor.perform(action, snapshot: observed)
        Issue.record("Expected ExecutorError to throw for self-switch")
    } catch let error as ExecutorError {
        guard case .executionFailed(let message) = error else {
            Issue.record("Expected .executionFailed, got \(error)")
            return
        }
        #expect(message.contains("agent itself"),
                "error message must explain the bug class so the LLM's recovery prompt has context")
        #expect(message.contains(agentBundleID),
                "error must include the offending bundle ID for diagnosis")
        #expect(message.contains("Running Apps"),
                "error must point the LLM at the Running Apps list as the recovery surface")
    } catch {
        Issue.record("Expected ExecutorError, got \(type(of: error)): \(error)")
    }
}

// MARK: - Unit 36: writeFile sandbox

@Suite struct WriteFileSandboxTests {
    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ path: String?, _ text: String, root: URL?) async throws -> String {
        let exec = Executor(workspaceRoot: root)
        let action = AgentAction(type: .writeFile, text: text, confidence: 0.9,
                                 requiresConfirmation: true, rationale: "save", filePath: path)
        let snapshot = try PerceptionSnapshot.make(timestamp: .now, focusedAppBundleID: "x", elements: [])
        return try await exec.perform(action, snapshot: ObservedSnapshot(snapshot: snapshot))
    }

    @Test func writesInsideWorkspace() async throws {
        let root = try workspace()
        let result = try await write("notes/draft.txt", "hello", root: root)
        #expect(result.contains("wrote 5 bytes"))
        let written = try String(contentsOf: root.appendingPathComponent("notes/draft.txt"), encoding: .utf8)
        #expect(written == "hello")
    }

    @Test func disabledWhenNoWorkspace() async throws {
        await #expect(throws: ExecutorError.self) {
            _ = try await write("a.txt", "x", root: nil)
        }
    }

    @Test func rejectsTraversal() async throws {
        let root = try workspace()
        for bad in ["../escape.txt", "notes/../../escape.txt", "a/../../b.txt"] {
            await #expect(throws: ExecutorError.self, "traversal '\(bad)' must be rejected") {
                _ = try await write(bad, "x", root: root)
            }
        }
        // Nothing escaped: the parent of the workspace has no escape.txt / b.txt.
        let parent = root.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escape.txt").path))
    }

    @Test func rejectsAbsoluteAndTilde() async throws {
        let root = try workspace()
        for bad in ["/tmp/evil.txt", "/etc/hosts", "~/evil.txt"] {
            await #expect(throws: ExecutorError.self, "absolute/tilde '\(bad)' must be rejected") {
                _ = try await write(bad, "x", root: root)
            }
        }
    }

    @Test func rejectsMissingPath() async throws {
        let root = try workspace()
        await #expect(throws: ExecutorError.self) { _ = try await write(nil, "x", root: root) }
        await #expect(throws: ExecutorError.self) { _ = try await write("", "x", root: root) }
    }

    @Test func rejectsSymlinkEscape() async throws {
        let root = try workspace()
        // A symlinked subdir pointing outside the workspace must not let a
        // write through it land outside.
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: outside)
        await #expect(throws: ExecutorError.self, "write through a symlink escaping the workspace must be rejected") {
            _ = try await write("link/pwned.txt", "x", root: root)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.txt").path))
    }

    // 36a — a LEAF symlink (the filename itself points outside) must be
    // rejected explicitly, not just incidentally by .atomic's rename.
    @Test func rejectsLeafSymlinkEscape() async throws {
        let root = try workspace()
        let victim = root.deletingLastPathComponent().appendingPathComponent("victim.txt")
        try "original".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("evil.txt"),
                                                   withDestinationURL: victim)
        await #expect(throws: ExecutorError.self, "a leaf symlink must be refused, not followed") {
            _ = try await write("evil.txt", "pwned", root: root)
        }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "original",
                "the out-of-sandbox victim file must be untouched")
    }

    // 36a — a live provider returning nil (operator disabled the workspace)
    // disables writes immediately, even on a reused Executor.
    @Test func liveProviderDisablesWrites() async throws {
        let root = try workspace()
        // An atomic flag the provider reads live; flipping it disables writes
        // on the SAME Executor instance without a rebuild.
        final class Flag: @unchecked Sendable { var on = true }
        let flag = Flag()
        let exec = Executor(workspaceRootProvider: { flag.on ? root : nil })
        let snapshot = try PerceptionSnapshot.make(timestamp: .now, focusedAppBundleID: "x", elements: [])
        func writeOnce() async throws -> String {
            let a = AgentAction(type: .writeFile, text: "x", confidence: 0.9,
                                requiresConfirmation: true, rationale: "save", filePath: "a.txt")
            return try await exec.perform(a, snapshot: ObservedSnapshot(snapshot: snapshot))
        }
        _ = try await writeOnce()
        flag.on = false
        await #expect(throws: ExecutorError.self, "disabling the workspace must stop writes on the SAME Executor") {
            _ = try await writeOnce()
        }
    }
}

// MARK: - Unit 40: operator-drift guard

@Suite struct FrontmostDriftTests {
    @Test func errorDescribesTheYield() {
        let err = ExecutorError.frontmostDrifted(actionType: .typeText,
                                                 expectedApp: "com.apple.Notes",
                                                 liveApp: "com.apple.Safari")
        let msg = err.errorDescription ?? ""
        #expect(msg.contains("com.apple.Notes") && msg.contains("com.apple.Safari"))
        #expect(msg.lowercased().contains("yield"), "the message frames it as yielding, not failing")
    }

    // 40a — the pure drift decision (the actual comparison the guard runs).
    @Test func driftDecision() {
        // Real drift to another running app → yield.
        #expect(Executor.frontmostDriftError(actionType: .typeText,
            expectedApp: "com.apple.Notes", liveBundle: "com.apple.Safari", expectedRunning: true) != nil)
        // Same app (case-insensitive) → no drift.
        #expect(Executor.frontmostDriftError(actionType: .typeText,
            expectedApp: "com.apple.Notes", liveBundle: "com.apple.notes", expectedRunning: true) == nil)
        // Expected app not running (operator quit it, or a test fixture) → inert.
        #expect(Executor.frontmostDriftError(actionType: .typeText,
            expectedApp: "com.example.app", liveBundle: "com.apple.Safari", expectedRunning: false) == nil)
        // Unknown / empty expected → inert (cold start).
        #expect(Executor.frontmostDriftError(actionType: .click,
            expectedApp: "unknown", liveBundle: "com.apple.Safari", expectedRunning: true) == nil)
        // nil live bundle with a running expected → unconfirmable → yield (safe).
        #expect(Executor.frontmostDriftError(actionType: .click,
            expectedApp: "com.apple.Notes", liveBundle: nil, expectedRunning: true) != nil)
    }

    // 40a — the guard now covers positional clicks + drag, not just keystrokes.
    @Test func frontmostSensitiveScope() {
        for t in [ActionType.typeText, .keyCombo, .holdKey, .click, .doubleClick,
                  .tripleClick, .rightClick, .drag] {
            #expect(Executor.isFrontmostSensitive(t), "\(t) acts positionally and must be drift-guarded")
        }
        for t in [ActionType.scroll, .menuSelect, .switchApp, .wait, .complete,
                  .say, .readClipboard, .writeFile, .mouseUp] {
            #expect(!Executor.isFrontmostSensitive(t), "\(t) must not be drift-guarded")
        }
    }

    @Test @MainActor func isAppRunningGatesOnRealApps() {
        // A synthetic fixture bundle is never running, so the drift guard is
        // inert for it (this is the test-safety property the whole suite
        // relies on — typeText fixtures use "com.example.app").
        #expect(!Executor.isAppRunning(bundleID: "com.example.nonexistent.fixture"))
        // The test host process itself IS running, proving the check works.
        let selfBundle = Bundle.main.bundleIdentifier
        if let selfBundle { #expect(Executor.isAppRunning(bundleID: selfBundle)) }
    }
}
