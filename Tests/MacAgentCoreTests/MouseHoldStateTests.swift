/// MouseHoldStateTests.swift
///
/// Unit 13b — process-wide stateful-mouse tracker AND Executor live
/// dispatch for `.mouseDown`/`.mouseUp`/`.mouseMove`/`.drag`/`.click`
/// chokepoint guarantees.
///
/// One `@Suite(.serialized)` covers BOTH the tracker tests and the
/// Executor stateful-mouse tests because Swift Testing's `.serialized`
/// trait only serialises tests WITHIN a single suite — sibling suites
/// can still run in parallel against each other. The singleton makes
/// any parallel exec across these two test sets cause cross-test bleed.
/// Combining them under one suite gives global serial ordering for
/// every test that touches `MouseHoldState.shared`.
///
/// Each test still calls `resetForTesting()` at entry as defense-in-
/// depth in case `.serialized` semantics regress in a future Swift
/// Testing release.
import CoreGraphics
import Foundation
@testable import MacAgentCore
import Testing

@Suite(.serialized)
struct StatefulMouseTests {
    // MARK: - Tracker invariants

    @Test
    func markHeldThenRelease_clearsState() async {
        let s = MouseHoldState.shared
        await s.resetForTesting()
        #expect(await s.isHeld() == false, "precondition: state clean after reset")

        await s.markHeld(button: .left, at: CGPoint(x: 100, y: 200))
        #expect(await s.isHeld() == true)
        #expect(await s.currentHeldButton() == .left)
        #expect(await s.currentCoordinate() == CGPoint(x: 100, y: 200))

        let released = await s.release()
        #expect(released == true, "release must return true when a button was actually held")
        #expect(await s.isHeld() == false)
        #expect(await s.currentHeldButton() == nil)
    }

    @Test
    func releaseIdempotent_returnsFalseSecondTime() async {
        let s = MouseHoldState.shared
        await s.resetForTesting()

        await s.markHeld(button: .left, at: CGPoint(x: 50, y: 50))
        let first = await s.release()
        let second = await s.release()
        #expect(first == true, "first release returns true")
        #expect(second == false, "second release is a no-op (false) — multiple cleanup paths must converge safely")
    }

    @Test
    func releaseWhenNothingHeld_isNoOp() async {
        let s = MouseHoldState.shared
        await s.resetForTesting()
        let released = await s.release()
        #expect(released == false, "release on a clean tracker must not crash and must return false")
    }

    @Test
    func updateCoordinate_preservesHeldButton() async {
        let s = MouseHoldState.shared
        await s.resetForTesting()

        await s.markHeld(button: .left, at: CGPoint(x: 10, y: 20))
        await s.updateCoordinate(CGPoint(x: 300, y: 400))
        #expect(await s.isHeld() == true, "updateCoordinate must not clear held state")
        #expect(await s.currentHeldButton() == .left)
        #expect(await s.currentCoordinate() == CGPoint(x: 300, y: 400),
                "coordinate must reflect the most recent update so the watchdog's eventual mouseUp lands at the right point")

