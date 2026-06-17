# Test Coverage Matrix

> Path F deliverable, 2026-05-27. Catalog of end-to-end use cases × test
> tier × current coverage. Motivated by a real dogfood failure
> (Spotlight loop on `"Open Notes"`, 13 actions in 2 minutes, no stall
> detector fired) that revealed a structural gap: T2 scenarios cover
> single-action LLM emission but not multi-step orchestration shapes,
> and stall detectors are single-action counters that miss interleaved
> loops.

## Three tiers

| Tier | Description | Cost | Catches |
|---|---|---|---|
| **T1** | Pure Swift, mocked LLM + mocked executor. `swift test`. | Fast, deterministic, CI-friendly. | Loop mechanics, safety, recovery, stall detectors, schema. |
| **T2** | Live Anthropic API, mocked snapshot fixture. `MacOSAgentSmokeAction` (env-gated `MACOS_AGENT_SMOKE_ACTION=1`). | ~$0.04 per full run at current model rates; opt-in. | LLM strategy regressions in isolation per use case. |
| **T3** | Live LLM, REAL UI on a TCC-permissioned macOS session. | Manual / nightly only — needs GUI session, app fixtures, permissions. | End-to-end orchestration failures: Spotlight loops, animation races, stale-target reflows, multi-app handoffs. |

## Use case catalog × coverage

