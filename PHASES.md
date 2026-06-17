# PHASES.md — macOS Agent v0 Beta Phase Map

> This is the authoritative phase tracker. Update status column when a phase completes.
> MANIFEST.md §Known Gaps must be updated whenever a gap is resolved or discovered.
> AUDIT.md closing checklist references this file.
> Last updated: 2026-06-15 — 643/643 tests pass, build clean, doc-gate green.
>
> CURRENT STATE: three major arcs have landed since the original Beta map
> below — all on local feature branches, NOT yet merged or pushed:
>   • H3 perception chain + V1 capabilities (Units 1–27) — on main.
>   • Voice-Ops Tier 1 (Units 28–31) — hands-free operation: F13/F14/F15
>     global hotkeys, gate park-and-heartbeat, wall-clock park ceiling,
>     crash-safe pending-gate journal, stale-approval supersede, stall
>     self-recovery. Branch `feat/voice-ops-tier1` (merged to local main).
>   • Agent-Chat Tier 2 (Units 32–41) — two-way chat + capabilities:
>     clarify park-parity, `say` non-pausing chat, chat-first interface,
>     readClipboard, sandboxed writeFile (shell DEFERRED), keyCombo floor,
>     a11y, operator-drift guard, design tokens. Branch
>     `feat/agent-chat-tier2` then `feat/aesthetic-multiapp`.
>   • Phase G — Real-World Confidence (G1–G5) — born from a confidence
>     audit (see below). On `feat/aesthetic-multiapp`.
>
> Per-unit detail: CHANGELOG.md. Each arc has its own phase section near
> the END of this file (Voice-Ops Tier 1 · Agent-Chat Tier 2 · Phase G),
> with what-shipped + DoD + status. The numbered Phase 0–13 sections below
> are the ORIGINAL Beta map and remain accurate history.
>
> ⚠️ PRE-MERGE GATE: real-world behavioral confidence is UNPROVEN (all
> tests mock LLM+perception+executor). Before merging the Tier-2/Phase-G
> branches to a shipping state, run `docs/live-verification-protocol.md`
> on a real machine. See the "Phase G" section + MANIFEST §Verification
> posture.

---

## Definition of Done — Beta

Beta = the app can be handed to real users for real tasks on any macOS app.
Not App Store. Not signed. Not multi-app. **It works, it's safe, it doesn't lie.**

### Layer A — Automated gates (run on every phase close)

```bash
swift build                          # zero errors, zero new warnings
swift test                           # all pass, no single test > 2s
swift run MacOSAgentSmoke            # exits 0
grep -rn "@unchecked Sendable" Sources/  # each instance has an invariant comment
```

### Layer B — Rubric gates (self-check against AGENTS.md §Rubric)

| Check | Pass condition |
|---|---|
| `swift build` | Zero errors, zero warnings |
| `swift test` | All pass |
| Safety gate unchanged | `SafetyPolicy.classify()` still runs on every action |
| Receipt on every action | Approved AND rejected actions have receipts |
| No new external dependencies | `Package.swift` dependencies array is still `[]` |
| Concurrency | No data races, no `@unchecked Sendable` without comment |
| Scope | Only required files touched |
| Throughline schema | No fields removed from `AgentThroughline` or `TaskRecord` |
| ActionLogEntry schema | No fields removed |
| Smoke test passes | `swift run MacOSAgentSmoke` exits 0 |
| AuDHD defaults | No auto-dismiss UI, no animations >200ms, no flash |

### Layer C — Behavioral burn-in (manual, per phase)

Run these manually when closing a phase.

| Check | Phase | Pass condition |
|---|---|---|
| Free-form task accepted | 1 | Submit "find the clock app" with no preset — not blocked |
| Model self-heal | 1 | Set UserDefaults `selectedModel` to `"claude-sonnet-4-5"`, relaunch — auto-migrates to Sonnet 4.6 |
| Short task skips planner | 1 | Submit "quit safari" — no `📋 Plan:` event in transcript |
| Long task uses planner | 1 | Submit 8+ word task — `📋 Plan:` event appears |
| Throughline persists across runs | 1 | Run two tasks, check `~/Library/Application Support/MacAgent/throughline.json` — both recorded, `last_successful_app` set |
| Vision observations in receipt | 2 | Open Electron app, run task — receipt JSON has non-empty `visionObservations` |
| Vision-only task completes | 2 | Open app with no AX elements, submit task — agent uses vision index to click |
| Composer refocuses | 3 | Run any task — after completion, typing immediately goes to composer without clicking |
| Abort stops in-flight | 3 | Click Abort during LLM think — run stops within 1s |
| No duplicate error display | 3 | Trigger a failed run — error appears once in conversation, no banner |
| Full rubric | 4 | All 11 AGENTS.md §Rubric checks pass |
| Smoke exits 0 | 4 | `swift run MacOSAgentSmoke` exits 0 |

