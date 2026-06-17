# AGENTS.md — Engineering Rules & Execution Rubric
# macOS Agent v0

> Rules for anyone (human or AI agent) working in this repo.
> Read this before touching any file. MANIFEST.md is the product spec. This file is the execution contract.

---

## Stack

- Swift 6.2, strict concurrency (`-strict-concurrency=complete` on all targets)
- SwiftUI + AppKit, macOS 14+
- No external Swift Package dependencies (zero `dependencies: []` in Package.swift — keep it that way)
- Anthropic API via raw URLSession (no SDK)
- Accessibility framework (AXUIElement) + Vision framework (OCR)
- JSONL receipts, JSON throughline — no database

---

## Preconditions Before Any Work

1. Verify you're on the right branch with a clean working tree.
2. Required env: `ANTHROPIC_API_KEY` set, or a Keychain entry under service `com.southernreach.macos-agent-v0` (see MANIFEST §API Key Handling). Note: `~/.config/macos-agent/api_key` is no longer a fallback — it is a one-shot migration source consumed and securely deleted on first `readKey()` call.
3. `swift build` must pass before you start. If it doesn't, fix that first — don't pile on.
4. `swift test` must pass before you start. If tests fail, report and stop.
5. Read MANIFEST.md §relevant section before modifying any component.

---

## Non-Negotiable Architectural Rules

### Concurrency
- `Orchestrator` is an `actor`. Never call actor-isolated methods from non-async contexts.
- `AppModel` is `@MainActor`. All UI state mutations happen there.
- `AXPerception` is an `actor`. Never cache stale observations outside its cache window (200ms).
- No `Task { @MainActor in }` inside `MacAgentCore` — that layer has no knowledge of AppKit main thread.
- No `@unchecked Sendable` unless you document why the invariant is safe.

### Safety
- `SafetyPolicy.classify()` must run on every proposed action before execution. Never bypass it.
- An unanswered `Orchestrator.gate()` parks and heartbeats (`.approvalPending` each `gateTimeoutDuration`, default 60s) and self-rejects at the wall-clock park ceiling (`gateMaxParkMinutes`, default 60 min). It never auto-approves, and only an explicit decision, abort, or ceiling expiry resolves it (MANIFEST §Parked approvals). Do not reintroduce an interval auto-reject and do not remove the ceiling default.
- Adding new destructive keywords to `SafetyPolicy.isDestructive()` is always safe. Removing any is a CONFIRM-class decision.
- Never auto-approve a `.confirm` tier action regardless of autonomy mode.

### Receipt Chain
- Every action execution (approved or rejected) writes a receipt. No exceptions.
- `ActionLogEntry` schema is append-only. Never remove fields. Adding fields is fine with a default.
- Receipt files are never deleted by agent code.

### Agent State Files (file-mode parity)
- Receipts (`receipts/YYYY-MM-DD.jsonl`), throughline (`throughline.json`),
  capability-rules (`capability-rules.json`), and the pending-gate journal
  (`pending-gate.json`, Unit 29c — parked-approval crash-safety) are all
  `0600` files inside a
  `0700` parent (`~/Library/Application Support/MacAgent/`). Re-applied on
  every atomic write because the rename swaps the inode. chmod failures are
  best-effort (do not block the entry from being persisted) — the cleartext
  payload still lives inside the user's home directory either way.
- Single source of truth: `ReceiptWriter.write()`, `ThroughlineStore.save()`,
  `CapabilityRuleStore.persist()`, `PendingGateJournal.record()`. Each is
  responsible for re-applying perms after its own atomic-rename cycle. Adding
  another state file requires the same chmod path or it ships as a privacy
  regression.
- All state files live under one `0700` umbrella in Application Support.
  Pre-2026-05-23 builds wrote `~/MacAgent/throughline.json`; the current
  build migrates that file via `ThroughlineStore.migrateLegacyHomeDirThroughline`.
  The migration helper rejects symlink legacy files — moving a symlink would
  let an attacker with write access to `~/MacAgent/` redirect both the
  agent's read AND the post-move `chmod 0600` to an unrelated file.
