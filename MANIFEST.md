# MANIFEST — macOS Agent v0

> Retroactive product spec. Written after v0 build. Treats what exists as ground truth,
> defines what it is, what it is not, and what the path to v1 looks like.

---

## What This Is

**macOS Agent v0** is a native macOS desktop agent that sees the screen, reasons about it,
and takes actions — clicks, typing, key combos, menus, scrolling — the way a human would.

It is NOT a browser extension. NOT a web scraper. NOT a remote control tool.
It operates on whatever is frontmost on your Mac, reads it through Accessibility APIs and Vision OCR,
asks Claude what to do next, and does it — one step at a time, with human approval gates built in.

Think of it as: **a junior copilot learning to drive any macOS app. It asks before doing risky
things and writes a signed receipt for every action it takes.** (v0: the safety machinery is
proven; real-world task reliability is still rough. See §Known Gaps, "Verification posture.")

Reference analogies: Storyline 360's recording mode, Premiere's scripted marker tools,
UiPath for enterprise desktops — except local, native Swift, and built around Claude.

---

## Core Capabilities (Implemented)

| Capability | Source |
|---|---|
| AX tree perception — reads every interactive element, role, label, frame | `AXPerception.swift` |
| Vision OCR fallback — screenshots + text recognition when AX is empty | `VisionPerception.swift` |
| Unified snapshot with hash — tamper-evident perception record | `PerceptionSnapshot.swift` |
| Claude-powered action selection — structured tool call, one action per step | `LLMClient.swift` |
| Safety gating — AUTO / PREVIEW / CONFIRM tiers, destructive-keyword detection | `SafetyPolicy.swift` |
| Autonomy modes — Manual / Semi-Autonomous / Autonomous | `AutonomyMode.swift` |
| Action executor — click, doubleClick, rightClick, typeText (clipboard fast-path for long text), scroll, keyCombo, menuSelect, wait, undo, switchApp, drag, holdKey, mouse{Down,Up,Move}, say (Unit 33, non-pausing chat), readClipboard (Unit 35, preview-gated pasteboard read) | `Executor.swift` |
| Receipt chain — JSONL audit log per day, one entry per action | `ReceiptWriter.swift`, `ActionLogEntry.swift` |
| Capability rules — per-app/per-action allow/ask/deny rules; 4-button HUD gate; glob label matching; persistent JSON store | `CapabilityRule.swift`, `CapabilityRuleStore.swift` |
| Floating HUD overlay — 4-button approval card (Approve/Always/Reject/Never), phase labels (Observing…/Thinking…), highlight box | `OverlayWindowController.swift` |
| Menu bar status item — phase-colored icon, last 3 messages, Stop button | `MenuBarStatusView.swift`, `MacAgentApp.swift` |
| Task planner — pre-run Claude Haiku call to decompose task into 3-7 steps, with step-progress injection into every LLM call | `TaskPlanner.swift` |
| Throughline — persistent cross-session memory: hard rules, positions, task history | `AgentThroughline.swift` |
| Orchestrator loop — observe → think → gate → act → receipt; 50-step budget; stall detection; think() 3-retry transient-error recovery | `Orchestrator.swift` |
| Multi-app orchestration — switchApp activates or cold-launches apps by bundle ID; 10s launch timeout | `Executor.swift`, `LLMClient.swift` |
| SwiftUI launcher panel — conversation thread, autonomy picker, presets, live activity, collapsible visible-apps panel | `LauncherView.swift` |
| Welcome + Settings screens — API key, model picker, autonomy default, capability rules manager, agent memory, receipts | `WelcomeView.swift`, `SettingsView.swift` |
| Permissions management — AX dialog trigger, TCC reset detection, advisory SR banner | `Permissions.swift`, `AppModel.swift` |
| Smoke test entry point — live Claude/tool-call path without UI permissions | `MacOSAgentSmoke` target |
| Live action-model smoke harness — env-gated multi-scenario assertion against the live Anthropic API; coarse "can this model emit each primitive in isolation?" check (NOT a real-orchestrator-pressure detector) | `MacOSAgentSmokeAction` target (opt-in: `MACOS_AGENT_SMOKE_ACTION=1`) |
| Receipt replay CLI — read-only forensic surface for dogfood. Newest-first listing with `--date` / `--errors` / `--show-text` / `--limit` flags. `action.text` redacted to `***` for `.typeText` actions by default; opt-in `--show-text` to print verbatim. Closes Path D Candidate 3 Phase 1 | `MacAgentReplay` target + `ReceiptReplayFormatter.swift` + `ReceiptReader.swift` |
| Real-app perception harness (H2) — env-gated CLI that activates each target app and walks its LIVE Accessibility tree, reporting per-app fidelity (element count, role distribution, AX-rich vs AX-blind/vision-dependent, truncation, focus). Turns "perception works" into per-app evidence. Opt-in: `MACOS_AGENT_PERCEPTION_HARNESS=1`; needs Accessibility granted to the running binary | `MacOSAgentPerceptionHarness` target + `PerceptionFidelity.swift` |