---

## Phase Status

| Phase | Name | Est. | Status |
|---|---|---|---|
| -1 | Reference docs | 10 min | ✅ Done |
| 0 | Preconditions | 30 min | ✅ Done |
| 1 | Polish fixes (6 items) | 90 min | ✅ Done |
| 2 | Vision path completion | 3–4 hrs | ✅ Done |
| 3 | UX for real users | 2–3 hrs | ✅ Done |
| 4 | Beta gate | 1 hr | ✅ Done |
| 5A | Throughline memory UI + TOCTOU fix | 1 hr | ✅ Done (88/88 tests) |
| 5B | Cleanup (autonomy persist, doc counts, memory file) | 30 min | ✅ Done |
| 5C | Partial run recovery (.undo action, clipboard defer, recovery hook) | 2 hrs | ✅ Done (90/90 tests) |
| 6A | Multi-app orchestration (switchApp, RunningApp, appSwitched event) | 2 hrs | ✅ Done (93/93 tests) |
| 6A-post | Audit fixes — deprecated activate API, spurious appSwitched, app-name sanitization | 30 min | ✅ Done |
| 6B | App launch (cold-launch via NSWorkspace.openApplication + 10s timeout) | 1 hr | ✅ Done (95/100 tests) |
| 7 | think() error recovery (transientLLMFailure, independent 3-retry budget) | 2.5 hrs | ✅ Done (100/100 tests) |
| 8 | Demo-mode gating unlock (bundleID on DemoPreset, delete bundleMap, simplify validateSupportedApp) | 30 min | ✅ Done (109/109 tests) |
| terminal/fix | Audit items 1-2-4-5: Unicode sanitizer, negative targetIndex→CONFIRM, 5xx throw, DurationMillis | 1 hr | ✅ Merged |
| terminal/test | RED-TEAM Phase 2: injection/DoS/edge-case tests (B, C, G coverage) | 1 hr | ✅ Merged |
| terminal/chore | Tier-3 cleanup: gate timeout cancel, receipt doc, UI disclosure, FlattenedAXElement dead code | 30 min | ✅ Merged |
| 9 | Error semantics fix + MANIFEST correction | 30 min | ✅ Done (112/112 tests) |
| 10 | Loop mechanic test coverage | 1–2 hrs | ✅ Done (119/119 tests) |
| 11 | Plan step tracking | 2 hrs | ✅ Done (120/120 tests) |
| 12 | Signed .app distribution | — | ✅ Done (Developer ID + notarize.sh + package-dmg.sh) |
| 13 | UI/UX audit — permission UX, 4-button gate, capability rules, menu bar | 4 hrs | ✅ Done (126/126 tests) |

---

## Phase -1 — Reference Docs ✅

Write PHASES.md, update MANIFEST.md and AUDIT.md, create memory file.

---

## Phase 0 — Preconditions ✅

1. `AXPerception.swift:37` — invariant comment on `AXElementLookup @unchecked Sendable` ✅
2. `OverlayWindowController.swift:17` — invariant comment on `OverlayWindowController @unchecked Sendable` ✅
3. `SafetyPolicyTests.swift` — nil targetIndex edge case test ✅
4. `SafetyPolicyTests.swift` — empty label edge case test ✅
5. `PerceptionTests.swift` — hash stability test (caught real bug: `sortedKeys` missing from encoder) ✅

---

## Phase 1 — Polish Fixes ✅

| # | Fix | File(s) | Status |
|---|---|---|---|
| 4 | Model migration — validate stored ID, self-heal on first access | `SettingsView.swift` | ✅ |
| 6 | Demo gate — allow all free-form tasks when no preset active | `AppModel.swift` | ✅ |
| 3 | Planner heuristic — skip for ≤ 6 words or single-verb prefix | `Orchestrator.swift` | ✅ |
| 1 | Wait executor — injectable `waitDuration` (test: 1ms) | `Executor.swift` | ✅ 10.4s → 28ms |
| 5 | Throughline positions — auto-populate `last_successful_app` on success | `AgentThroughline.swift` | ✅ |
| 2 | Throughline concurrency — inline `await record()` at all 6 terminal exits | `Orchestrator.swift` | ✅ |