- **Accepted chmod-window gap.** Foundation's `Data.write(.atomic)` and
  `FileManager.replaceItemAt` both write to a tmp path and rename. Between
  the rename and the trailing `setAttributes`, the file is at the umask-
  default mode (typically `0644`). The window is sub-millisecond and the
  attacker would need a concurrent `open(2)` racing the agent on the exact
  filename — practically unexploitable in this single-process local agent.
  Documented as accepted gap; the alternative (`O_CREAT | O_EXCL` + `fchmod`
  before write) would require dropping the atomic-rename guarantee that
  protects against partial-write corruption, which is the worse trade.

### Perception
- AX snapshot cache window is 200ms. If you change it, document why and test stale-snapshot scenarios.
- Vision OCR is a fallback only — it fires when AX elements are empty OR `shouldForceVisualCheck` is set.
- Vision full-screen fallback emits a warning to the event stream. Keep that warning.
- Element list cap is 300 (pruned in `AXPerception.prune()`). LLM sees max 80 (filtered in `LLMClient`). Do not raise these without benchmarking token cost.

### LLM Client
- Model default is `claude-sonnet-4-6`. Planning model is `claude-haiku-4-5-20251001`. Computer Use model default is `claude-sonnet-4-6` (new beta). CU dual-beta support: new-beta models {Opus 4.7, Opus 4.6, Sonnet 4.6} use `computer-use-2025-11-24` + `computer_20251124`; old-beta models {Sonnet 4.5, Haiku 4.5, Opus 4.1, Sonnet 4, Opus 4} use `computer-use-2025-01-24` + `computer_20250124`. `ComputerUseClient.cuToolVersion` dispatches per model. Never swap these silently.
- `nextAction()` uses structured tool call with `disableParallelToolUse: true`. Keep this — parallel tool use breaks the one-action-per-step invariant.
- Conversation history is capped at 12 messages (each completed action contributes two — rationale + observation, so ~6 action-pairs). Expanding this increases token cost per step.
- Retry policy: 429/529 → 1s / 5s / 30s backoff (3 retries). 5xx → 2s (3 retries). Do not change without load testing.

### Throughline
- `ThroughlineStore` is an actor. Never write throughline from outside the actor.
- `hardBoundaries` always appear first in the `promptBlock()` output. Never reorder.
- `taskHistory` ring buffer cap is 20. Do not increase without checking JSON file size.
- `hardBoundaries` FIFO cap is 50 (each renders into every system prompt). Do not increase without auditing token cost on the longest realistic system prompt.

### No Dependencies
- Do not add Swift Package dependencies without a documented architectural decision.
- Vendoring a small helper is acceptable if it stays under 200 lines and has MIT/Apache license.

---

## Output Shape (Code Tasks)

- Ship the change. No pre-explanation. Post-summary in 1–2 sentences after.
- No bonus refactors. No "while I was here" cleanups.
- Spotted something out of scope? One line at the end. Don't act on it.
- No new `//` comments that explain what code does. Only comment the non-obvious why.
- No new documentation files, READMEs, or planning docs without explicit request.

---

## Scope Discipline

- A bug fix touches the bug and nothing else.
- A feature touches only the files the feature requires.
- Tests go in the corresponding `Tests/` subdirectory. Test names match what they verify.
- New `ActionType` cases require: schema change, executor case, LLM schema enum update, SafetyPolicy review. `scripts/check-invariants.sh` enforces the schema↔executor parity the compiler can't.

### Scripted-edit discipline (Phase G5)
Bulk/scripted multi-file edits (sed/python rewrites) have silently produced
wrong state — an edit that never hit disk (a fix left inert), a mangled line,
a commit on a detached HEAD. The compiler catches Swift errors but not "did
my intended change actually land." After ANY scripted edit:
1. `git diff` the touched files and read the hunks — confirm the change is
   present and shaped as intended (not just that the tool reported success).
2. Run `scripts/check-invariants.sh` (cross-file parity) + `swift build`.
3. For UI/prose/doc edits the build can't verify, grep for the new string.
Treat "the script printed ok" as necessary, never sufficient.