---

## What It Is Not (v0 Scope Limits)

- **No general file system access.** Agent cannot read or write arbitrary files. EXCEPTIONS: its own receipts/throughline/snapshots, clipboard READ (Unit 35), and — only when the operator enables the "Agent workspace" — confirm-tiered `writeFile` confined to a single 0700 sandbox folder (`~/Library/Application Support/MacAgent/workspace/`). Writes cannot escape that folder (no absolute paths, no `..`, no symlink traversal), cannot overwrite the user's other files, and execute nothing. Off by default.
- **Clipboard read is in scope (Unit 35), with a privacy cost.** The
  `readClipboard` action reads the pasteboard's text and sends it to the
  model API. It floors at PREVIEW approval, autonomy mode does not widen it,
  and it is floor-bound against capability-rule widening — but a reader
  auditing the data-egress surface should know the pasteboard is a reachable
  source. Clipboard WRITE remains internal-only (the typeText fast-paste
  path).
- **No browser-specific DOM access.** Safari is treated as a native AX tree like any other app.
- **No scheduled or background runs.** Agent runs only when the user triggers it.
- **No persistent identity / user accounts.** Local-only. No cloud sync, no backend.
- **No network actions.** Agent cannot make HTTP calls on your behalf.
- **No voice input.** Text task entry only.

---

## Architecture

```
MacOSAgentV0 (SwiftUI app)
    └── AppModel (@MainActor, ObservableObject)
            ├── Orchestrator (actor)
            │       ├── AXPerception (actor)          ← reads AX tree
            │       ├── VisionPerception              ← OCR fallback
            │       ├── ClaudeLLMClient               ← think() → AgentAction
            │       ├── SafetyPolicy                  ← classify() → SafetyTier
            │       ├── Executor                      ← act() → CGEvent / AXUIElement
            │       ├── OverlayWindowController       ← HUD gate UI
            │       ├── ReceiptWriter                 ← JSONL audit log
            │       ├── ThroughlineStore              ← persistent memory (actor)
            │       └── ClaudeTaskPlanner             ← pre-run plan (Haiku)
            └── LauncherView (SwiftUI)

MacAgentCore (library target — reusable logic, no AppKit app lifecycle)
MacOSAgentSmoke (CLI smoke test — validates live API path)
MacOSAgentSmokeAction (env-gated live regression harness — multi-scenario action-model assertions)
```

### Loop invariant

```
while running:
  snapshot  ← AXPerception.capture()     // AX tree + optional Vision OCR
  action    ← LLMClient.nextAction()     // Claude tool call → AgentAction
  tier      ← SafetyPolicy.classify()   // AUTO | PREVIEW | CONFIRM
  tier       = AutonomyMode.adjust()    // mode may tighten or loosen tier
  verdict   ← CapabilityRuleStore.evaluate()  // deny | ask | allow | nil (Option C)
              // deny → immediate rejection receipt + .failed, no gate
              // allow → widen tier (safety floor: never widen destructive/sensitive)
              // ask → floor tier at PREVIEW
  decision  ← gate(tier)               // HUD 4-button (Approve/Always/Reject/Never) or auto-pass
              // Always/Never → persist CapabilityRule for future runs
  result    ← Executor.perform()        // CGEvent or AXUIElementPerformAction
  receipt   ← ReceiptWriter.write()     // JSONL entry
  if action.type == .complete: break
```

---

## Snapshot / Receipt Model

- **PerceptionSnapshot** — hash of (timestamp + bundleID + elements + visionObservations). Tamper-evident.
  Stored as `snapshotHash` in every receipt entry.
- **ActionLogEntry** — per-action receipt. Fields: id (UUID), timestamp, action (full struct), tier,
  approved (bool), executionResult (string), durationMs, snapshotHash, and (H1) `outcomeVerified`
  (Bool?, tri-state: true verified / false post-condition-not-met / nil not-checked) +
  `outcomeDetail` (String?) — the closed-loop check of whether the action achieved its intended
  post-condition. Both optional/nil-default; append-only (old receipts decode unchanged).
- **Storage** — `~/Library/Application Support/MacAgent/receipts/YYYY-MM-DD.jsonl`
  One file per day. Never deleted by the agent. Writes are serialized through the `ReceiptWriter`
  actor — append safety is enforced at the application layer, not via OS-level `O_APPEND`.
  Concurrent processes writing to the same file would interleave entries; this is acceptable
  because the agent is single-process by design.