Test count after Phase 1: 77/77 passing (additional tests added in Phases 0–1).

---

## Phase 2 — Vision Path Completion

*Est: 3–4 hours. Risk: medium.*

**The single biggest functional gap.** Vision OCR captures text + bounding boxes but the LLM never sees it.
When AX tree is empty (Electron apps, some Chromium windows), the agent is effectively blind.

### What to build

1. **Serialize vision observations into LLM prompt** (`LLMClient.swift`)
   - Format: `[VISION-{index}] "{text}" at ({x},{y},{w},{h})`
   - Cap at 80 observations (same cap as AX elements)
   - Vision indices start immediately after last AX index

2. **Resolve vision indices in Orchestrator** (`Orchestrator.swift`)
   - If `targetIndex >= axElementCount`, resolve vision bounding box center → screen coordinate

3. **Update LLM system prompt** to explain vision index semantics (`LLMClient.swift`)

4. **End-to-end test** (`IntegrationTests.swift`)
   - Snapshot with zero AX elements + non-empty vision observations
   - Verify LLM prompt contains vision section
   - Verify action with vision targetIndex resolves to screen coordinate

### DoD
- Layer A passes
- `snapshotWithVisionOnlyProducesClickableAction` test passes
- MANIFEST.md "Screenshot-only mode" marked resolved in §Known Gaps
- Layer C: "Vision observations in receipt" and "Vision-only task completes" pass

---

## Phase 3 — UX for Real Users

*Est: 2–3 hours. Risk: low–medium.*

**3a — Composer focus restore** *(AuDHD rule — non-negotiable)*
After every run completion (success / abort / fail / clarification reply), focus returns to composer.
Files: `LauncherView.swift`, `AppModel.swift`

**3b — Error state deduplication**
Remove `lastError` banner (`LauncherView.swift:134`). Inline conversation errors are sufficient.
Files: `LauncherView.swift`, `AppModel.swift`

**3c — Clarify UX**
Show clarification as a named question, not a generic system log entry.
Files: `AppModel.swift:handle(.clarificationRequested)`

**3d — Abort cancels in-flight calls**
Add `Task.checkCancellation()` in `observe()` and `think()` so abort stops within 1s.
Files: `Orchestrator.swift`

### DoD
- Layer A passes
- AuDHD checklist in AGENTS.md §AuDHD-First Defaults fully passes
- Layer C: "Composer refocuses", "Abort stops in-flight", "No duplicate error display" pass

DoD verified. Test count after Phase 3: 45/45 passing. Phase 3 review fixes applied: `isClarifying` reset in `abort()`, `try?` on receipt update, timeout Task weakly captures Orchestrator via `fireClarificationTimeout()`.

---

## Phase 4 — Beta Gate

*Est: 1 hour. Risk: zero (verification only).*

1. Layer A — all automated gates pass
2. Layer B — all 11 AGENTS.md §Rubric checks pass
3. Layer C — all burn-in checks for phases 1–4 pass
4. Update MANIFEST.md §Known Gaps — mark resolved: Demo-mode gating, Screenshot-only mode
5. Commit: `chore(release): beta gate verification`

---

## What Beta Does NOT Include

- Scheduled / background runs
- Signed .app distribution (deferred — needs Developer ID cert)
- DesktopAgentKit wired as library product

---

## Terminal Branch Summary (merged to main)

Three branches landed from a parallel Claude Code terminal session. All merged to main before Phase 9.

### `fix/audit-items-1-2-4-5`
- `sanitizeForPrompt` — strips Unicode line separators U+2028, U+2029, U+000B, U+000C, U+0085 (prompt injection)
- Negative `targetIndex` → always `.confirm` (was `.preview`)
- Explicit `throw` for 5xx responses in `LLMClient` (was silently retried as bad JSON)
- `DurationMillis.swift` — sub-millisecond precision helper; receipt `durationMs` is now fractional

### `test/red-team-phase-2`
- 6 new tests covering RED-TEAM scenarios B (shell injection), C (Unicode smuggling), G (stall/DoS edge cases)
- `RED-TEAM.md` now 10/10 specs marked ✅