---

## PR / Commit Shape

- One concern per commit.
- Commit message format: `type(scope): short description`
  - types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`
  - scope: module name (`Orchestrator`, `Executor`, `SafetyPolicy`, etc.)
- If a task spans multiple files with different concerns, split into separate commits, not one giant one.

---

## Testing

### What Must Be Tested
- `SafetyPolicy.classify()` — all tier outcomes, including edge cases (nil index, empty label)
- `AXPerception.prune()` — truncation flag, role filtering, depth cap
- `AgentThroughline` — record(), addBoundary(), promptBlock() output format
- `ActionLogEntry` — Codable round-trip
- `PerceptionSnapshot.make()` — hash stability for identical inputs

### What Does NOT Need Tests
- SwiftUI view layout (test with eyes)
- `OverlayWindowController` (requires running NSApplication)
- Shell scripts

### Smoke Test
`swift run MacOSAgentSmoke` validates the live Claude API path end-to-end without UI permissions.
Run it after any change to `LLMClient.swift` or `Orchestrator.swift`.

---

## Rubric — Evaluating a Change

Use this to self-check before proposing or merging any change:

| Check | Pass condition |
|---|---|
| `swift build` | Zero errors, zero warnings (or pre-existing only) |
| `swift test` | All tests pass |
| Safety gate unchanged | `SafetyPolicy.classify()` still runs on every action |
| Receipt written on every action | Approved AND rejected actions have receipts |
| No new external dependencies | `Package.swift` dependencies array is still empty |
| Concurrency | No data races, no `@unchecked Sendable` without comment |
| Scope | Only the files the task required were touched |
| Throughline schema | No fields removed from `AgentThroughline` or `TaskRecord` |
| ActionLogEntry schema | No fields removed |
| Smoke test passes | `swift run MacOSAgentSmoke` exits 0 |
| AuDHD defaults | No new auto-dismissing UI, no animations >200ms, no flash effects |

---

## AuDHD-First Defaults (Non-Negotiable UI Rules)

This app is built for operators who may be neurodivergent. These are structural requirements, not preferences.

- No auto-dismiss toasts or banners. If it appears, it stays until dismissed.
  **Exception** — two named ephemeral *action-confirmation* affordances are
  allowed under a strict reduceMotion contract: (a) the `PulsingDot` shared
  component (`Sources/MacAgentCore/Overlay/PulsingDot.swift`), and (b) the
  cursor click ripple in `CursorFeedbackController`. Both MUST respect
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`: when
  reduceMotion is on, the affordance does NOT appear at all (not just
  "doesn't animate"). Informational toasts, errors, status banners
  remain persistent-until-dismissed without exception. The previous
  third confirmation affordance (`KeystrokeOverlayController`) was
  removed 2026-05-23 — the text payload of `.typeText` actions now
  renders inline in the conversation thread (`AppModel.handle(.proposed)`).
- No animations >200ms on any element.
  **Exception** — the two named confirmation affordances above are
  allowed longer durations (PulsingDot 800-900 ms, cursor ripple 450 ms
  inner + 650 ms removal) under the same reduceMotion contract.
  **One-shot exception** — `WelcomeView.glideToCorner` runs a single
  520 ms window-position animation on first launch (transition from
  centered welcome 680×420 → hub 480×640 in bottom-right corner). The
  window MUST move regardless; teleport is more jarring than a smooth
  glide for non-reduceMotion operators. Gated on reduceMotion (skipped
  to instant `setFrame` when on) AND on `UserDefaults.agentSuite
  .hasSeenWelcome` — once persisted true, never replays for this
  install. Note: `hasSeenWelcome` lives in UserDefaults (not Keychain),
  so a fresh install replays the screen even if the Keychain API key
  survived. That's acceptable for a UI-state hint. No other one-shot
  animation may use this exception — adding another requires updating
  this rule first.
  Anything else >200 ms is a violation.