        _ = await s.release()
    }

    @Test
    func watchdogAutoReleasesAfterTimeout() async throws {
        let s = MouseHoldState.shared
        await s.resetForTesting()

        await s.markHeld(
            button: .left,
            at: CGPoint(x: 0, y: 0),
            watchdogDuration: .milliseconds(100)
        )
        #expect(await s.isHeld() == true, "precondition: held immediately after markHeld")

        try await Task.sleep(for: .milliseconds(400))
        #expect(await s.isHeld() == false,
                "watchdog must auto-release after timeout — held buttons that survive are an OS-level user-lockout risk")
    }

    @Test
    func markHeldTwice_takesOverDeterministically() async throws {
        let s = MouseHoldState.shared
        await s.resetForTesting()

        // G-phase de-flake. The prior version of this test asserted a
        // NON-event — that the first watchdog does NOT fire before the second
        // markHeld cancels it — by racing a real 300ms→1s timer against the
        // scheduler. Under 16-way parallel-suite load that race lost
        // intermittently (≈1-in-3 even at 1s). A non-event raced against
        // unbounded scheduler delay cannot be made both deterministic AND
        // meaningful without a production introspection seam, which isn't
        // worth adding for one test.
        //
        // What IS deterministic, and what actually matters: a second markHeld
        // takes over (its coordinate wins, state stays held). That the second
        // markHeld ran is itself proof that markHeld's UNCONDITIONAL
        // `watchdog?.cancel()` (straight-line code) executed. Both watchdogs
        // are long here so neither fires during the assertion — no timer race.
        // The watchdog ACTUALLY firing on timeout is covered separately and
        // deterministically by `watchdog auto-release after timeout`.
        await s.markHeld(button: .left, at: .zero, watchdogDuration: .seconds(30))
        await s.markHeld(button: .left, at: CGPoint(x: 99, y: 99), watchdogDuration: .seconds(30))
        #expect(await s.isHeld() == true,
                "two markHelds keep the button held — the second takes over")
        #expect(await s.currentCoordinate() == CGPoint(x: 99, y: 99),
                "second markHeld's coordinate must overwrite the first")

        _ = await s.release()
        #expect(await s.isHeld() == false, "release clears the hold")
    }

    @Test
    func resetForTesting_clearsWithoutPosting() async {
        let s = MouseHoldState.shared
        await s.resetForTesting()

        await s.markHeld(button: .left, at: CGPoint(x: 1, y: 1))
        await s.resetForTesting()
        #expect(await s.isHeld() == false, "resetForTesting must clear state")
    }

    // MARK: - Executor live dispatch
    //
    // CGEvent.post(tap:) silently no-ops on CI runners without TCC grants,
    // so we verify the tracker side-effects rather than actual mouse
    // motion. The behavioral contract: after the executor returns, the
    // MouseHoldState singleton reflects the new OS-side state.

    private func executeLive(_ action: AgentAction) async throws -> String {
        let executor = Executor()
        let snapshot = ObservedSnapshot(
            snapshot: try PerceptionSnapshot.make(
                timestamp: .now, focusedAppBundleID: "com.example.test", elements: []
            )
        )
        return try await executor.perform(action, snapshot: snapshot)
    }

    private func makeAction(_ type: ActionType, x: Double = 100, y: Double = 200) -> AgentAction {
        AgentAction(
            type: type,
            confidence: 0.9, requiresConfirmation: false,
            rationale: "13b live executor test",
            coordinate: CodablePoint(.init(x: x, y: y))
        )
    }

    @Test
    func executor_mouseDown_marksHeldAndReturnsLabel() async throws {
        await MouseHoldState.shared.resetForTesting()
        let result = try await executeLive(makeAction(.mouseDown))
        #expect(result == "mouse button pressed (held)",
                "executionResult must label the receipt as a hold-start, not a click")
        #expect(await MouseHoldState.shared.isHeld() == true,
                "mouseDown must register with the singleton — otherwise the run() defer cleanup can't release on terminal events")
        #expect(await MouseHoldState.shared.currentHeldButton() == .left,
                "Anthropic CU spec only exposes LMB hold today")
        #expect(await MouseHoldState.shared.currentCoordinate() == CGPoint(x: 100, y: 200))
        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_mouseDown_missingCoordinate_throws() async throws {
        await MouseHoldState.shared.resetForTesting()
        let action = AgentAction(
            type: .mouseDown,
            confidence: 0.9, requiresConfirmation: false,
            rationale: "no coord",
            coordinate: nil
        )
        do {
            _ = try await executeLive(action)
            Issue.record("Expected executionFailed for mouseDown without coordinate")
        } catch let error as ExecutorError {
            guard case .executionFailed(let msg) = error else {
                Issue.record("Expected .executionFailed")
                return
            }
            #expect(msg.contains("coordinate"), "error must explain the missing coord")
        }
        #expect(await MouseHoldState.shared.isHeld() == false,
                "throw before post must NOT mark the tracker held — invariant: tracker mirrors OS state")
    }

    @Test
    func executor_mouseUp_releasesHeldState() async throws {
        await MouseHoldState.shared.resetForTesting()
        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 100, y: 200))
        #expect(await MouseHoldState.shared.isHeld() == true)

        let result = try await executeLive(makeAction(.mouseUp, x: 150, y: 250))
        #expect(result == "mouse button released")
        #expect(await MouseHoldState.shared.isHeld() == false,
                "mouseUp must clear the singleton so the run() defer doesn't double-release")
    }

    @Test
    func executor_mouseUp_withoutHeld_throws() async throws {
        await MouseHoldState.shared.resetForTesting()
        do {
            _ = try await executeLive(makeAction(.mouseUp))
            Issue.record("Expected throw — mouseUp without preceding mouseDown is malformed")
        } catch let error as ExecutorError {
            guard case .executionFailed(let msg) = error else {
                Issue.record("Expected .executionFailed")
                return
            }
            #expect(msg.contains("no button held") || msg.contains("mouseUp"),
                    "error must steer the LLM to emit mouseDown first")
        }
    }

    @Test
    func executor_mouseMove_whileHeld_updatesCoordinate() async throws {
        await MouseHoldState.shared.resetForTesting()
        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 0, y: 0))
        let result = try await executeLive(makeAction(.mouseMove, x: 500, y: 600))
        #expect(result == "mouse dragged",
                "mouseMove while held must be labeled as a drag — drag-aware UIs need the dragged event class")
        #expect(await MouseHoldState.shared.isHeld() == true,
                "mouseMove must NOT release the hold")
        #expect(await MouseHoldState.shared.currentCoordinate() == CGPoint(x: 500, y: 600),
                "coordinate must update so the watchdog's eventual mouseUp lands at the last-known cursor pos")
        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_mouseMove_withoutHeld_postsAsHover() async throws {
        await MouseHoldState.shared.resetForTesting()
        let result = try await executeLive(makeAction(.mouseMove, x: 10, y: 20))
        #expect(result == "mouse moved",
                "mouseMove with no hold must NOT be labeled as a drag — hover-state UIs (tooltips, menu submenus) need a mouseMoved event")
        #expect(await MouseHoldState.shared.isHeld() == false,
                "mouseMove without prior mouseDown must NOT mark held")
    }

    @Test
    func executor_drag_releasesPriorHoldBeforeOwnDownEvent() async throws {
        // Reviewer-caught Sev-2: `.drag` posts its own leftMouseDown
        // pair (start → end) but pre-chokepoint did NOT consult
        // `MouseHoldState`. A prior `.mouseDown` held state would have
        // been orphaned when the drag's down posted.
        // Chokepoint helper `releasePriorHoldIfAny` is called at the
        // top of performDrag — so by the time drag posts its own down,
        // the singleton must be clean.
        await MouseHoldState.shared.resetForTesting()
        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 5, y: 5))
        #expect(await MouseHoldState.shared.isHeld() == true, "precondition: prior hold present")

        let dragAction = AgentAction(
            type: .drag,
            confidence: 0.9, requiresConfirmation: false,
            rationale: "drag with prior held",
            coordinate: CodablePoint(.init(x: 200, y: 200)),
            startCoordinate: CodablePoint(.init(x: 100, y: 100))
        )
        _ = try await executeLive(dragAction)
        // After drag finishes (down → drag → up), the singleton should
        // be clean: the prior hold was released by the chokepoint, the
        // drag's own down/up does NOT touch the singleton (intentional —
        // drag is self-contained and stateless w.r.t. the tracker).
        #expect(await MouseHoldState.shared.isHeld() == false,
                "drag must release prior hold AND not leave itself marked held")
        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_click_releasesPriorHoldBeforeOwnDownEvent() async throws {
        // Same chokepoint guarantee for `.click`. The held-mouse safety
        // invariant gates this at .confirm in production, but the
        // chokepoint is the actual cleanup once the user approves.
        await MouseHoldState.shared.resetForTesting()
        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 5, y: 5))
        #expect(await MouseHoldState.shared.isHeld() == true)

        let clickAction = AgentAction(
            type: .click,
            confidence: 0.9, requiresConfirmation: false,
            rationale: "click with prior held",
            coordinate: CodablePoint(.init(x: 200, y: 200))
        )
        _ = try await executeLive(clickAction)
        #expect(await MouseHoldState.shared.isHeld() == false,
                "click must release prior hold via the chokepoint")
        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_mouseDown_whilePriorHeld_releasesFirstThenStartsSecond() async throws {
        // Reviewer-caught Sev-1 regression. Two consecutive .mouseDown
        // actions must NOT leave the first OS-level press orphaned. The
        // executor releases the prior hold before posting the new down,
        // so the singleton ends up tracking exactly the second press.
        await MouseHoldState.shared.resetForTesting()

        _ = try await executeLive(makeAction(.mouseDown, x: 10, y: 10))
        #expect(await MouseHoldState.shared.isHeld() == true,
                "first mouseDown registered")
        #expect(await MouseHoldState.shared.currentCoordinate() == CGPoint(x: 10, y: 10))

        _ = try await executeLive(makeAction(.mouseDown, x: 999, y: 999))
        #expect(await MouseHoldState.shared.isHeld() == true,
                "second mouseDown leaves the singleton held (the new press)")
        #expect(await MouseHoldState.shared.currentCoordinate() == CGPoint(x: 999, y: 999),
                "tracker reflects the SECOND press — the first was released before the second started")

        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_typeTextCoordPath_releasesPriorHoldBeforeFocusClick() async throws {
        // Round-3 reviewer-caught chokepoint gap: `performType`'s
        // .coordinate fallback path posts a focus-click leftMouseDown
        // pair before typing. Same orphan-hold class as the click /
        // drag / multiClick / mouseDown sites — must go through the
        // chokepoint.
        await MouseHoldState.shared.resetForTesting()
        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 5, y: 5))
        #expect(await MouseHoldState.shared.isHeld() == true)

        let typeAction = AgentAction(
            type: .typeText,
            text: "x",  // single char so the test runs fast
            confidence: 0.9, requiresConfirmation: false,
            rationale: "type with prior held",
            coordinate: CodablePoint(.init(x: 200, y: 200))
        )
        _ = try await executeLive(typeAction)
        #expect(await MouseHoldState.shared.isHeld() == false,
                "typeText coord-path focus-click must release prior hold via the chokepoint")
        await MouseHoldState.shared.resetForTesting()
    }

    @Test
    func executor_releaseHeldInputs_isIdempotent() async throws {
        await MouseHoldState.shared.resetForTesting()
        let executor = Executor()
        await executor.releaseHeldInputs()
        #expect(await MouseHoldState.shared.isHeld() == false)

        await MouseHoldState.shared.markHeld(button: .left, at: CGPoint(x: 1, y: 1))
        await executor.releaseHeldInputs()
        #expect(await MouseHoldState.shared.isHeld() == false)

        await executor.releaseHeldInputs()
        #expect(await MouseHoldState.shared.isHeld() == false)
    }
}