### `chore/tier-3-cleanup`
- `gateTimeoutTask` cancel on approval — eliminates gate-timeout Task leak when user approves quickly
- Receipt doc comment corrects "approved" field semantics
- `LauncherView` info disclosure (keyboard shortcut visible without hover)
- `FlattenedAXElement` dead code deleted from `Executor.swift`

---

## Phase 9 — Error Semantics Fix + MANIFEST Correction

*Est: 30 min. 1 file in MacAgentCore, 1 doc update.*

### 9a — `missingAPIKey` rethrown as `malformedAction` (severity 2)

`think()` catches `LLMError.missingAPIKey`, emits `.failed`, then throws `OrchestratorError.malformedAction`.
`malformedAction.errorDescription` says "The next action from Claude could not be parsed" — wrong message for a missing key.

**Fix:** Add `OrchestratorError.missingAPIKey` case, or reuse `transientLLMFailure` with the correct message
and mark it non-retryable by checking the error type before the recovery branch. Simplest:

```swift
// OrchestratorError.swift — add:
case apiKeyMissing

// errorDescription:
case .apiKeyMissing:
    return "Anthropic API key not found. Add it in Settings or set ANTHROPIC_API_KEY."

// think() — LLMError.missingAPIKey branch:
await emit(.failed(message: error.localizedDescription))
throw OrchestratorError.apiKeyMissing

// run() think-catch — add before transientLLMFailure branch:
} catch OrchestratorError.apiKeyMissing {
    // .failed already emitted — propagate, do not retry
    throw error
}
```

### 9b — MANIFEST.md §Known Gaps stale entry

"Throughline write-back for new boundaries" lists "UI has no way to add hard boundaries — only code."
Phase 5A resolved this: Settings now has an Agent Memory section with hard-boundary editing.
Mark it resolved exactly like the other resolved entries.

### DoD
- `swift build` zero errors/warnings
- `swift test` all pass (109+ tests)
- `OrchestratorError.apiKeyMissing` exists and is thrown by `think()` on `LLMError.missingAPIKey`
- MANIFEST.md §Known Gaps throughline write-back entry marked ✅

---

## Phase 10 — Loop Mechanic Test Coverage

*Est: 1–2 hrs. Tests only. Target: 115+ tests.*

MacAgentCoreTests have thin coverage of Orchestrator loop mechanics. The stall detectors, step budget, 90% warning, and autonomy-mode tier overrides are implemented but never exercised by tests.

### Gaps to cover

| Scenario | Mechanism | Test name |
|---|---|---|
| 50-step limit emits `.stepLimitReached` | `stepCount >= maxSteps` break | `stepBudgetExhaustedEmitsStepLimitReached` |
| Step 45 emits `.warning` | `stepCount == Int(Double(maxSteps) * 0.9)` | `stepBudgetWarningAt90Percent` |
| 10 consecutive `.wait` → stall | `consecutiveWaits >= 10` | `waitStallDetectionBreaksLoop` |
| 10 consecutive `.scroll` → stall | `consecutiveScrolls >= 10` | `scrollStallDetectionBreaksLoop` |
| 10 same-target clicks → stall (pre-gate) | `consecutiveSameTargetClicks >= 10` | `sameTargetClickStallDetectedPreGate` |
| 3 consecutive `.clarify` → `.failed` | `consecutiveClarifications >= 3` | `clarifyDoSGuardEmitsFailed` |
| `autonomous` mode promotes PREVIEW→AUTO at confidence ≥ 0.85 | `AutonomyMode.adjust()` | `autonomousModePromotesPREVIEWToAUTO` |
| `confirmEveryAction` mode demotes AUTO→PREVIEW | `AutonomyMode.adjust()` | `confirmEveryActionDemotesAUTOToPREVIEW` |

### DoD
- All 8 tests pass
- `swift test` count ≥ 117
- No new production code changes (these are test-only)

---

## Phase 11 — Plan Step Tracking

*Est: 2 hrs. 2 files in MacAgentCore + 1 doc.*

The planner decomposes a task into 3–7 ordered steps, but the orchestrator loop never injects current-step context into `think()`. The LLM receives the full plan once (as a system-prompt header) and must self-track, which it does poorly across 20+ steps.

### What to build

**11a — Step counter injection** (`Orchestrator.swift`, `LLMClient.swift`)