- No flashing, pulsing, or attention-grabbing effects except the single
  shared `PulsingDot` component (which is opt-out safe and reduceMotion-
  gated). A SupplyChainTests grep guards that only one `PulsingDot`
  definition exists in the codebase.
- Every destructive or risky action requires a visible HUD gate — never hidden, never time-pressured with a countdown.
- Status is always visible in text form (not just color). Color can be additive, never the only signal.
- Composer focus returns after every action (user should never have to re-click the input).
- Error messages appear inline — not in sheets or popups that require dismissal.

---

## Vocabulary (Canonical)

Use these terms consistently. Do not invent synonyms.

| Term | Canonical meaning |
|---|---|
| Snapshot | AX tree + Vision observations + hash at a point in time |
| Receipt | JSONL log entry for one executed action |
| Throughline | Persistent cross-session memory (hardBoundaries + positions + taskHistory) |
| Tier | Safety classification (AUTO / PREVIEW / CONFIRM) |
| Autonomy mode | User-controlled tier adjustment (Manual / Semi / Auto) |
| Gate | HUD overlay approval step |
| Planner | Pre-loop step decomposition (Haiku call) |
| Loop | The observe → think → gate → act → receipt cycle |
| Bundle ID | `focusedAppBundleID` — the macOS bundle identifier of the frontmost app |

---

## What v0 Is Explicitly Not

Do not scope-creep these in without a MANIFEST.md update and explicit approval:

- Multi-app orchestration (cross-app task flows)
- Scheduled or background execution
- Network actions on the user's behalf
- Cloud sync or remote receipt storage
- Voice input
- File system read/write beyond receipts/throughline, clipboard read (Unit 35), and the opt-in sandboxed agent workspace (Unit 36, confirm-tiered writeFile only)
- DOM-level browser access

## Dev-Loop Friction: TCC + Ad-Hoc Signing

`scripts/build-app.sh` falls back to ad-hoc code signing when
`DEVELOPER_ID` is unset. Each build produces a new cdhash, which
**invalidates macOS TCC entries** keyed against the old hash. Symptoms:

- "Accessibility" toggle in System Settings shows ON but the agent
  silently can't read the AX tree.
- Granting permission again does not stick; the existing row's hash
  is stale, and toggling it doesn't bind to the new binary.
- The agent prompts for permission repeatedly within a single run.

**Workarounds (least to most permanent):**

1. **Minimize rebuilds during testing.** Build once, grant once,
   iterate via `swift run` / `swift test` instead of rebuilding the
   `.app` bundle. Use `./scripts/build-app.sh` only when you need to
   exercise the bundle layout (TCC entitlements, MenuBarExtra wiring,
   anything that requires the .app structure).

2. **Hard TCC reset after a rebuild that blocks you:**
   ```bash
   pkill -x MacOSAgentV0
   tccutil reset Accessibility   com.southernreach.macos-agent-v0
   tccutil reset ScreenCapture   com.southernreach.macos-agent-v0
   tccutil reset AppleEvents     com.southernreach.macos-agent-v0
   tccutil reset PostEvent       com.southernreach.macos-agent-v0
   tccutil reset ListenEvent     com.southernreach.macos-agent-v0
   open dist/MacOSAgentV0.app
   # then re-grant in System Settings → Privacy & Security
   ```

3. **Permanent fix: Apple Developer ID.** Enroll in Apple Developer
   Program ($99/yr), get a Developer ID Application certificate,
   then `DEVELOPER_ID="Developer ID Application: <Name> (<TeamID>)"
   ./scripts/build-app.sh`. Cdhash becomes stable across rebuilds;
   TCC entries persist.

**Operational guidance:**

- During active development, default to `swift test` and unit-level
  iteration. The bundle is only needed for end-to-end behavioral
  verification or manual smoke checks.
- If `Permissions.requestAccessibility()` appears to fire repeatedly,
  the grant isn't sticking — `tccutil reset` and re-grant rather
  than clicking the banner button again.
- Document this in any handoff brief that includes `./scripts/
  build-app.sh && ./scripts/run-app.sh` — the operator needs to
  know about cdhash invalidation up front.
