# Changelog

All notable changes to macOS Agent v0 are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Sandboxed file writes** (Unit 36, opt-in) — the agent can save text
  files when you enable "Agent workspace" in Settings. Writes are
  confined to one 0700 folder, require confirmation every time, and
  cannot escape the folder (no absolute paths, no `..`, no symlink
  traversal), overwrite your other files, or execute anything. Off by
  default; the receipt records the path and a content hash, never the
  contents. Shell execution was evaluated and DEFERRED — the agent can
  already drive Terminal under the existing confirm-tier, which keeps
  every command human-approved and on-screen (see
  docs/design-fileops-shell.md).

- **readClipboard action** (Unit 35) — the agent can read the user's
  clipboard text into its context when a task needs it. Privacy
  posture: floors at preview approval and autonomous mode does NOT
  widen it (the content is sent to the model API — a boundary, not a
  UI action); content caps at 4000 chars before entering receipts and
  history; replay redacts the result by default (--show-text reveals),
  matching the typeText payload posture.

- **Chat-first interface with a complexity toggle** (Unit 34) — the
  window now operates like a regular chat by default: your messages,
  the agent's speech and questions, approvals, and outcomes. The
  machinery (step narrations, execution results, app switches) folds
  into calm, persistent "N steps" groups that expand on click — like a
  thinking disclosure. One top-bar button toggles the detailed pane
  (presets, plan strip, transparency panel, every step inline);
  preference persists. Safety surfaces never fold: anything awaiting
  approval, questions, warnings, and failures always render in both
  modes, and all AuDHD structural rules hold (no auto-dismiss, no
  auto-collapse, status as text). Also completes Unit 33a's
  spoof-resistant speech wiring — the .agentSaid handler now actually
  emits the dedicated "Agent says" role (the 33a edit had missed the
  disk; caught and fixed).

- **The agent can talk while it works** (Unit 33, `say` action) — a
  new non-pausing chat channel: `say` renders an agent bubble
  (`.agentSaid`) and the run continues immediately; `clarify` remains
  the pausing, answer-required channel and the prompt teaches the
  difference. say is auto-tier (speech is not an OS action),
  hold-compatible, exempt from confirm-every-action's preview floor,
  and deliberately NOT progress-making — 12 consecutive says trip the
  no-progress stall, and narration between identical clicks/combos/
  clarifies counts as filler so chatter can never defeat the loop
  detectors. Computer Use text-only responses now become say
  (narration) instead of parking the run as a question unless they
  actually end in "?". Combined with Unit 32, this is two-way mid-run
  chat: your composer notes reach the next think(), and the agent can
  answer without stopping. Fleet follow-up (33a): say is a filler for
  ALL loop detectors including H.6/H.1/H.4/supersedeChurn (the
  switchApp→say alternation was the one full-evasion pair); watch mode
  speaks instead of gating speech or rendering a contentless "[Watch]"
  line; spoken text renders in a dedicated "Agent says" role (teal) so
  model-authored words are structurally distinguishable from
  app-authored agent lines — a prompt-injected say cannot impersonate
  system truth; the duplicate proposed-narration bubble is suppressed;
  the CU fallback caps rationale at the schema's 2000 chars; the
  prompt forbids announcing completion via say.

### Fixed

- **Vision-capture failure no longer kills the run** (Track A live
  verification) — discovered on the first live task: when Screen
  Recording was not granted and the current screen had little
  accessibility data, the agent tried to screen-capture for its vision
  fallback, the capture was denied, and the whole run hard-failed with a
  cryptic "declined TCCs for display capture" — contradicting the
  permissions banner, which calls Screen Recording optional. `observe()`
  now catches a vision-capture failure, surfaces one clear "Vision
  unavailable — proceeding with accessibility data only" warning per run,
  and continues on the accessibility-only snapshot. Aborting mid-capture
  still stops the run. Safety is unchanged: every action still goes
  through the safety gate regardless of perception quality.
- **Autonomous mode no longer auto-fires risky keyboard chords**
  (Track A audit, Finding 1) — `.autonomous` widened every preview-tier
  action to auto-run, which silently swallowed three intentional safety
  floors: risky combos (cmd+q, cmd+option+escape force-quit), the
  unknown-chord floor (cmd+ctrl+q lock screen, cmd+shift+3/4 screenshot),
  and dangerous long modifier holds. These now stay at preview in
  autonomous mode, so the operator still sees and approves them. Benign
  editing/navigation chords (cmd+c, cmd+v, tab, …) are unaffected — they
  auto-run as before.
- **Network-fetch-then-execute payloads now force confirmation**
  (Track A audit, Finding 2) — typing `curl …| bash`, `wget …| sh`,
  `bash -c`, `python -c`, or `perl -e` is now treated like `sudo`/`rm -r`
  (always CONFIRM), closing a gap where those landed at preview — and
  could auto-run in autonomous mode — when the focused app was not a
  recognized shell (web-SSH terminals, scripting IDEs).
- **Computer-Use back-channel no longer leaks across tasks**
  (Track A audit, Finding 4) — a queued `cursor_position` answer is now
  cleared when the task changes, so a read-action answer from one run can
  no longer attach to the next run's first tool result.

### Changed

- **Design-token system** (Unit 41) — the app's colours, spacing,
  corner radii, and fonts were inline literals scattered across the
  views (inconsistent radii, several near-identical greys). They're now
  codified in one `DesignTokens` file and applied to the chat surface
  with the same values, so nothing looks different — but the visual
  language is now consistent and tunable from one place for future
  polish.