Track `currentPlanStep: Int` in the loop (starts at 0). After each successful non-wait/non-scroll action, attempt to increment using a heuristic: ask the LLM (or use a keyword check) whether the last action completed the current step. Simpler first pass: inject current step index as a `[PLAN PROGRESS: step N of M]` header in the user turn of each LLM call, and let the model self-declare step completion via a `planStepComplete` field in its response (optional, defaults false).

If `planStepComplete == true` and `currentPlanStep < planSteps.count - 1`, increment.

**11b — `.planProgress` event** (`OrchestratorEvent.swift`)

`case planProgress(steps: [String], currentStep: Int)` already exists (Phase 6A+). Wire it: emit after every `currentPlanStep` increment.

**11c — AppModel** (`AppModel.swift`)

`handle(.planProgress)` already handles this — confirm wiring is correct after 11b.

### DoD
- `swift build` zero errors/warnings
- `swift test` all pass
- `[PLAN PROGRESS: step N of M]` appears in captured LLM prompts (test assertion)
- `.planProgress` event emitted on step increment (test assertion)
- MANIFEST.md §Known Gaps "Subtask / multi-step plan tracking" marked resolved

---

## Phase 12 — Signed .app Distribution

*Deferred. Requires Developer ID Application cert.*

- Add `.entitlements` file (`com.apple.security.cs.allow-jit false`, `com.apple.security.device.audio-input false`, hardened runtime)
- Update `build-app.sh` to codesign with `--deep --strict --options runtime`
- Notarize with `notarytool` + staple
- Produce a signed `.dmg` via `hdiutil`

**Trigger:** When a Developer ID cert is available in the Keychain. Not a beta blocker.

---

## Phase 13 — UI/UX Audit ✅ Done (126/126 tests)

*Comprehensive permission UX, Claude Code-style capability rules, 4-button approval gate,
HUD phase labels, menu bar status item, and visible apps panel.*

### What shipped

**P1 — Permission UX**
- Permission banner split: orange/blocking when AX missing, blue/advisory when only SR missing
- `requestAccessibility()` added to `Permissions.swift` — fires system dialog on explicit tap
- TCC reset detection: `tccResetDetected` flag on AppModel; info card shown when permissions
  are revoked mid-session (Sequoia monthly re-prompt, re-signing, manual revoke)
- `grantAccessibility()` and `refreshPermissions()` clear the flag on success

**P2 — Welcome screen persistence**
- `hasSeenWelcome` persisted to `UserDefaults(suiteName:)` in `glideToCorner()`
- `showWelcome` reads the flag at init — welcome screen skipped on all subsequent cold launches

**P3 — Capability rules engine**
- New `CapabilityRule.swift` — per-app/per-action allow/ask/deny rules with glob label
  matching, `humanDescription`, `triggerCount`, `lastTriggered` metadata
- New `CapabilityRuleStore.swift` — actor-serialized store, atomic JSON persistence to
  `~/Library/Application Support/MacAgent/capability-rules.json`; deny > ask > allow precedence
- 6 new integration tests covering deny, deny-overrides-allow, safety floor, glob matching,
  persistence round-trip, and baseline equivalence

**P4 — 4-button approval gate**
- `ApprovalDecision` enum: `approveOnce`, `alwaysAllow`, `rejectOnce`, `neverAllow`
- `gate()` returns `ApprovalDecision` instead of `Bool`; legacy `(Bool)` shim preserved for
  existing conformers
- `alwaysAllow` → persists allow rule scoped to action type + app + label prefix
- `neverAllow` → persists deny rule scoped to action type + app
- Step-1 complete escalation gate does NOT persist rules (internal safety check, not user intent)
- Capability rule evaluation inserted between AutonomyMode and gate (Option C placement);
  deny path uses `running = false; return` to correctly exit the while loop
- `SafetyPolicy.isDestructiveOrSensitive()` is the hard floor: allow rules cannot widen
  destructive/sensitive actions
- HUD: Approve / Always (green) / Reject / Never (red) buttons; `PulsingCircle` phase label

**P5 — Rules Settings panel**
- New "Action Rules" section in Settings between Autonomy and Agent Memory
- Shows verdict icon (SF Symbols), `humanDescription`, creation date, trigger count
- Per-rule Revoke button; "Reset All Rules" destructive button
- Index-based divider guard