- **File mode** — JSONL files are mode `0600` (owner-rw, no group/other), parent
  directory is `0700`. Re-applied on every write because atomic-rename swaps the
  inode each call. chmod failures are best-effort (do not block the entry from
  being persisted) — the cleartext payload still lives inside the user's home
  directory either way.
- **Cleartext by design** — The full `AgentAction` struct is stored verbatim, including the `text`
  field for `typeText` actions. This means confirmed keystrokes (including content typed into
  password or 2FA fields after user approval) are logged in plaintext locally. This is intentional:
  the receipt is an audit trail of what the agent actually did, and masking would defeat that
  purpose. Scope: local disk only, no cloud sync or network transmission. Users with strict data
  hygiene requirements should exclude `~/Library/Application Support/MacAgent/` from Time Machine.

---

## Safety Model

Three tiers:

| Tier | Meaning | Gate behavior |
|---|---|---|
| AUTO | Safe, high-confidence action | Executes without interruption |
| PREVIEW | Visible or reversible change | HUD shows action, user can approve or reject |
| CONFIRM | Destructive, risky, or low-confidence | HUD blocks until explicit user approval (unanswered gates park and heartbeat — see Parked approvals below) |

**Destructive keywords** that always force CONFIRM (substring match):
`clear, delete, destroy, disable, discard, empty, erase, format, overwrite, purge, remove,
reset, revoke, sign out, terminate, trash, uninstall, wipe`

**Destructive keywords** that always force CONFIRM (whole-word match only — substring would fire on "Resend", "Unsend"):
`send`

**Dangerous key combos** (always CONFIRM):
`cmd+delete, cmd+shift+delete, cmd+shift+option+delete, ctrl+delete`

**Risky combos** (always PREVIEW):
`cmd+q, cmd+w, cmd+option+w, cmd+option+escape`

**Unknown-combo floor (Unit 38):** any keyCombo NOT on the benign allowlist
floors to PREVIEW. Benign (stays AUTO): bare navigation/whitespace
(`return enter tab escape space up down left right home end pageup pagedown
delete backspace shift+tab`) and ubiquitous reversible editing
(`cmd+c cmd+v cmd+x cmd+a cmd+z cmd+shift+z cmd+f cmd+g cmd+shift+g cmd+l`).
Everything else — `cmd+ctrl+q` (lock), `cmd+shift+3/4` (screenshot),
`cmd+ctrl+space` (emoji), fn-layer + app-specific chords — previews so the
operator sees the unrecognized chord before it fires. A multi-press
sequence is benign only if every press is.

**Confidence calibration** (LLM instruction):
- `0.90–1.00` exact label match
- `0.75–0.89` clear role/position match
- `0.60–0.74` indirect match
- `<0.60` always CONFIRM; prefer `clarify` action type instead

**Autonomy modes and tier adjustment:**
- `confirmEveryAction` — all actions except complete/clarify/wait become at least PREVIEW
- `semiAutonomous` — tier passes through as-is from SafetyPolicy
- `autonomous` — PREVIEW becomes AUTO except:
  - `menuSelect` (always preview so the user sees the chosen menu path)
  - coordinate-only `click`/`doubleClick`/`tripleClick`/`rightClick`/`typeText`
    (no resolved AX target — label-based destructive/sensitive/commercial checks
    cannot run, so SafetyPolicy floors them at .preview and autonomous mode
    holds that floor)
  CONFIRM tier is never demoted by any autonomy mode (AGENTS.md invariant).
  No confidence gate (removed in commit `4d87949` — sub-0.85 CU pixel clicks
  were stalling autonomous runs indefinitely waiting for overlay approval)

**Parked approvals (Units 29/29a/29b/29c/29d, stall recovery 30/30a, clarify parity 32):**
Clarify questions share the same contract since Unit 32: a parked question
heartbeats (`.clarificationPending`) at the same cadence, is bounded by the
same wall-clock wait limit, and on expiry stops the task safely — it never
auto-answers with an assumption. Clarify decisions are questions, not
actions, so they write no receipts (unchanged) and are deliberately NOT
crash-journaled — there is no pending action to reconcile at next launch.

An unanswered gate never auto-rejects after a fixed interval (that killed runs
for hands-free operators whose approval latency is minutes, not seconds) and
NEVER auto-approves. It parks, emitting `.approvalPending` heartbeats (beep +
status line) each `gateTimeoutDuration` (default 60s). The gate resolves only
on an explicit decision: HUD, launcher, or the F13/F14/F15 hotkeys; Abort is
always the escape. Three guards bound the parked state:

- **Park ceiling** — after `gateMaxParkMinutes` (Settings; default 60, 0 =
  unbounded) the gate self-REJECTS with a distinct "approval window expired"
  receipt and message. Expiry only ever rejects; the .confirm-never-auto
  invariant holds in both directions.