| # | Use case | T1 | T2 | T3 | Notes |
|---|---|---|---|---|---|
| 1 | **Single-action emission per type** (click, typeText, scroll, menuSelect, switchApp) | ✅ unit tests in `ExecutorTests` + `IntegrationTests` | ✅ `baselineClickScenario`, `typeTextScenario`, `scrollScenario`, `menuSelectScenario`, `switchAppScenario` | ❌ | Strongest layer today. |
| 2 | **App-launch via switchApp — "Switch to X" wording** | ✅ | ✅ `switchAppScenario` | ❌ | Wording-specific. |
| 3 | **App-launch via switchApp — "Open X" / "Launch X" wording** | ❌ no T1 prompt test | ⚠️ Scenario `openAppViaVerbScenario` exists but is **NOT in defaultScenarios** until prompt-tuning lands — currently expected to FAIL per dogfood evidence. Available via `auditScenariosIncludingKnownFailing()`. | ❌ | **Dogfood evidence:** LLM chose `keyCombo cmd+space` instead of `switchApp` for `"Open Notes"`. Hypothesis: "open" verb maps to Spotlight in the LLM's strategy bias. Regression guard ready; fix is prompt-side. |
| 4 | **Cold-launch (target app not in runningApps)** | ✅ unit test for `switchApp` executor path | ❌ T2 fixture has both apps running | ❌ | Unit 17 adds `launchCalculatorColdScenario`. |
| 5 | **Multi-step in single app** (open + then type + then click) | ✅ Unit 24 `MultiStepHarnessTests` (4 mock-LLM mechanic tests) + Unit 20 partial via `IntegrationTests.executorFailureTriggerRecoveryAndRunCompletes` | ✅ Unit 25h — both multi-step scenarios ship in `defaultScenarios()`: `safariSearchSequenceScenario` (3 steps: switchApp → cmd+l → typeText) + `openNotesThenSearchThenCompleteScenario` (3 steps: switchApp → click → typeText). Live audit-mode run 2026-06-03 verified 10/10. | ❌ | Closed by the Unit 25 chain (25 schema, 25b CU integration, 25c audit-mode env switch, 25d/25g fixture corrections, 25e production grounding, 25f imperative prompt rule, 25h un-quarantine). |
| 5b | **Multi-step trajectory verification — `isFocused` schema** | ✅ Unit 25 chain — 6 new tests in PerceptionTests + SnapshotSidecarTests covering Codable back-compat, hash sensitivity, prompt surfacing (both LLMClient JSON and ComputerUseClient line format), and ReceiptReplayFormatter diff. Plus 3 in ComputerUseTranslateTests for isFocused-priority typeText resolution. | ✅ CLOSED — multi-step scenarios in defaults verified at 10/10 in live audit run (2026-06-03). | ❌ | Unit 25 chain (2026-06-03) adds `isFocused: Bool` to `UIElement` + `RawAXElement`; AX walker queries `kAXFocusedUIElementAttribute` once at app level and marks the matching walked element via `CFEqual`. Prompt's imperative MUST NOT rule prevents redundant clicks on already-focused elements. Production Orchestrator appends synthetic user-observation turns between assistant rationales for grounding. CU mode's `nearestFocusedElement` uses isFocused as primary signal for typeText target selection. Snapshot hash rotates once (Codable defaults `isFocused=false` on legacy sidecars). |
| 6 | **Multi-app handoff** (copy from A, paste into B) | ❌ | ❌ | ❌ | Genuine T3-only coverage. Deferred. |
| 7 | **Recovery from executor error** | ✅ `IntegrationTests.executorFailureTriggerRecoveryAndRunCompletes`, `recoveryBudgetExhaustedEmitsFailed`, Unit 14's `targetStaleRecoveryPromptCarriesIndexLabelAndElementCount` | ✅ Unit 20 — `Scenario.forbiddenTargetIndex` + `recoveryFromExecutorErrorScenario` in defaults; T2 harness asserts the LLM honors an inlined "do NOT retry index N" hint | ❌ | T1 covers loop mechanics. T2 covers instruction-following regression. T3 would catch full end-to-end (Orchestrator → LLM → executor → recovery loop) but the layered T1 + T2 closes most of the surface. |
| 8 | **Refusal: KeywordTaskGuard** | ✅ `RedTeamTests.taskGuard_*` | ❌ T2 doesn't exercise the gate | ❌ | LLM never called when guard blocks; no T2 needed. |
| 9 | **Refusal: LLMTaskClassifier HARMFUL verdict** | ✅ `LLMClassifierSuite` 11 tests | ❌ | ❌ | Unit 15's mocks cover this; live LLM is the verdict source so T2 = T3 here. |
| 10 | **Abort mid-run** | ✅ `IntegrationTests` abort paths + Unit 13b held-mouse cleanup | ❌ | ❌ | Operator-side; T1 sufficient. |
| 11 | **Clarification cycle** (agent asks, operator replies, resumes) | ✅ `clarificationResumeCompletesRunSuccessfully`, `consecutiveClarificationsAbortAfterThree` | ❌ | ❌ | T1 sufficient. |
| 12 | **HUD approval decisions** (approve/always/reject/never persistence) | ✅ `RedTeamTests` approval-persistence suite (J.1–J.4) | ❌ | ❌ | UI-side; UI tests would be T3. |
| 13 | **Stall: 10× wait / 10× scroll / 10× same-target click / 3× clarify** | ✅ `OrchestratorTests` stall suite | ❌ | ❌ | T1 sufficient. |
| 14 | **Stall: repeated keyCombo loop** (Spotlight cycle) | ✅ Unit 17 — `IntegrationTests.sameKeyComboStall*` suite (3 tests: fires on interleaved pattern, resets on different combo, resets on click) | ❌ N/A — T1 catches | ❌ | **Dogfood evidence**: 5× `cmd+space` in 12 actions, interleaved with `typeText` and `wait`, no stall fired. H.5a counts `cmd+space` / `cmd+tab` occurrences across calls (scoped to `riskyLoopCombos` to avoid false-positive on tab navigation, paste cycles, etc.). Threshold 4. |
| 14b | **Stall: repeated switchApp loop** (defensive re-emission) | ✅ Unit 27 — H.6 `sameSwitchAppLoop` detector + `IntegrationTests.sameSwitchApp*` suite (3 tests: fires on 2nd same-target, resets on different target, resets on non-switchApp intervening action) | ❌ N/A — T1 catches | ❌ | Closes the Unit 25 audit gap. Strict-consecutive matching (no fillers — defensive re-emission is back-to-back with no intermediates), threshold 2, pre-gate. Recovery branch's user-turn hint at `Orchestrator:880` keeps recovery scenarios working: failed switchApp followed by varied retry targets doesn't trip H.6. |
| 15 | **Stall: no-progress window** (last N actions contain no click/menuSelect/switchApp/complete) | ✅ Unit 22 — H.5b sliding window: 12 actions with no UI-mutating action → stall via `recordStall("noProgressWindow", ...)`; `isProgressMakingAction` whitelist locks the reset semantics | ❌ N/A — T1 catches | ❌ | Progress-list intentionally conservative (8 action types: click variants + menuSelect + switchApp + drag + complete). Tab navigation in long forms could push toward stall; threshold 12 keeps that rare in practice. Raise threshold or expand list if dogfood shows FP. |
| 16 | **Stateful mouse (drag-select, slider grab)** | ✅ `StatefulMouseTests` suite | ❌ T2 doesn't emit `left_mouse_down`/`up`/`move` | ❌ | CU mode only — T2 expansion would need Computer Use client path. Out of scope this unit. |
| 17 | **Multi-monitor cursor / display scale edge cases** | ✅ `ScreenScalerTests`, `ComputerUseCoordRoundTripTests` | ❌ | ❌ | T1 sufficient for math; T3 would catch real display surprises. |