**P6 — Menu bar status item + visible apps panel**
- `MenuBarExtra` scene in `MacAgentApp.swift` with phase-colored circle icon
- `MenuBarStatusView`: task label, last 3 messages, Stop button, autonomy mode badge
- `@Published var visibleApps: [RunningApp]` on AppModel — refreshed on `.started` and
  `.appSwitched` (not every `.observed` tick to avoid NSWorkspace IPC per step)
- Collapsible "Apps the agent can see (N)" `DisclosureGroup` in `LauncherView`, shown
  only when list is non-empty; refreshed on hub `.onAppear`
- `focusedAppName` updated on each `.observed` event, shown in live activity row

### Post-review fixes applied
- `.deny` capability rule block: was `break` (exited switch only); fixed to `running = false; return`
- Step-1 complete gate: removed inadvertent rule persistence
- `refreshVisibleApps()` moved from every `.observed` to `.started`/`.appSwitched` only
- Rules list divider: switched from `rule.id != last?.id` to index-based guard

### DoD
- `swift build` zero errors/warnings ✅
- `swift test` 126/126 pass ✅
- `CapabilityRule` + `CapabilityRuleStore` files created and tested ✅
- All test overlay mocks updated to `(ApprovalDecision)` signature ✅
- Two commits on main: `c2570a7` (core) + `e24257f` (app layer) ✅

---

## RED-TEAM Phase 3 — Coverage gaps D / E / I / J / K / L / M ✅ Done (143/143 tests)

*17 new tests covering clipboard injection, additional terminal emulators, identity spoofing,
approval-decision persistence, supply-chain integrity, receipt schema, and gate timeout.*

### Production changes

1. `Orchestrator.swift` — Added `private let gateTimeoutDuration: Duration` property.
   Added `gateTimeoutDuration: Duration = .seconds(60)` defaulted init param (after `maxSteps`).
   `gate()` now uses `self?.gateTimeoutDuration ?? .seconds(60)` instead of hardcoded 60s.
   Enables M.1 gate-timeout test with a 1ms injected duration.

2. `LLMClient.swift` — `private let model: String` → `let model: String` (internal).
   Enables `@testable import` access for K.1 model-string invariant test.

3. `TaskPlanner.swift` — `private let model: String` → `let model: String` (internal).
   Enables `@testable import` access for K.3 planner model-string invariant test.

### New tests — `RedTeamTests.swift` (+12 tests → 138 total in file)

| Test | Scenario |
|---|---|
| D.1 `typeText_promptInjectionInTextField_doesNotEscalateTier` | Prompt injection in text field without shell patterns stays .preview |
| D.2 `typeText_receiptCapturesContentVerbatim` | Receipt stores typed text verbatim (cleartext by design) |
| E.4 `typeText_nonAppleShellBundleIDs_requireConfirm` | iTerm2 / Ghostty / Kitty / Alacritty all escalate to .confirm |
| I.1 `identity_requiresConfirmationFalseDoesNotBypassGate` | LLM's requiresConfirmation:false doesn't override .confirm |
| I.2 `identity_maxConfidenceOnDestructiveStillRequiresConfirm` | Confidence 1.0 on destructive target still .confirm |
| I.3 `identity_rationaleInjectionDoesNotAffectTier` | Injection in rationale field doesn't affect safety tier |
| J.1 `approvalPersistence_alwaysAllowCreatesAllowRule` | .alwaysAllow decision persists allow rule in ruleStore |
| J.2 `approvalPersistence_neverAllowCreatesDenyRule` | .neverAllow decision persists deny rule in ruleStore |
| J.3 `approvalPersistence_allowRuleWidensTierAndSkipsGate` | Pre-loaded allow rule widens tier to .auto; gate not called |
| J.4 `approvalPersistence_denyRuleBlocksActionWithoutGate` | Pre-loaded deny rule blocks action; .failed emitted; gate not called |
| M.1 `gateTimeout_silentOverlayParksAndHeartbeats_abortEndsRun` (Phase-3 form auto-rejected; superseded by Unit 29 park-and-heartbeat) | SilentOverlay + 1ms interval → gate parks + repeating .approvalPending; abort ends the run |
| M.2 `gateTimeout_taskIsCancelledAfterGateResolves` | gateTimeoutTask is nil after gate resolves (no Task leak) |

### New tests — `SupplyChainTests.swift` (+5 tests, new file)