- **Stale-approval supersede** — an approval arriving after ≥1 heartbeat
  re-observes first and acts only if the screen is structurally identical
  (focused app, elements, vision observations, capture origin). Otherwise the
  approval is receipted as superseded (`⏭` in replay) and the LLM re-proposes
  against fresh perception.
- **Pending-gate journal** — a park that outlives one heartbeat is journaled
  (`pending-gate.json`) and the entry is cleared only after a receipt for
  that gated step is durably written; a quit/crash mid-park is reconciled at
  next launch into a rejection-shaped "unresolved at shutdown" receipt. Net
  guarantee, in executing modes: no gate parked past one heartbeat ends
  invisible — it leaves a receipt, a reconciliation entry, or (in the rare
  clear-after-receipt crash window) both. Watch mode (read-only) clears the
  journal on approval without an execution receipt — nothing executed, and
  watch-mode decisions are deliberately not receipted. Gates answered within the first heartbeat interval are never
  journaled; their crash exposure matches the pre-Unit-29 baseline.

  The park ceiling is measured in wall-clock time (survives machine sleep —
  an overnight lid-closed park expires on the first post-wake heartbeat) and
  is read live from Settings at each heartbeat, so tightening it applies to
  a gate that is already parked.

**Voice Control setup note.** The hotkeys are F13/F14/F15. Voice Control
can press them by name ("Press F13") on keyboards that have them; on
keyboards without F13–F15, create custom Voice Control commands that send
those keys (System Settings → Accessibility → Voice Control → Commands).
This setup step is the operator's one-time prerequisite for the hands-free
approve/reject/abort path and needs one live verification pass per machine.