## Gaps closed by Unit 17

| Gap | Closes via |
|---|---|
| Row 3: "Open X" wording → switchApp regression guard | New `openNotesScenario` T2 |
| Row 4: Cold-launch fixture | New `launchCalculatorColdScenario` T2 |
| Row 14: keyCombo loop stall detector | New H.5a `consecutiveSameKeyCombo` counter + test |
| Row 7 (post Unit 20): T2 recovery-prompt guard | New `Scenario.forbiddenTargetIndex` + `recoveryFromExecutorErrorScenario` in defaults |
| Row 15 (post Unit 22): No-progress window stall | New H.5b sliding-window detector + `isProgressMakingAction` whitelist |
| Row 5 (post Unit 24): Multi-step in-app T2 HARNESS | New `Scenario.expectedSteps: [ExpectedStep]?` + `runMultiStep` harness + per-step output (Unit 24a). Scenarios themselves quarantined per Row 5b. |
| Row 14b (post Unit 27): Same-target switchApp loop | New H.6 `sameSwitchAppLoop` detector + 3 `IntegrationTests.sameSwitchApp*` tests; closes the Unit 25 audit gap. |

## Gaps deferred

| Gap | Why deferred |
|---|---|
| Row 5: Multi-step in-app — HARNESS closed, scenarios quarantined | ⚠️ Unit 24 harness mechanic closed Row 5 architecturally; both shipped scenarios moved to audit-only after live T2 surfaced the Row 5b `isFocused` schema gap. Awaiting Unit 25 to un-quarantine. |
| Row 6: Multi-app handoff | T3-only. Build T3 harness first. |
| Row 16: Stateful mouse in T2 | Computer Use path. Add when CU receipt evidence shows real-world hits. |

## T3 feasibility note (research-only)

The Spotlight-loop dogfood failure motivates building a T3 harness eventually. Feasibility:

| Concern | Status |
|---|---|
| TCC permissions on a CI runner | macOS GitHub Actions runners don't have Accessibility / Screen Recording grants. Hard blocker for CI. |
| TCC permissions on operator-local machine | Already granted (agent runs daily). Local nightly cron / lefthook trigger would work. |
| App fixture matrix | Stock apps (Notes, Safari, Finder, Calculator, Mail) installed on every macOS install; safe set for fixtures. |
| Deterministic UI state | Apps mutate (tabs open, sidebars collapse). T3 fixtures must restore known state or assert "lands in any of N valid states." |
| Receipt-based assertions | Already in place — `MacAgentReplay` Unit 16 reads JSONL. A T3 harness writes receipts to a temp `baseURL`, asserts on the chain. |
| Output | Pass/fail summary + diff against expected receipt shape. |

**Sketch (not for this unit):** `Sources/MacOSAgentSmokeE2E/main.swift` — env-gated like the action harness; takes a fixture name (`open-notes`, `safari-search`, etc.), constructs an `Orchestrator` with a fresh temp receipts dir, runs the task, polls until `.finished` or `.failed`, asserts receipt invariants (`outcome=success`, target app frontmost at end, no stall events, ≤N steps). Build cost: ~1 week. Trigger: a second dogfood session producing a NEW failure class that T2 + H.5a can't cover.

## Dogfood evidence anchor

This matrix exists because of a single 2026-05-27 dogfood session:
- Task: `"Open Notes"`
- Result: 13 actions in 2 minutes, 5× `cmd+space` (Spotlight), 5× `typeText`, interleaved waits and one `escape`. No stall fired. No `switchApp`. No `complete`.
- Receipts: `~/Library/Application Support/MacAgent/receipts/2026-05-27.jsonl`, entries `23:55:20Z` through `23:57:14Z`.

The catalog above is the systematic version of what one session of dogfood revealed in one task.