| Test | Scenario |
|---|---|
| K.1 `llmClientDefaultModelIsValid` | ClaudeLLMClient.model is a known valid model ID |
| K.2 `packageHasZeroExternalDependencies` | Package.swift declares `dependencies: []` |
| K.3 `taskPlannerDefaultModelIsValid` | ClaudeTaskPlanner.model is Haiku (fast/cheap invariant) |
| L.1 `actionLogEntrySchemaIsComplete` | ActionLogEntry JSON contains all 8 required audit fields |
| L.2 `receiptWriterProducesValidJSONL` | ReceiptWriter writes one JSON object per line, all decode cleanly |

### New mocks added to `RedTeamTests.swift`

- `SilentOverlay` — never calls gate completion; exercises gateTimeoutDuration path
- `AlwaysAllowDecisionOverlay` — returns `.alwaysAllow` (rule-persistence path)
- `NeverAllowDecisionOverlay` — returns `.neverAllow` (deny-rule persistence path)
- `GateCallCountingOverlay` — counts gate presentations; verifies gate skipped by rules

### Deferred (v1 queue)

- **F.6** — Task-level harm classifier: "flag task that could cause widespread system damage before accepting it." No production feature exists; requires a new pre-run LLM classifier. Added to MANIFEST.md §Known Gaps.

### DoD
- `swift build` zero errors/warnings ✅
- `swift test` 143/143 pass, slowest < 2s ✅
- `gateTimeoutDuration` param wired in Orchestrator ✅
- `model` visibility changed to `internal` in LLMClient + TaskPlanner ✅
- `SupplyChainTests.swift` created with 5 passing tests ✅
- PHASES.md updated ✅

---

## Phase VO — Voice-Ops Tier 1 ✅ Done (Layer A/B only; Layer C live-behavioral deferred to Phase G protocol) · Units 28–31 · branch `feat/voice-ops-tier1` → merged to local main

Goal (from the hands-free audit): a user with no hands can operate the app,
approve/reject/abort from any app, and survive slow approvals without the run
dying. Process: per-unit research → plan → cascade → execute → dual-checker +
adversarial fleet → fix → commit.

### What shipped
- **Unit 28/28a** — `GlobalHotkeyMonitor`: F13 approve / F14 reject / F15 abort,
  NSEvent global+local, Accessibility-gated + re-armed on TCC flip; executor
  agent-frontmost backstop for keystroke actions.
- **Unit 29/29a/29b/29c/29d** — gate park-and-heartbeat (no auto-reject);
  `.approvalPending` beep+status; wall-clock park ceiling (`gateMaxParkMinutes`,
  default 60); `PendingGateJournal` crash-safety + launch reconciliation;
  stale-approval supersede (structural screen compare); zombie-park guards.
- **Unit 30/30a** — stall self-recovery at the six H-series sites (per-detector
  budget 2 → honest terminal `.failed`); `.clarificationRequested` now
  exclusive to genuine `.clarify`; run-generation guards for wedged-task reaping.
- **Unit 31** — chain-review fixes (step-1 `.complete` gate made voice-visible;
  stale-run reaping; honest abort attribution).

### DoD ✅
- Layer A (build/test/smoke/app-launch) green; doc-gate green.
- Each unit fleet-reviewed; all confirmed Sev-1/2 fixed in follow-up commits.
- Chain-level adversarial review passed (one Sev-1 found + fixed → Unit 31).
- ⬜ Layer C (live behavioral) — deferred to the Phase G protocol.

---

## Phase AC — Agent-Chat Tier 2 ✅ Done (Layer A/B only; Layer C live-behavioral deferred to Phase G protocol) · Units 32–41 · branches `feat/agent-chat-tier2`, `feat/aesthetic-multiapp`