- **The agent yields when you take over an app** (Unit 40) — if you
  click into a different app while the agent is working, a queued
  keystroke (type/keyCombo/hold land in whatever's frontmost) is no
  longer injected into your app. The executor detects the frontmost
  drift, the agent pauses that action, re-checks the screen against
  the new reality, and decides what to do — it never grabs focus back
  from you. Costs no recovery budget; the message says it's yielding,
  not failing.

- **Unknown key combos no longer auto-fire** (Unit 38) — any keyCombo
  not on an explicit benign allowlist (navigation/whitespace keys +
  ubiquitous reversible editing like cmd+c/v/x/a/z/f) now floors to
  preview approval. Previously unrecognized chords fell through to
  auto, so cmd+ctrl+q (lock screen), cmd+shift+3/4 (screenshot),
  cmd+ctrl+space, and app-specific destructive shortcuts fired without
  review. A multi-press sequence is benign only if every press is.

- **Clarify questions park like gates** (Unit 32, agent-chat Tier 2) —
  a `.clarify` suspension previously auto-resumed after 240+60s with
  "(no reply — timed out)", answering the agent's question FOR a slow
  operator with a fabricated assumption — the same failure class Unit
  29 removed from approval gates. Questions now park with
  `.clarificationPending` heartbeats (beep + "Paused — waiting for your
  answer" status, same cadence as `.approvalPending`), resume only on a
  real answer or abort, and expire at the shared wall-clock approval
  wait limit into an honest "task stopped safely" failure with retry
  instructions — the run never proceeds on an invented answer.

- **Chain-review fixes** (Unit 31, pre-push gate on the voice-ops
  Tier-1 branch) — the chain-level adversarial review (verdict: fail,
  one Sev-1) found what the per-unit reviews structurally missed.
  Sev-1: the step-1 `.complete` confirm escalation was invisible to the
  entire voice surface (its `.proposed` fired at auto tier, so
  `pendingApprovalAction` stayed nil — F13/F14 dead, launcher buttons
  hidden, heartbeat beep suppressed) and post-Unit-29 parked SILENTLY
  for the full ceiling; `.approvalRequired` now arms the approval
  mirror, the gate has three-way expired/aborted/rejected attribution,
  clears its crash journal on approval, and the waiting bubble teaches
  the hotkeys. Sev-2: stale-run reaping — a run wedged past the 5s
  abort drain now reaps at generation guards in run()'s defer and both
  post-act re-entry points, so it cannot fire the new run's gate
  callback via overlay teardown, kill the new loop, release its mouse
  hold, clear its journal, or pollute its history (its own executed
  action is still receipted directly). The journal-clear is re-keyed to
  a parkJournalPending flag and all gate state resets at run() start.
  Confirmed Sev-3s: post-loop aborted throughline record; optional-
  permission grants no longer abort a live run; "Paused" status clears
  on approval; hotkey re-arm on direct permission writes; watch-mode
  alwaysAllow not persisted from a parked gate; actionable retry copy
  on all three terminal stop paths; shared park-ceiling default helper;
  PARITY-ANCHOR comments replace drifting line references; Settings +
  MANIFEST document the Voice Control F13 setup prerequisite; +2
  terminal-contract tests (H.5a/H.6). Deferred to Tier 2 with notes:
  clarify park-and-heartbeat (clarifications still auto-resume after
  240+60s — the same slow-operator class gates no longer have).

- **Stall detectors self-recover before stopping, and stop honestly**
  (Unit 30, voice-ops Tier-1 C) — the six H-series stall sites (wait,
  same-target click, scroll, risky-keyCombo loop, no-progress window,
  switchApp loop) previously killed the run on first detection while
  emitting `.clarificationRequested` — a question whose reply channel
  was never armed (the isClarifying fake-channel bug: the run had
  already ended; an answer went nowhere). Now each detector gets a
  per-run budget of two self-recoveries: the offending proposal is
  suppressed, a corrective hint is injected into conversation history,
  perception refreshes, and the detector re-arms — the LLM usually CAN
  change strategy once told exactly what loop it is in. The firing
  after the budget is an honest terminal `.failed` naming the detector.
  `.clarificationRequested` is now emitted only by genuine `.clarify`
  actions. Every firing still writes its `stalled-<detector>` receipt;
  only terminal firings record a throughline outcome. New
  supersedeChurn detector routes three consecutive approve→supersede
  cycles (volatile screen) through the same machinery, and a superseded
  action no longer resets the no-progress window. AppModel.abort()'s
  run-task drain is bounded at 5 seconds so a wedged non-cancellable
  executor call cannot hang the abort path. 13 tests updated to the
  recover-twice-then-honest-terminal contract; +1 churn test.

- **Unit 30a (fleet follow-up)** — run-generation guards close the
  wedged-task hazards the bounded abort drain opened: a run task that
  un-wedges after the 5s ceiling can no longer overwrite "Aborted" with
  "Finished", clear a newer run's tracking state, or resume its loop
  concurrently with a new run (Orchestrator's while-condition checks
  the generation; AppModel's defer and terminal writes are guarded;
  abort retires the generation). The residual fake-channel instance on
  the .clarify TIMEOUT path is closed (isClarifying clears on the next
  .observed, so a post-timeout operator message routes as a mid-run
  note instead of being silently dropped). Also: the supersede-churn
  streak now breaks on any genuine execution attempt (not just act()
  success); a superseded step-1 action restores the Unit-23 RISKY tier
  floor it consumed; queued operator messages drain BEFORE the stall
  hint so a dictation burst can't evict the hint from the prompt's
  recency window; the H.6 hint sanitizes the LLM-chosen bundle ID; the
  handleStall doc comment distinguishes pre-act suppression from
  post-act (wait/scroll) recovery semantics.

- **Approval-gate timeout parks instead of auto-rejecting** (Unit 29,
  voice-ops Tier-1 B) — previously an unanswered gate auto-rejected
  after `gateTimeoutDuration` (default 60s), which killed the whole
  run. For a hands-free operator (higher approval latency: notice the
  HUD, invoke Voice Control, speak the command) that made every gate a
  60s run-death window. Now the timeout NEVER resolves the
  continuation — the run stays parked on the gate — and emits a new
  `.approvalPending` event as a recurring heartbeat, surfaced by
  AppModel as an `NSSound.beep()` + status line ("Paused — … F13
  approve · F15 abort"). The gate resolves only on an explicit decision
  (HUD / launcher / Unit-28 hotkey); the Abort hotkey is the escape.
  This strengthens the `.confirm`-never-auto invariant rather than
  weakening it: the action still never fires without approval, and now
  it also never gets auto-rejected out from under a slow operator. New
  integration test parks a gate, asserts heartbeat-not-fail, then
  resume-on-approve. Three existing tests that encoded the old
  auto-reject contract (red-team M.1, Phase-4 AX B.3, Phase-4 Vision
  C.5) were rewritten to the new contract: silence parks with
  heartbeats, never executes, and `abort()` remains the escape hatch —
  each polls for its condition with a bounded ceiling so a regression
  fails loud instead of hanging the suite.

- **Park-and-pause hardening** (Unit 29a, fleet findings) — four
  zombie-park vectors closed now that an unanswered gate no longer
  self-terminates: (1) `gate()` refuses to park on a dead run
  (`guard running, !Task.isCancelled`) so an abort that interleaves
  before the park can't strand the run forever; (2) heartbeat emission
  moved behind an actor method that re-checks the gate is still parked,
  killing the stale-beep-after-resolve race; (3) AppModel aborts a live
  run before `configureIfPossible()` replaces the orchestrator (a
  Settings save or permission refresh mid-park previously orphaned an
  immortal beeping orchestrator whose stale gate F13 could still
  approve); (4) `rebuildOrchestrator()` now enforces `!isRunning`
  itself instead of trusting call sites. Also fixed the gate-park
  test's failure branch to wind down via `abort()` (task cancellation
  cannot unpark a continuation).

- **Stale-approval supersede** (Unit 29b, fleet Sev-2) — an approval
  that lands after the gate parked past at least one heartbeat interval
  no longer executes blind. The action's targetIndex and SafetyPolicy
  tier were computed against the screen as it was at propose time; with
  unbounded parking an approve can arrive hours later, and the
  executor's CGEvent fallback would click the old coordinates on
  whatever is there now. The orchestrator re-observes on approve and
  acts only if the screen is structurally unchanged (focused app +
  elements + vision observations — timestamp-independent, deliberately
  not `snapshot.hash`, which embeds capture time). On change, the
  approval is recorded as a receipt (`approved: true`, executionResult
  "superseded…"), a `.warning` surfaces it, and the LLM re-proposes
  against fresh perception. New integration test drives a changing
  screen through park → approve and asserts the click never fires while
  the run still completes.

- **Park ceiling + pending-gate journal + fleet fixes** (Unit 29c) —
  the two operator-decided answers to the unbounded-park exposures,
  plus the 29a/29b verification-fleet findings. (1) Park ceiling: an
  unanswered gate self-REJECTS after `gateMaxParkMinutes` (Settings,
  default 60, 0 = unbounded) with a distinct "approval window expired"
  receipt and recovery message — expiry never approves. (2) Crash-safe
  journal: a park outliving one heartbeat writes `pending-gate.json`
  (0600, same state-file conventions); resolution clears it; an entry
  found at launch becomes a rejection-shaped "unresolved at shutdown"
  receipt, so a force-quit mid-park can no longer erase the evidence a
  gated action was proposed. (3) Fleet Sev-1: the stale-approval
  re-observe now writes the approved receipt before rethrowing when
  perception fails mid-re-check (AX revoked during a long park).
  Fleet Sev-2s: captureOrigin joined the supersede comparison (a moved
  window with identical content no longer passes as unchanged), and
  replay renders superseded receipts as ⏭ instead of ✓. Also: abort is
  attributed as "aborted" (not "rejected by the user") in receipts,
  events, and throughline; alwaysAllow rules persist only after the
  supersede check passes; `.appSwitched` fires across the park-time
  re-observe; a manual no-change permission Refresh no longer aborts a
  live run; Settings saves refuse while a task runs (unified with the
  rebuild policy); abort() drains the run task so stale terminal events
  can't overwrite fresh state. MANIFEST documents the parked-approval
  model and the accepted synthetic-keystroke residual (filtering would
  break Voice Control — the exact input path this feature serves).

- **29c fleet follow-up** (Unit 29d) — both Sev-2s plus confirmed
  Sev-3s from the 29c verification fleet. (1) The pending-gate journal
  now clears at the receipt-write chokepoint, only after a receipt for
  the parked step is durably on disk — clearing at decision time left a
  crash window spanning the supersede re-observe plus the whole act()
  execution in which a decided action had zero trace, defeating the
  journal's purpose. Watch-mode and write-failure paths covered; the
  reconciliation wording accounts for the rare double-entry. (2) The
  park ceiling is now a live provider read at each heartbeat —
  previously the Settings value only reached a NEW orchestrator on an
  unrelated rebuild, so "applies from the next task start" was false;
  tightening the ceiling now applies to a gate already parked, and the
  ceiling is measured in wall-clock time (ContinuousClock survives
  machine sleep — an overnight lid-closed park expires on the first
  post-wake heartbeat) instead of heartbeat count. Also: two stale-
  heartbeat re-checks (after the journal-write and emit suspensions)
  close the heartbeat-1 stale-beep and expired-mislabel races; a
  corrupt journal is reported as unreadable instead of silently
  destroyed (decode-before-delete, 64 KB read cap, tier validated
  against SafetyTier); the bootstrap bubble reflects whether the
  reconciliation receipt actually wrote; an abort racing the supersede
  re-observe records its throughline entry; rejected/expired runs no
  longer end with status "Finished"/success; abort sets a matching
  failure outcome; the while-running refusal copy says to re-apply;
  stale AGENTS.md "60-second gate timeout" rule rewritten to the
  park-and-ceiling contract; ceiling test gained a watchdog so a
  regression fails loud instead of hanging CI.

### Added

- **Voice-reachable global hotkeys** (Unit 28, voice-ops Tier-1 A) —
  `GlobalHotkeyMonitor` binds F13/F14/F15 to Approve/Reject/Abort via
  NSEvent global + local monitors (no external dependency; uses the
  Accessibility grant the agent already holds). Routed through the
  existing `approve()`/`reject()`/`abort()` chokepoints — a hotkey
  approval is an explicit human decision that flows through the same
  `applyDecision` gate and emits the same receipt; no auto-approve
  bypass. Lets a hands-free operator answer an approval gate or
  emergency-stop a run from any app by voice ("Press F13"). Bindings
  shown in Settings → Voice Control Hotkeys. Closes hands-free-audit
  blocker #2 (no voice-reachable kill switch).
- **Executor agent-frontmost backstop** (Unit 28) —
  `Executor.agentFrontmostGuardError` extends the existing menuSelect
  guard to typeText/keyCombo/holdKey: `perform()` blocks a
  keystroke-injecting action when the agent itself is frontmost, so an
  approved action can never land in the agent's own window after a
  focus-steal. Closes hands-free-audit blocker #1 (approval focus-steal
  corruption). 8 new T1 tests cover the keyCode→intent decode and the
  guard across all three keystroke action types.
- **Hotkey grant-gating** (Unit 28a, verification-fleet follow-up) —
  the cross-app global tap is gated on the Accessibility grant
  (`start(includeGlobal:)`, exposed via `globalActive`) and re-armed in
  `silentPermissionRecheck` when the grant flips, so the emergency
  Abort brake isn't silently dead if Accessibility is absent at launch
  or revoked mid-session. The agent-frontmost (local) monitor is
  unaffected — it needs no grant. Settings copy corrected to reflect
  the always-on, grant-dependent-for-cross-app scope.

- **H.6 `sameSwitchAppLoop` runtime stall detector** (Unit 27) — closes
  the audit gap surfaced by the Unit 25 chain: defensive `switchApp`
  re-emission (LLM emits switchApp to a target, then immediately again
  "to ensure it is the active application"). Strict-consecutive
  matching with threshold 2, pre-gate. Sibling of H.5a but tighter:
  no filler allowance because the defensive pattern has no natural
  intermediates. Coverage-matrix Row 14b closed. 3 new T1 tests:
  `sameSwitchAppLoopStallFiresOnSecondConsecutiveSameTarget`,
  `sameSwitchAppCounterResetsOnDifferentTarget`,
  `sameSwitchAppCounterResetsOnNonSwitchAppAction`.

### Changed

- **`switchAppUnknownBundleIDTriggersRecovery` test** updated to use
  `SequencedLLM` with varied bundle ID targets per iteration so it
  continues to exercise the recovery-budget-exhaustion path without
  false-tripping the new H.6 detector. Prior `FixedLLM` fixture was
  structurally unrealistic (a real LLM seeing a recovery hint wouldn't
  re-emit the identical failing action).

## [0.2.0-beta] — 2026-06-07

169 commits since `v0.1.0-beta`. Test suite grew 177 → 573. Headline changes: Computer Use is back on with a dedicated model picker, the H3 chain (agent-self-occlusion fix), the stateful-mouse safety invariant, end-to-end stale-target + disabled-target recovery, the H-series stall detector family (H.5a / H.5b / `recordStall` chokepoint), receipt-replay observability (CLI + snapshot sidecar + positional diff), the LLM harm classifier with RISKY tier-floor, and the multi-step T2 regression harness backed by an `isFocused` schema field and production-side conversation grounding.

### Computer Use re-enable + correctness pass (19-commit series)

- **Computer Use mode is back on**, with a dedicated model picker separate from
  the action LLM. Whitelist: `claude-opus-4-7` (1:1 coords), `claude-opus-4-6`,
  and `claude-sonnet-4-6` (default; coords scaled to a 1568-px long edge per
  Anthropic's `computer-use-2025-11-24` docs). `ScreenScaler.swift` does the
  downsample + inverse rescale; coords land at the right screen point on every
  display.
- **`KeywordTaskGuard` is now wired in production.** MANIFEST §Phase Status F.6
  claimed it shipped; `AppModel.makeOrchestrator` never overrode the
  `PermissiveTaskGuard` default. Fixed + regression test in
  `AppModelTaskGuardTests`.
- **`AgentAction.modifiers: String?`** — new optional field for shift/cmd-click
  and modifier-scroll. Append-only-safe: old receipts decode unchanged.
  ComputerUseClient reads the `text` modifier param from Anthropic CU actions;
  Executor applies `CGEventFlags` to click + scroll variants.
- **JSON null in tool_use input** — `AnyDecodable.init` now has an explicit
  `decodeNil` branch. Pre-fix, every `clarify` / `complete` / `switchApp`
  response failed with `DecodingError.dataCorrupted`. The CU sibling
  `AnyCodable` got the same fix + branch-order alignment.
- **CU translator wire-format fixes:** scroll reads `scroll_direction` /
  `scroll_amount` (every scroll silently fell to default before).
  `nearestElement` gains a 100-pt distance threshold so SafetyPolicy's
  coord-only `.preview` floor + Executor's coordinate fallback activate.
  `coordinate(from:)` returns `nil` (not `.zero`) on malformed input.
  `x11KeysToMacOS` preserves `ctrl` as Control (was wrongly remapping to
  Cmd, silently breaking terminal SIGINT) and maps `super` → `cmd`.
- **`captureScreen` migrated to ScreenCaptureKit.** `CGWindowListCreateImage`
  was deprecated in macOS 14.
- **LauncherView in-window approval card.** Approve / Always / Reject / Never
  buttons with `⌘↩` and `⎋` shortcuts route through the same
  `OverlayModel.decide` chokepoint as the HUD. AuDHD-first: the safety gate
  is reachable from where the user is looking.
- **HUD geometry uses `visibleFrame`** so the panel clears the menu bar /
  notch on notched MacBook Pros.
- **Concurrency + hygiene:** `Executor.performType` / `performMenuSelect`
  async + `Task.sleep`; `PulsingCircle` honors `accessibilityReduceMotion`;
  `AppModel` activation observer cleaned up in `deinit`; `ComputerUseClient`
  gained the same retry ladder as `ClaudeLLMClient`; capability `allow`
  rules narrowed to only widen `.confirm → .preview`.

Test suite grew from 177 → 235.

### Prompt-injection sanitization at every prompt-bound site

- **Sanitize chokepoint replicated** across every place an external string
  enters an LLM-bound prompt: operator-typed task, plan label, planner
  prompt, throughline `promptBlock()`, CU `buildSystemPrompt` (AX labels,
  app names, history content), `Orchestrator` plan-step injection.
  Codepoint set matches `AgentThroughline.promptBlock()` (U+2028, U+2029,
  NEL, VT, FF, plus CR/LF). `ClaudeLLMClient.sanitizeForPrompt` is the
  canonical helper.
- **Throughline scrubs on load + sanitises on write** — defence-in-depth
  for older JSON files written before sanitise-on-write landed.
  Idempotent. Test exercises the `appBundleID` sanitise path in
  `promptBlock`.

### Autonomous-mode safety floors

- **Coord-only click + typeText hold `.preview`** even under
  `autonomous` mode — `AutonomyMode.adjustedTier` exception preserves
  the `SafetyPolicy` floor that's structurally important when
  `targetIndex` is nil. Autonomous mode auto-approves `.preview` for
  any action that DOES have a confirmable target.
- **Drag floor-bind** mirrored in the capability-rule predicate so
  an `allow` rule cannot widen drag below `.preview`.
- **CU blind-type flag**: when `nearestFocusedElement` returns nil or
  low confidence, the translated `typeText` carries
  `requiresConfirmation: true`. Documented intent in the receipt
  without changing the tier (tier is already `.preview` via
  `classify()`).

### Perception correctness

- **AX lookup rebuild post-prune** — `AXPerception.capture` now
  rebuilds the per-snapshot `AXElementLookup` after the visible-only
  filter so `Executor.resolveTarget` maps a post-prune `targetIndex`
  back to the correct AX element instead of dispatching to the wrong
  one.
- **AX press fallthrough** — `Executor` falls through to a coordinate
  click on AX press codes `-25200` / `-25202` / `-25205` (locked
  against extra observes).
- **Cached PNG dim alignment** — CU uses the cached PNG's pixel dims
  + snapshot-stored logical size to map Anthropic CU coordinates
  rather than the live `NSScreen.main`, surviving display geometry
  shifts between capture and send.

### Secrets + state-file hardening

- **Keychain-only API key** with one-shot migration from the
  plaintext-file fallback that existed before. Service identifier is
  injectable for test isolation.
- **`0600` file mode + `0700` parent dir** enforced on every write
  to the receipts directory. Same chmod path on the throughline file
  (relocated to `~/Library/Application Support/MacAgent/`).

### AuDHD UI refactor + welcome cleanup

- **Single `PulsingDot` component** replaces the prior duplicate
  patterns; honors `accessibilityReduceMotion`. `KeystrokeOverlay`
  deleted as dead code. `PulsingDot` reads frontmost app from
  `NSWorkspace` (not snapshot-derived) and color is required.
- **Action narrations excluded from LLM context** — `.started`,
  `.appSwitched`, and execute-side announcements no longer become
  conversation turns. Reduces prompt bloat and removes a
  narration-loop failure mode.
- **`typeText` payload redacted on non-`confirm` tier** so receipt
  entries don't echo user-typed secrets unless explicitly approved.
- **Decorative entrance animations removed** from `WelcomeView`;
  documented carve-out (γ) explains the kept glide; `hasSeenWelcome`
  correctly lives in `UserDefaults`, not Keychain.

### Action-model regression smoke (`MacOSAgentSmokeAction`)

- **Env-gated live-LLM smoke harness** (`MACOS_AGENT_SMOKE_ACTION=1`)
  that runs a deterministic set of scenarios against the action
  model and exits non-zero on regressions in action-type emission.
  Crafted to catch the failure class the 2026-05-23 audit found
  (Haiku 4.5 regressing to click-only under the multi-tool schema).
- **Honest scope framing** in MANIFEST: harness asserts the FIRST
  emitted action per scenario, not multi-step trajectories. The
  multi-step gap closes later in this release via Unit 24.

### Launcher polish

- **Resizable launcher window** with persisted size. Composer-focus
  delay routed via `Task @MainActor`. Glide animation honors the
  persisted size. Activation observer cleaned up on close.
- **In-window approval card** in `LauncherView` — `Approve` / `Always`
  / `Reject` / `Never` buttons with `⌘↩` and `⎋` shortcuts route
  through the same `OverlayModel.decide` chokepoint as the HUD.
  AuDHD-first: the safety gate is reachable from where the user is
  looking.

### H3 chain (agent-self-occlusion fix, Units 1-12)

- **Refused to walk agent's own AX tree on `observe()`** —
  `AXPerception.resolveTargetApp` returns the operator's previous
  app when the agent is frontmost, falling back gracefully when no
  fallback is available (cold-start path).
- **Excluded agent's own windows from CU + Vision screenshots** so
  the LLM never gets visual evidence of the agent's HUD as a
  click target.
- **Wrote throughline + emit `.failed` when `observe()` throws** —
  no silent stalls when perception breaks mid-run.
- **Cold-start enablement** via the Anthropic system-prompt
  pattern: when the agent is frontmost with no fallback, the
  cold-start directive tells the model to dispatch `switchApp`
  as its first action.
- **`PerceptionSnapshot.agentIsOverlaid`** field warns the LLM to
  `switchApp` before clicking when the agent's overlay would
  intercept the click.
- **Doc-drift CI** — first repo-level CI workflow gates the test
  count cited in `PHASES.md` and `MANIFEST.md` against the actual
  suite size, failing the build on drift (Path B / Unit 12).

### Stateful mouse with safety invariant (Units 13a, 13b)

- **`ActionType.mouseDown` / `.mouseUp` / `.mouseMove`** added to
  the schema with CU translator wiring and Executor stubs (Unit 13a).
- **Live `MouseHoldState` actor singleton** with 30-second watchdog
  posts `mouseUp` at the last-known coordinate and writes a
  `MouseHeldTimeout` receipt if Claude never emits the release
  (Unit 13b).
- **`SafetyPolicy.heldMouseAdjusted` invariant** promotes
  cross-cutting actions (typeText, keyCombo, etc.) to `.confirm`
  while a button is held. Catches the "Claude starts typing while
  button held" failure class.
- **Terminal events** (`.finished` / `.failed` / `.stepLimitReached`)
  call `executor.releaseHeldInputs()`. `AppModel.abort()` does the
  same as belt-and-suspenders.

### Stale-target + disabled-target recovery (Units 14, 18B)

- **`ExecutorError.targetStale(actionType, requestedIndex,
  elementCount, lastKnownLabel)`** thrown by `resolveTarget` on
  AX/vision out-of-bounds and by `performClick` on AX press codes
  `-25200` / `-25202`. Orchestrator recovery loop emits a specific
  labelled hint so the LLM stops re-picking the same dead index
  across fresh snapshots (receipt evidence from 2026-05-23 showed
  `targetIndex=216` failing against 4 distinct snapshot hashes).
- **`ExecutorError.targetDisabled(actionType, requestedIndex,
  label)`** is the symmetric variant for "element is in the
  snapshot YET DISABLED" — recovery prompt tells the LLM to satisfy
  the enabling condition rather than re-observe.

### LLM harm classifier with RISKY tier-floor (Units 15, 23)

- **`LLMTaskClassifier`** wraps `KeywordTaskGuard` with a single
  Haiku call before `emit(.started)`. Verdicts: `SAFE` / `RISKY` /
  `HARMFUL`. Closes the F.6 v1 stretch goal.
- **In-session `SHA256`-keyed verdict cache** (32 entries, FIFO).
  Memory-only — no fourth state file.
- **Graceful network degradation**: any failure path returns nil
  (allow) so the LLM call cannot deny-of-service the operator's
  own runs. Base guard remains the floor.
- **`TaskGuarding.tierFloor(task:) -> SafetyTier?`** parallel
  protocol method with a nil-returning default extension. Only
  `LLMTaskClassifier` overrides — production guards stay unaffected.
- **`SafetyTier: Comparable`** so `max(tier, floor)` is well-defined.
- **First-step-only escalation** — Orchestrator reads the floor
  once after `shouldBlock` passes, applies `tier = max(tier, floor)`
  on step 1, then clears. Operator confirms the trajectory once;
  the rest of the task follows the normal `SafetyPolicy` +
  `AutonomyMode` + capability chain.

### Receipt-replay observability (Units 16, 19, 21)

- **`MacAgentReplay` CLI** — new executable target. `--date <YYYY-MM-DD>`
  reads the daily JSONL receipt file; `--errors` filters to
  rejection / error rows; `--show-text` widens column padding.
- **Snapshot sidecar** (Path D Candidate 3 Phase 2a) —
  `SnapshotWriter` and `SnapshotReader` actors persist
  `PerceptionSnapshot` JSON at
  `snapshots/YYYY-MM-DD/<hash>.json`. Opt-in via Settings →
  Forensics; default off. `screenshotPNG` stripped by default.
  Fourth state file under AGENTS.md §Agent State Files chmod
  compliance.
- **`--snapshot <hash-prefix>`** pretty-prints the full element
  + vision-observation tables from a stored snapshot file.
- **`--prune-snapshots --older-than N`** for retention.
- **`--diff <hash-A-prefix> <hash-B-prefix>`** (Phase 2b) — positional
  snapshot diff via `ReceiptReplayFormatter.formatSnapshotDiff`.
  Header summary + per-index `CHANGED` / `ADDED` / `REMOVED`
  rendering with affected-field names; identical-hash short-circuit;
  metadata-only-difference explicit surfacing.

### H-series stall detector family (Units 17, 18A, 22, Path F)

- **H.5a: same-keyCombo stall** — counts `riskyLoopCombos`
  (`cmd+space`, `cmd+tab`, `cmd+option+escape`) across the run,
  interleaved with typeText/wait. Threshold 4. Fires
  `.clarificationRequested` with an explicit "use `switchApp`"
  recovery hint. Closes the 2026-05-27 dogfood Spotlight loop.
- **H.5b: no-progress window** — sliding 12-action window resets
  on user-visible-progress actions (click / doubleClick /
  tripleClick / rightClick / menuSelect / switchApp / drag /
  complete); stalls otherwise via
  `recordStall("noProgressWindow", ...)`. Complements H.5a's
  specific risky-combo detection with general "stuck" coverage.
- **`recordStall()` chokepoint** wired at all 5 H-series stall sites
  (H.1 wait, H.2 clarifyDoS, H.3 sameTargetClick, H.4 scroll, H.5a
  sameRiskyKeyCombo). Each fire writes
  `ActionLogEntry(approved: false, tier: "confirm",
  executionResult: "stalled-<detector>")`. `MacAgentReplay --errors`
  now surfaces every stall.
- **Adversarial UX/UI audit** (Path F) — `docs/test-coverage-matrix.md`
  catalogs use cases × tier coverage. 2 new T2 scenarios in
  `ActionRegressionScenarios` close the "Open X" verb gap +
  cold-launch gap revealed by the 2026-05-27 dogfood.

### Multi-step T2 regression harness + isFocused chain (Units 20, 24, 25)

- **`Scenario.expectedSteps: [ExpectedStep]?`** opt-in additive field
  on `ActionRegressionScenarios.Scenario`. Existing single-action
  scenarios are unchanged.
- **`ActionRegressionScenarios.runMultiStep`** walks each step with
  production-parity history append (mirrors `Orchestrator.swift:1100`
  with a 6-entry cap) and `ExpectedStep.advanceSnapshot` simulating
  executor effect. Fail-fast on first divergence saves API spend.
- **Per-step output** in `MacOSAgentSmokeAction` surfaces which
  step diverged + the LLM's rationale for triage.
- **`Scenario.forbiddenTargetIndex`** field + `recoveryFromExecutor
  ErrorScenario` in defaults — closes coverage-matrix row 7's T2
  regression guard for Unit 14's stale-target recovery prompt.
- **`UIElement.isFocused: Bool`** added to the schema with Codable
  back-compat (`decodeIfPresent` defaults legacy sidecars to false).
  `RawAXElement` gets the matching field.
- **`AXPerception` walker** queries `kAXFocusedUIElementAttribute`
  once at app level (single IPC) and marks the matching walked
  element via `CFEqual`. Snapshot hash rotates once for new captures.
- **Standard-path prompt JSON** surfaces `isFocused`; CU line
  format surfaces `focused:true` only when true (terse). Imperative
  Rules-block directive: "You MUST NOT click or re-issue switchApp
  on an element whose isFocused is already true."
- **CU `nearestFocusedElement`** uses `isFocused` as primary signal
  for typeText target resolution above the existing lastClick +
  first-enabled fallbacks.
- **`ReceiptReplayFormatter`** elements table gains a `focused`
  column and the diff lists `isFocused` changes.
- **Production conversation grounding** — `Orchestrator.think`
  appends a synthetic `user`-role observation turn
  (`"Previous action observed: <result>"`) after each successful
  action, mirrored in `runMultiStep`. Closes the defensive
  re-action gap on long trajectories. `conversationHistory` cap
  bumped 6 → 12 to preserve the prior effective 6-action depth
  under the new pairing.
- **2 multi-step scenarios** ship in `defaultScenarios()`:
  `safariSearchSequenceScenario` (3 steps: switchApp → cmd+l →
  typeText) and `openNotesThenSearchThenCompleteScenario` (3 steps:
  switchApp → click → typeText, dogfood-anchored). Live audit-mode
  T2 smoke verified at 10/10 on 2026-06-03.
- **`MACOS_AGENT_SMOKE_INCLUDE_AUDIT=1`** env switch on
  `MacOSAgentSmokeAction` runs the audit set
  (`auditScenariosIncludingKnownFailing()` = defaults + 1 known-
  failing `openAppViaVerbScenario`).

Test suite grew from 235 → 573.

### Added

- **`docs/v1-capability-candidates.md`** — Path D V1+ research doc.
  Three structured candidate analyses (stale-target recovery, harm
  classifier, receipt-replay CLI) plus Tier-2 research-only entries
  (multi-step T2, throughline auto-summary, multi-monitor cursor)
  and a Tier-3 trigger-blocked roster (5 items each with a testable
  pull-forward trigger and the doc pointer for design context).
- **`docs/dogfood-loop.md`** — Path E. Loop runbook: what to dogfood,
  how to capture evidence, when to escalate to a unit.
- **`docs/test-coverage-matrix.md`** — Path F audit deliverable. Use
  cases × T1/T2/T3 coverage rows. Closed rows tracked alongside
  open gaps.
- **Dual MIT / Apache-2.0 licensing** — `LICENSE-MIT` + `LICENSE-APACHE` at repo root,
  per the Rust ecosystem convention. Copyright assigned to Southern Reach LLC.
- **Governance docs** — `SECURITY.md` (vulnerability disclosure policy with private
  channel and 7-day acknowledgement SLA), `CONTRIBUTING.md` (solo-maintained beta;
  not accepting external contributions during beta), `CODE_OF_CONDUCT.md`
  (Contributor Covenant v2.1).
- **GitHub issue templates** — structured YAML forms for bug reports and feature
  requests; `config.yml` disables blank issues and redirects security reports to
  the private disclosure channel.
- **Mermaid architecture diagram** in README replaces the prior ASCII loop block.
- **`scripts/check.sh`** — single-command local CI. Runs build (zero-warning gate),
  test, app bundle assembly, and live API smoke test in one pass. Output mirrored
  to `.local-ci.log` (gitignored) — failure trap surfaces the log path for
  post-mortem.
- **Repo metadata** — GitHub topics, homepage URL pointing at the latest release.

### Changed

- **Bundle ID renamed** from `com.loganfreeman.macos-agent-v0` to
  `com.southernreach.macos-agent-v0` to align with the Southern Reach LLC copyright
  on the LICENSE files. **Breaking for existing installs:** macOS scopes TCC,
  Keychain, and UserDefaults by bundle identifier, so Accessibility permission
  must be re-granted and the API key must be re-pasted via Settings after upgrade.
  Receipts and capability rules survive (they live at hardcoded paths under
  `~/Library/Application Support/MacAgent/`, not bundle-scoped).
- **README** rewritten for public-beta posture — quickstart, privacy disclosure,
  install paths (DMG + source), safety-model summary, costs, license section.
  Adds status badges (license / macOS / Swift / beta).
- **`scripts/notarize.sh`** — redacted parenthetical example values for `APPLE_ID`
  and `TEAM_ID`; generic placeholders now.
- **`ROADMAP.md`** — absolute home-dir path in Verification Commands snippet
  swapped for `<repo-root>`.

### Fixed

- **RED-TEAM coverage status markers** reconciled through Phase 4; four
  post-review issues in the coverage matrix corrected.

## [0.1.0-beta] — 2026-05-11

First public-history milestone. See the
[GitHub Release page](https://github.com/Stray-South/macos-agent/releases/tag/v0.1.0-beta)
for the published version of these notes.

### Added

- **Capability rule system** — per-app / per-action allow / ask / deny rules with
  `deny > ask > allow` precedence. 4-button HUD approval card (Approve once /
  Always allow / Reject / Never allow) creates persistent rules inline.
- **Persistent activity transparency** — phase-aware HUD (`Observing…` /
  `Thinking…`), menu bar status item, plan progress strip, live activity row
  with focused-app indicator.
- **RED-TEAM adversarial test suite** — 65 specs across AX injection, Vision OCR
  injection, throughline poisoning, identity spoofing, excessive agency, DoS /
  loop abuse, sensitive data exposure, supply chain, and AuDHD-specific safety
  regressions. Citations to OWASP LLM Top 10, OWASP Agentic AI Threats v1.0,
  MITRE ATLAS, and 20+ arxiv papers.
- **Four autonomy tiers** — `confirmEveryAction` / `semiAutonomous` /
  `autonomous` / `readOnly` (Watch — observe + plan, never execute).
- **`MacOSAgentV0Tests` target** — closes coverage for AppModel-level error
  surfacing (F1, F2, F5).
- **TCC reset detection** — when permissions previously granted go missing
  (re-signed binary, monthly Sequoia re-prompt), the UI surfaces a soft
  "Permissions reset" card rather than the orange-blocking banner.

### Changed

- **`OrchestratorEvent.receiptWriteFailed`** — new event variant; receipt
  write failures now render as orange `.system` bubbles instead of green
  `.agent` bubbles (wrong role).

### Fixed

- **Error surfacing in Settings-driven config changes** — `ClaudeLLMClient`
  init failures (missing API key) on model / perception / autonomy changes
  now produce a visible system bubble instead of silently retaining the
  prior orchestrator.
- **Mid-run autonomy mode changes** emit "Autonomy: ⟨mode⟩ — applies next
  task" so the deferral is visible to the user.
- **Open Receipts Folder** surfaces errors via `receiptLoadError` instead
  of swallowing with `try?`.
- **Corrupt JSONL receipt lines** are counted; Settings receipt section
  header surfaces "N unreadable" when the loader encounters bad lines.

### Security

- **Sanitizer mirrors `AgentThroughline.promptBlock()` codepoint set** —
  strips U+2028, U+2029, U+000B, U+000C, U+0085 in addition to `\r\n`,
  preventing Unicode line-break prompt injection.
- **Negative `targetIndex`** actions forced to `.confirm` (was `.preview`).
- **LLM 5xx after retries** now throws explicitly rather than falling through
  to a generic `.api` error.

[Unreleased]: https://github.com/Stray-South/macos-agent/compare/v0.2.0-beta...HEAD
[0.2.0-beta]: https://github.com/Stray-South/macos-agent/compare/v0.1.0-beta...v0.2.0-beta
[0.1.0-beta]: https://github.com/Stray-South/macos-agent/releases/tag/v0.1.0-beta