**Accepted residual risk — synthetic approval keystrokes.** The F13 approve
hotkey is an NSEvent global monitor; macOS delivers it for synthetic CGEvents
posted by ANY process holding Accessibility. This cannot be filtered without
breaking Voice Control — VC's "Press F13" is itself a synthetic event, and it
is the exact input path this feature exists for. A rogue AX-granted process
could therefore approve a parked gate; it could equally drive the entire
machine directly, so the agent adds no new capability to such an attacker —
the marginal exposure is attribution (an action fires with "operator
approved" on the receipt). Mitigations: the park ceiling bounds the window,
the supersede guard requires the propose-time screen to still be live, and
receipts record the decision trail. Operators who set the ceiling to "Never"
accept the unbounded window explicitly.

**Sensitive target labels** that force CONFIRM on typeText (substring match):
`password, one-time code, verification code, 6-digit code, two-factor, authenticator, auth code, security code, card number, expiry, credit card`

**Sensitive target labels** that force CONFIRM on typeText (whole-word match only):
`2fa, cvv, cvc, otp`

**Commercial action keywords** that force CONFIRM on click/doubleClick:
`place order, buy now, confirm purchase, complete transaction, checkout, pay now, submit order`

**Shell bundle IDs** where typeText and keyCombo always force CONFIRM:
`com.apple.Terminal, com.googlecode.iterm2, net.kovidgoyal.kitty, com.mitchellh.ghostty, io.alacritty.Alacritty`
(VSCode excluded — its bundle ID cannot distinguish editor pane from integrated terminal; `isDangerousText()` still catches destructive command content.)

**Dangerous typeText patterns** that force CONFIRM (shell content inspection):
`rm -r, rm -f, sudo , shutdown, reboot, halt, poweroff, mkfs, dd if=, (){ :|, > /dev/, curl , wget , bash -c, python -c, python3 -c, perl -e`

**Loop-abuse / stall detection.** 8 detectors. The 7 H-series detectors
self-recover: a detector's first `stallRecoveryBudget` (2) firings inject a
recovery hint and emit a `.warning` ("<detector> self-recovering"); if the
stall persists past that budget the run ends with an honest terminal `.failed`.
A run-global recovery cap (H4, `maxTotalRecoveries`, default 5) bounds the
TOTAL self-recoveries across ALL detectors in one run: once it is reached the
next stall is terminal regardless of any detector's remaining per-detector
budget, so a run flailing across multiple detectors fails fast instead of
grinding to the step limit.
`.clarificationRequested` is NOT a stall signal: it is emitted only for a
genuine `.clarify` action. The clarify-DoS guard is terminal (no self-recovery
budget) and emits `.failed` directly. Thresholds:
- ≥ 10 consecutive `.wait` actions → wait stall
- ≥ 10 consecutive `.scroll` actions → scroll stall
- ≥ 10 consecutive `.click`/`.rightClick`/`.doubleClick`/`.tripleClick` proposals on the same `targetIndex` → same-target click stall (detected pre-gate)
- ≥ 4 consecutive identical risky `.keyCombo` actions → risky-keyCombo stall
- ≥ 2 consecutive `.switchApp` to the same target → switch-app loop stall
- ≥ 12 actions with no perceptible progress → no-progress-window stall
- ≥ 3 consecutive stale-approval supersedes → supersede-churn stall
- ≥ 3 consecutive `.clarify` actions (each followed by user reply) with no real action between → clarify-DoS guard → `.failed`

**Step budget:**
- Default: 50 steps. Warning emitted at 90% (step 45). Exceeded: `.stepLimitReached` event emitted (distinct from `.failed`).

---

## Throughline / Persistent Memory

Stored at `~/Library/Application Support/MacAgent/throughline.json` (canonical
location since 2026-05-23). Pre-2026-05-23 builds wrote to
`~/MacAgent/throughline.json`; `ThroughlineStore.init` performs a one-shot
move on first launch under the new build (`moveItem` + parent-dir cleanup;
all `try?` — on failure the legacy file is left in place and `load()`
reads it as a fallback, retried next launch).

Three fields:
1. `hardBoundaries` — operator rules that survive sessions ("never delete without asking"). FIFO cap at 50 entries (each renders into every system prompt; unbounded growth is also the only adversarial-write surface)
2. `positions` — learned key/value facts ("preferred_browser: Safari")
3. `taskHistory` — ring buffer, last 20 task records (task text, outcome, stepCount, bundleID, timestamp)

Injected into every LLM system prompt as a `[PERSISTENT CONTEXT]` block.
Hard boundaries appear first; model cannot override them.

**File mode** — JSONL receipts established `0600` file + `0700` parent dir
in Cluster A (2026-05-22). Throughline + capability-rules follow the same
invariant since 2026-05-23: `0600` on file, `0700` on parent, re-applied
on every atomic write because the rename swaps the inode each call. chmod
failures are best-effort and do not block the write. All three files live
under one `0700` umbrella at `~/Library/Application Support/MacAgent/`.

---

## API Key Handling

Priority order (post-Cluster-A — Keychain-only with legacy migration):
1. `ANTHROPIC_API_KEY` environment variable (read at `AppModel.resolvedAPIKey()`
   via the `defaultAPIKeyProvider` closure on every `configureIfPossible()`
   call — shell / Xcode scheme / `launchctl setenv` before process launch.
   Empty string is treated as absent so a shell profile that exports
   `ANTHROPIC_API_KEY=""` doesn't shadow the Keychain entry.)
2. macOS Keychain — generic password, service `com.southernreach.macos-agent-v0`,
   account `anthropic-api-key`. The canonical store. Settings UI reads/writes here.
3. **One-shot migration** from `~/.config/macos-agent/api_key`. On first launch
   with a key present at this legacy path, the file content is moved into the
   Keychain and the file is securely deleted (zero-overwrite + `removeItem`).
   After migration the file no longer exists; the Keychain is consulted directly.
4. **Read-only borrow** from `~/.anthropic/api_key` (the Anthropic CLI's slot).
   Returned for the current session if present and Keychain is otherwise empty.
   Never written to our Keychain (a different tool's secret is not ours to
   promote) and never deleted (it's the CLI's file).

`.app` bundles don't inherit shell env — first-launch operators must paste the
key into Settings; it lands in the Keychain. There is no longer a writable
plaintext file fallback.

---

## Model Selection

Default action model: `claude-sonnet-4-6` (configurable in Settings)
Action-LLM whitelist (`AgentModel.all`): `claude-opus-4-6`, `claude-sonnet-4-6`.
Haiku 4.5 was on this whitelist through 2026-05-22 and was removed
2026-05-23 after a live hands-off audit found multi-tool selection
failing under accumulated orchestrator pressure: across all 6 Lane 1
tasks Haiku emitted only `click` / `wait` / `keyCombo cmd+tab` /
`keyCombo cmd+space` — never `switchApp`, `typeText`, `menuSelect`,
`scroll`, or `undo`. A 2026-05-25 follow-up experiment confirmed Haiku
CAN emit those primitives in isolation (single-shot smoke 5/5 pass),
so the production failure is compound — real AX trees, accumulated
history, NSWorkspace running-apps, and real AX execution errors all
contribute; a synthetic unit-test harness can't reproduce it. Haiku
stays off the action whitelist on the strength of the live audit
evidence; the `MacOSAgentSmokeAction` smoke is a coarse "is this
model totally broken?" check, not a sufficient gate. Operators with
persisted `selectedModel = claude-haiku-*`
auto-migrate to Sonnet 4.6 on next launch via `UserDefaults.selectedModel`
getter; the migration is logged via `settingsLog.info` per AGENTS.md
§LLM Client "never swap silently" — observable in Console.app under
subsystem `com.southernreach.macos-agent-v0`, category `SettingsView`.

Planning model: `claude-haiku-4-5-20251001` (hardcoded — Haiku is intentionally used for speed/cost; the planner uses a single-tool schema where Haiku performs correctly)
Default Computer Use model: `claude-sonnet-4-6` (configurable in Settings).
Anthropic ships two CU beta protocols; `ComputerUseClient.cuToolVersion`
dispatches per model:

- **New beta** (`computer-use-2025-11-24` + `computer_20251124`):
  Opus 4.7 (1:1 coords), Opus 4.6, Sonnet 4.6 (both scaled).
- **Old beta** (`computer-use-2025-01-24` + `computer_20250124`):
  Sonnet 4.5, Haiku 4.5, Opus 4.1, Sonnet 4, Opus 4 — all scaled.
  Haiku 4.5 is ~5× cheaper per step but lacks the `zoom` action.

Planning is a single non-streaming call with max_tokens=256 before the loop starts.
If planning fails (key missing, network error), run continues without a plan.

Computer Use mode is a separate setting from the action model because the two
must be picked independently: the action LLM uses a custom tool schema and any
whitelisted model works, while Computer Use uses Anthropic's native tool schema
which requires a specific model + beta header combination. Coupling them would
either force the user out of their preferred action model or silently swap the
CU model — both rejected per AGENTS.md "Never swap silently".

### Coordinate scaling

Per Anthropic's `computer-use-2025-11-24` docs, only `claude-opus-4-7`
supports up to a 2576-px long-edge image and returns click coordinates 1:1
with image pixels. Every other supported model (Opus 4.6, Sonnet 4.6,
Opus 4.5) operates in a 1568-px / 1.15-MP server-side downsampled space
and returns coords in that scaled space.

`ComputerUseClient` honors this:
- Opus 4.7: capture at native logical resolution, send 1:1, no descale.
- Opus 4.6 / Sonnet 4.6 / others: capture at logical resolution,
  downsample via `ScreenScaler.scaleDownIfNeeded` to 1568-px long edge,
  send the scaled image, and inverse-rescale every returned click /
  scroll coordinate back to logical screen points before AX matching
  and CGEvent posting.

The math is in `ScreenScaler.swift` (pure functions, fully unit-tested
without a display). `lastSentImageSize` and `lastLogicalSize` on the
actor are set per request so the descale path always uses the size pair
that matched the most recent screenshot.

---

## Permissions Required

| Permission | Why |
|---|---|
| Accessibility | AX tree traversal — reads all UI elements of frontmost app |
| Screen Recording | Vision OCR fallback — captures screen when AX tree is empty |

Both must be granted in System Settings → Privacy & Security before the orchestrator starts.
The app requests them on launch and polls status on each run attempt.

---

## Build & Run

```bash
# Build
swift build

# Run tests
swift test

# Smoke test (validates Claude API path, no UI permissions needed)
swift run MacOSAgentSmoke

# Build .app bundle
./scripts/build-app.sh

# Run .app bundle (picks up Info.plist for permission descriptions)
./scripts/run-app.sh

# Full pipeline
./scripts/smoke-check.sh
```

App bundle output: `./dist/MacOSAgentV0.app`
Receipt log: `~/Library/Application Support/MacAgent/receipts/YYYY-MM-DD.jsonl`
Throughline: `~/Library/Application Support/MacAgent/throughline.json`

---

## Known Gaps / v1 Queue

> Phase map, DoD, and per-gap status live in **PHASES.md**. Update both when a gap is resolved.
> These are not bugs — they are deferred scope. Do not implement without a spec update.

| Gap | Description | Priority |
|---|---|---|
| ~~Demo-mode gating~~ | ✅ Resolved (Phase 8) — `DemoPreset` now carries `bundleID` directly; hardcoded `bundleMap` deleted; `validateSupportedApp` simplified to `String?`; dead "supports Notes, Finder, and Safari" block removed. Any preset targeting any app now works without code changes. | — |
| ~~DesktopAgentKit target~~ | ✅ Resolved — `Sources/DesktopAgentKit` deleted; directory was empty and unreferenced | — |
| ~~Subtask / multi-step plan tracking~~ | ✅ Resolved (Phase 11) — `think()` injects `[PLAN PROGRESS: step N of M — "label"]` into every LLM call. `currentPlanStep` advances mechanically after each meaningful action (click/typeText/keyCombo/menuSelect). `.planProgress` event emitted on each advance. | — |
| ~~Throughline write-back for new boundaries~~ | ✅ Resolved (Phase 5A) — Settings → Agent Memory section allows viewing and editing hard boundaries; `ThroughlineStore` persists writes via actor-serialized JSON. | — |
| ~~Screenshot-only mode~~ | ✅ Resolved (Phase 2) — vision observations injected into LLM prompt; vision indices resolve to screen coordinates via `ResolvedTarget`; `visionIndexOffset` is single source of truth | — |
| ~~Composer focus not restored~~ | ✅ Resolved (Phase 3) — `LauncherView.swift` restores `composerFocused` after every run, abort, and clarification reply | — |
| ~~Duplicate error display~~ | ✅ Resolved (Phase 3) — `lastError` banner removed; errors surface inline in the conversation panel | — |
| ~~Abort did not cancel in-flight calls~~ | ✅ Resolved (Phase 3) — `currentRunTask?.cancel()` + `Task.checkCancellation()` in `observe()` and `think()` | — |
| `clarify` action in conversational flow | Implemented. Phase 3 improved the UX: clarification appears as a named question with reply instructions. Unit 32 replaced the old 5-min auto-resume with gate-parity parking: heartbeats + wall-clock wait-limit expiry; the run never proceeds on an invented answer. | — |
| Test coverage | 662 tests across 10 suites (unit + integration; LLM, perception, and executor are mocked — see the honest scope note below). Covers loop mechanics, stall detection + self-recovery, capability rules, safety-tier classification, gate park/heartbeat/ceiling, clarify parity, the `say`/`readClipboard`/`writeFile` capabilities, the operator-drift guard, vision-path geometry, closed-loop outcome verification (H1), real-app perception fidelity analysis (H2), supply-chain integrity, and the red-team injection matrix. **Per-unit detail: `CHANGELOG.md`. Phase ledger + DoD: `PHASES.md`.** | Low |
| taskGuard default | `Orchestrator.init` defaults `taskGuard:` to `PermissiveTaskGuard` for test ergonomics; production override to `KeywordTaskGuard` happens in `AppModel.makeOrchestrator` per the in-line comment at Orchestrator.swift:115-117. `AppModelTaskGuardTests` locks the production guarantee. Pre-existing pattern; removing the default would require explicit `taskGuard:` arg at 78 test sites for marginal benefit — accepted as documented divergence. | Accepted |
| ~~Task-level harm classifier (F.6)~~ | ✅ Resolved (RED-6 + Unit 15) — `KeywordTaskGuard` fires before `emit(.started)` with zero LLM calls (15 banned phrases). Unit 15 closes the v1 stretch: `LLMTaskClassifier` wraps `KeywordTaskGuard` and adds a single Haiku call for tasks the keyword pass clears, returning SAFE/HARMFUL with reasoning. Opt-in via `UserDefaults.agentSuite.useLLMTaskClassifier` (default off → no latency regression). In-session SHA256 cache (32-entry FIFO, memory-only — no fourth state file). Network failures degrade gracefully (LLM-blocked tasks fall back to the base guard's verdict). | — |
| Signed .app distribution | Developer ID signed + notarized DMG available via `scripts/package-dmg.sh`. App Store not targeted. | — |
| ~~Disabled-element recovery prompt~~ | ✅ Resolved (Unit 18B) — new `ExecutorError.targetDisabled(actionType, requestedIndex: Int?, label: String?)` thrown by both `resolveTarget` AX-disabled path and `performMenuSelect` disabled-item path. Orchestrator recovery branch emits a specific prompt: "element is in the snapshot YET DISABLED, re-observing alone won't help, pick a different element OR satisfy the enabling condition first." Distinct from `.targetStale` (element gone vs. element alive-but-disabled) so the recovery strategy differs accordingly. | — |
| ~~Stall paths don't write rejection receipts for the offending action~~ | ✅ Resolved (Unit 18A, extended through Unit 30) — the `Orchestrator.recordStall()` chokepoint is wired at every stall detector: `wait`, `clarifyDoS`, `sameTargetClick`, `scroll`, `sameRiskyKeyCombo`, `noProgressWindow`, `sameSwitchAppLoop`, `supersedeChurn` (8 sites; the authoritative list is the `detector:` call-sites in `Orchestrator.swift`). Each fires `ActionLogEntry(approved: false, tier: "confirm", executionResult: "stalled-<detector>")`. `MacAgentReplay --errors` surfaces every stall. Post-execute stalls (`wait`, `scroll`) produce two distinct receipts — the success for the action that ran + the rejection for the stall — capturing both facts in the audit trail. | — |
| Verification posture (honest, Phase G) | The automated tests mock the LLM, perception, AND the executor — they prove decision LOGIC and SAFETY POLICY, not that the agent drives a real machine correctly. The "smoke" checks grade the model's PROPOSED action; they do not click or type. **Real-world behavioral confidence is unproven until** the live-verification protocol (`docs/live-verification-protocol.md`) is run on a real machine + dogfood burn-in is summarized via `MacAgentReplay --report`. Roadmap: `docs/phase-g-real-world-confidence.md`. **H1 (closed-loop outcome verification) now tags each executed action as verified / unverified / not-checked, so `MacAgentReplay --report` shows real verified-success, not just "did not throw"** — the measurement instrument exists; the live burn-in that uses it is still owed. **H2 (the real-app perception harness, `MacOSAgentPerceptionHarness`) measures the perception layer's real-app fidelity per app the same evidence-first way** (operator-run; needs Accessibility). Self-assessed confidence: logic ~8/10, real-world behavior ~2/10 pending the protocol. | Open — needs live run |

---

## Deferred / V1+ Backlog

Items deliberately deferred from the comprehensive audit (commits since
`fec44fe`). Each entry includes the architecture sketch and the deferral
trigger — the condition that would warrant pulling it forward.

### ~~CU stateful mouse actions~~ ✅ SHIPPED (Unit 13b)

No longer deferred — this is the Sev-1 spec-drift the Phase G6 truth pass
caught (the entry contradicted the Core Capabilities table in this same
file). `left_mouse_down`/`left_mouse_up`/`mouse_move` translate to real
`.mouseDown`/`.mouseUp`/`.mouseMove` ActionTypes (`ComputerUseClient`), the
`Executor` performs them with live CGEvents, `MouseHoldState` is the actor
singleton with a 30s watchdog + `releaseHeldInputs()` terminal-cleanup
chokepoint, and `SafetyPolicy.heldMouseAdjusted` promotes cross-cutting
actions to `.confirm` during a held button. See CHANGELOG (Unit 13b) and the
`StatefulMouseTests` suite. The "one turn = one CGEvent burst" concern was
resolved by the watchdog + idempotent release, not by deferring.

### Live CU smoke harness (Design A from the audit)

**Status**: deferred. Existing `Sources/MacOSAgentSmoke/main.swift`
validates `ClaudeLLMClient` against the live Anthropic API but does NOT
exercise `ComputerUseClient` (needs display + screen-recording TCC grant
which `swift run` from CLI lacks).

**Architecture** (~80 LOC if pulled forward):
- New `Sources/MacOSAgentSmokeCU/main.swift` target.
- Use the existing `seedScale(...)` testing seam on `ComputerUseClient`
  (`ComputerUseClient.swift:55-58`) to bypass ScreenCaptureKit; feed a
  fixture PNG of a known UI layout.
- Make one live API call via `nextAction`; assert the returned
  AgentAction has sensible coordinates within logical screen bounds and
  the expected ActionType for the fixture's intent.
- Gate behind `MACOS_AGENT_SMOKE_CU=1` env var; opt-in only, never on
  default CI (Actions minutes + live API cost).

**Why deferred**: the only regression class only a live smoke catches is
Anthropic deprecating the beta header or tool type — and that's also
caught the moment any user runs the live app. Existing unit-test coverage
(`ScreenScalerTests`, `ComputerUseTranslateTests`,
`ComputerUseCoordRoundTripTests`) covers translator + descale + safety.
Anthropic's own quickstart `computer-use-demo/tests/loop_test.py` uses
only mocks — same approach we already have.

**Deferral trigger** — pull forward when ANY of:
1. Anthropic deprecates either CU beta header (`computer-use-2025-11-24`
   or `computer-use-2025-01-24`) without warning.
2. A user reports a CU regression no existing unit test caught.
3. Any model in `knownComputerUseModels` (SupplyChainTests.swift:38+)
   gets a retirement date on Anthropic's deprecation list. Current
   active models retire ≥2026-08-05 (Opus 4.1), ≥2026-09-29 (Sonnet 4.5),
   ≥2026-10-15 (Haiku 4.5), ≥2027-02-05 (Opus 4.6), ≥2027-02-17
   (Sonnet 4.6), ≥2027-04-16 (Opus 4.7). Drop earlier-retiring entries
   from the whitelist before retirement — see commit `ceb3698` for the
   2026-06-15 sonnet-4 / opus-4 precedent.

   > **Maintenance:** the dates above are a snapshot as of 2026-05-12
   > and go stale silently. Re-verify against Anthropic's deprecation
   > page (https://docs.anthropic.com/en/docs/about-claude/model-deprecations)
   > before every whitelist contraction. The trigger itself (any model
   > getting a retirement date) is the canonical prompt; the enumerated
   > dates are a convenience, not a source of truth.

---

## Vocabulary

| Term | Meaning |
|---|---|
| Snapshot | AX tree + Vision observations at a moment in time, with a hash |
| Receipt | JSONL record of one executed action (approved or rejected) |
| Throughline | Persistent cross-session memory |
| Tier | Safety classification: AUTO / PREVIEW / CONFIRM |
| Autonomy mode | User-controlled setting that adjusts tier thresholds |
| Gate | The HUD overlay approval step for non-AUTO actions |
| Planner | Pre-loop Haiku call that decomposes task into ordered steps |
| Smoke test | CLI target that exercises live Claude API path without UI permissions |