Goal (the maintainer's direction): genuinely chat with the working agent; expand
capabilities spec-first; clean, AuDHD-friendly, toggleable-complexity UI;
graceful behavior when the operator works in other apps. Single agent (not
concurrent multi-agent — they'd fight one mouse/keyboard).

### What shipped
- **Unit 32/32a** — clarify park-and-heartbeat (gate parity; never auto-answers;
  wall-clock expiry; dead-run + reaping guards).
- **Unit 33/33a** — `say`: non-pausing agent chat (`.agentSaid` → spoof-resistant
  `.agentSpeech` role); filler for all stall detectors (anti-evasion); CU
  text-only fallback maps narration→say, only `?`→clarify.
- **Unit 34/34a** — chat-first interface: `ConversationMessage.kind`
  (.chat/.activity); `TranscriptBuilder.fold` collapses machinery into
  expandable "N steps"; simple↔detailed toggle (`@AppStorage`); safety surfaces
  never fold; approval card present in simple mode whenever a decision pends.
- **Unit 35/35a** — `readClipboard`: preview-floored, autonomy-non-wideable,
  4000-char cap, replay-redacted, floor-bound.
- **Unit 36/36a** — sandboxed `writeFile`: opt-in 0700 workspace, confirm-tier,
  every escape vector rejected (abs/`~`/`..`/leaf+intermediate symlink), live
  enable/disable, alwaysAllow forbidden, contents redacted from the receipt,
  informed-confirm card. **Shell DEFERRED** (`docs/design-fileops-shell.md`).
- **Unit 38/38a** — unknown-keyCombo preview floor + benign allowlist; floor-bound.
- **Unit 39** — accessibility annotations (VoiceOver-navigable chat surface).
- **Unit 40/40a** — operator-drift guard: keystroke/click/drag yield (not inject)
  when the operator switches apps; neutral receipt; pause-after-5; never
  re-asserts focus.
- **Unit 41** — `DesignTokens.swift` (no visual change; one tunable source).

### DoD ✅
- Layer A green throughout; doc-gate green; smoke 9/9; app relaunched clean.
- Every unit fleet-reviewed; confirmed findings fixed (writeFile got the
  heaviest sandbox-escape review in the project — no escape survived).
- ⬜ Layer C (live behavioral) — deferred to the Phase G protocol.

---

## Phase G — Real-World Confidence ⚠️ maintainer-owned rungs done (G1–G5); phase DoD NOT met until the live-verification protocol runs · branch `feat/aesthetic-multiapp`

Goal: born from a confidence audit (an honest assessment: strong logic/
safety-design coverage, near-zero real-world behavioral evidence — all tests
mock LLM+perception+executor; "smoke" only grades proposed actions). Close
every gap that can be closed without a live machine, and equip the operator to close
the rest. Roadmap: `docs/phase-g-real-world-confidence.md`.

### What shipped (maintainer-owned)
- **G1** — extracted + unit-tested the executor's pure math (`visionBoxToScreen`
  descale, `modifierFlags`); an audit blind spot now verified.
- **G4** — `MacAgentReplay --report`: pure tested ConfidenceReport (success/
  stall/yield/error rates, histograms, problems) — burn-in as evidence. Live
  vs the real receipt store: 628 actions, 94% clean. De-flaked the watchdog test.
- **G5** — `scripts/check-invariants.sh` (ActionType↔schema↔executor parity,
  wired into `check.sh`) + AGENTS §Scripted-edit discipline.
- **G2** — independent `/security-review` over the egress/disk surface → clean;
  one TOCTOU candidate filtered (2/10, not a privilege crossing). Record:
  `docs/security-review-2026-06-15.md`.

### Owner = Operator (the actual confidence-movers — these need a real machine and TCC grants)
- **G3 / Rung 1** — one real, watched, end-to-end run. ⬜
- **Rung 2** — fire each safety claim for real, using
  `docs/live-verification-protocol.md`. ⬜
- **Rung 3** — dogfood 20–30 real tasks, then `MacAgentReplay --report`. ⬜

### DoD
- maintainer-owned (G1/G2/G4/G5): ✅ build/test/doc-gate green, fleet/security-reviewed.
- **Phase-level DoD is NOT met until Rungs 1–3 run.** Self-assessed confidence:
  logic ~8/10, real-world behavior ~2/10 until then. Merging ≠ confidence.

---

## Next steps (the pre-merge gate)

1. **Run `docs/live-verification-protocol.md`** on a real machine (A + B rows
   are the minimum). One B-row failure is more informative than 100 green tests.
2. Record results; if green, **merge** `feat/agent-chat-tier2` →
   `feat/aesthetic-multiapp` → main (or squash), then push when ready.
3. Begin dogfood burn-in; review `MacAgentReplay --report` after ~20–30 tasks.
4. Deferred backlog (not blocking): shell capability, elapsed-time staleness
   key, CU screenshot-digest drift check, writeFile `openat`/`O_NOFOLLOW`
   hardening, run-global stall-recovery cap.
