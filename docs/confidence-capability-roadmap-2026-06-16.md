# Confidence + Capability Roadmap (Phases H–M)

> Created 2026-06-16. Canonical plan for moving macOS Agent v0 from "safe by design,
> capability unproven" to "undeniably confident, full-autonomy desktop driving with
> delegated sub-agents and a voice/chat immersive interface."
> Continues the repo's phase-letter sequence after Phase G.
> Supersedes nothing; integrates the Phase-G confidence ladder
> (`docs/phase-g-real-world-confidence.md`) and the Tier-3 deferred backlog into one
> ordered map.

---

## Why this exists (the diagnosis)

Two confidence numbers get conflated, and the gap between them is the whole story:

| | Score | Basis |
|---|---|---|
| Safety + logic design | ~8/10 | 643 tests, multi-agent code audits, security review, live-proven gate *wiring*. |
| Real-world capability | ~3/10 | Every test mocks perception + LLM + executor. The headline claim "drives any macOS app" is unproven. |

**The keystone finding: the loop is open.** The agent executes and writes a receipt that
says `"clicked"` — nothing verifies the click *did what was intended*.
`MacAgentReplay --report`'s "executed clean" means "the executor did not throw," not
"the UI changed as intended" (`ReceiptReplayFormatter.swift:469–510`). There is no
instrument that distinguishes a *safe* agent from a *capable* one. Every downstream
problem (over-navigation, brittle long tasks, rough execution) is downstream of that
missing signal. Phase H builds the instrument; everything else keys off it.

### Code-grounded gaps (from the 2026-06-16 audit)
- **Perception:** zero real-app test coverage (`PerceptionTests.swift:292–298`); web/Electron return empty → full-screen Vision OCR noise (`Orchestrator.swift:1640`); vision is all-or-nothing, never supplements a partial AX tree; silent loss at >300 elements / depth >15 / 200ms cache race (`AXPerception.swift:247–253, 243, 173`).
- **Action fidelity:** AX-press failure falls back to frame-center CGEvent with no identity recheck (`Executor.swift:308–318, 360–378`); over-navigation documented but uninstrumented — no AX-error-loop detector, no primitive-preference prompt (`docs/handoff-2026-06-16.md:103`; `LLMClient.swift:236–363`); no test proves an action manipulates a real app.
- **Safety:** genuinely strong and partially live-proven. Do not spend confidence budget re-proving it; spend it on capability.

### Vision delta, honestly classed
- **Robust desktop driving** → closes with Phase H + I. *The real work.*
- **Delegated sub-agents** → *concurrent* multi-agent is architecturally opposed (one cursor, one `MouseHoldState` singleton, one serial receipt chain; `PHASES.md:533`, `MANIFEST.md:124`). **Sequential delegation** (parent decomposes → child owns cursor for a bounded in-app sub-task → returns verified result → parent resumes) is fully compatible. Phase J. ADR-gated.
- **Voice input** → does not exist today; F13–F15 are approval-only. ~150–200 LOC + mic TCC. Phase K.
- **Immersive interface** → chat window + HUD today; immersion is UI rework. Phase L, last.

---

## The nested verification cadence (how every phase is executed)

Work is verified at **three granularities**. None may be skipped.

1. **Per item (step):** the full working loop, repeated until the item's predetermined DoD holds.
2. **Per pair of steps:** after every two completed items in a phase, run the full working loop again as an *integration* checkpoint — prove the two items compose correctly, not just individually. Phases with an odd number of steps fold the trailing single item into the phase-level review.
3. **Per phase:** before moving to the next phase, run the full working loop once more at phase scope against the phase DoD. Only a green phase-level review unlocks the next phase.

### The working loop (identical at all three granularities)
**Research** (read live source, cite `file:line`, never memory) →
**Plan** (numbered: files touched, changes, tests, risks, edge cases) →
**Determine cascade potential** (can sub-parts fan out to parallel agents / a Workflow, or is this a serial chokepoint?) →
**Adjust plan** →
**Execute** (smallest in-scope change) →
**Adversarial review** (`Agent(code-reviewer)`; verify-before-verdict on findings *and* their false-positive verdicts — ~20% FP rate observed) →
**Repeat until the predetermined DoD holds.**

### Baseline DoD gate (every code item, on top of its item-specific DoD)
- `swift build` — zero errors, zero new warnings
- `swift test` — all pass; count synced across suite / PHASES / MANIFEST via `scripts/check-doc-test-counts.sh --count N`
- `swift run MacOSAgentSmoke` — exit 0
- `scripts/check-invariants.sh` — green (ActionType ↔ schema ↔ executor parity)
- doc-drift gate green
- adversarial-reviewed; scope matches the item; no new dependencies; `ActionLogEntry` append-only.

---

## Phase map overview

| Phase | Goal | Owner | Gate to start | Depends on |
|---|---|---|---|---|
| **H — Closed-Loop Foundation** | Turn execution from open-loop to measured. Build the instrument. | Maintainer (no machine) | now | — |
| **I — Evidence / Burn-in** | Prove real-world capability with the new metric. Rungs 2–3. | Operator runs, maintainer analyzes | H1+H2 landed | H |
| **J — Sequential Delegation** | Parent hands a scoped sub-task to a focused child; single-driver preserved. | Maintainer (ADR first) | H1 landed | H1 |
| **K — Voice Input** | Voice-driven task entry, not just F13–F15 approval. | Maintainer | H stable | H (soft) |
| **L — Immersive Interface** | Fluent non-blocking approvals + unified voice/chat surface. | Maintainer + operator review | K landed | K, I |
| **M — Tier-3 Hardening** | Drain deferred backlog where it unblocks confidence. | Maintainer | opportunistic | per-item |

**Critical path:** H1 → (H2/H3/H4 cascade) → I → J/K → L. M runs opportunistically.

---

## Phase H — Closed-Loop Foundation `[Maintainer, startable now]`

| Step | What | Cascade | Item DoD |
|---|---|---|---|
| **H1 (keystone)** | **Outcome verification.** After each action, re-perceive and check the intended post-condition (focus changed / text present / element appeared or disappeared). Add `outcomeVerified: Bool?` + `outcomeDetail` to `ActionLogEntry` (append-only). `--report` gains a *real* success rate distinct from "did not throw." Folds in Tier-3 *CU screenshot-digest comparison*. | **Serial chokepoint** — schema + verify hook; everything keys off it. | Receipt carries verified outcome; `--report` shows verified-success ≠ no-error; regression test proves a click that lands wrong is marked unverified. |
| **H2** | **Real-app perception harness.** Env-gated target (sibling to `MacOSAgentSmokeAction`) that walks Notes / Safari / Mail / System Settings live and asserts expected elements. | After H1; independent of H3/H4. the operator runs the gated target (TCC); the maintainer builds and analyzes. | Harness exists, env-gated; emits a perception-fidelity report per app; documents what each app class exposes vs misses. |
| **H3** | **AX-error-loop detector + primitive-preference prompt.** 9th stall detector on consecutive AX-error receipts; prompt nudge toward `typeText`/`keyCombo` over click-hunting. Attacks over-navigation directly. | After H1 (uses verified-outcome signal); parallel with H2. | Detector fires + recovers honestly on an AX-error loop (test); prompt change measured against a dogfood replay. |
| **H4** | **Mid-task replanning.** Plan is injected once, never updated; a UI surprise at step 2 strands the agent. Bounded replan trigger. Folds in Tier-3 *run-global recovery cap*. | After H1+H3. | Replan fires on N verified-failures or stall; capped against loops; test proves recovery vs old strand behavior. |

**Pair checkpoints:** (H1,H2) integration review; (H3,H4) integration review.
**Phase H DoD:** the agent *and* `--report` distinguish intended-success from no-error; over-navigation has a detector; long tasks can replan. The instrument that makes Phase I meaningful exists and is green at phase scope.

---

## Phase I — Evidence / Burn-in `[Operator runs, maintainer analyzes]`

| Step | What | Cascade | Item DoD |
|---|---|---|---|
| **I1** | Finish live-verification **B/C rows** (`docs/live-verification-protocol.md`): true confirm-to-execution, F13/F14/F15 from another app, ceiling expiry, operator-drift yield, writeFile sandbox, readClipboard. | Serial; needs a controlled desktop. | Every B/C row PASS/FAIL recorded in the protocol log; any FAIL triaged. |
| **I2** | **20–30 dogfood tasks** across app classes → `--report`. | the operator executes; the task corpus can be authored by parallel agents in advance. | `--report` with verified-success rates per app class; failures enumerated. |
| **I3** | **Confidence re-score** against the verified metric (not "did not throw"). | Serial after I2. | Honest number with evidence; decision: ship-ward vs more H-work. |

**Pair checkpoint:** (I1,I2) integration review. **I3** (trailing odd item) folds into the phase-level review.
**Phase I DoD:** real-world capability has a measured score backed by ≥20 logged tasks, not a vibe.

---

## Phase J — Sequential Delegation `[Maintainer, ADR-gated]`

| Step | What | Cascade | Item DoD |
|---|---|---|---|
| **J1** | **ADR**: sequential sub-agent model. Parent decomposes → child owns cursor for a bounded in-app sub-task → returns structured *verified* result → parent resumes. Single-driver-at-a-time preserved; receipt chain serial; safety floors inherited. Explicitly contrasts with rejected *concurrent* multi-agent. | Serial — settles architecture before code. | ADR approved by the operator. |
| **J2** | Child-orchestrator spawn/return mechanism (one active at a time; parent suspends). | After J1. | Parent spawns child, child runs to verified outcome, returns, parent resumes; no cursor race (test). |
| **J3** | Receipt + safety + throughline inheritance; parent visibility into child steps. | After J2. | Child actions appear in one serial receipt chain attributed to the delegation; floors enforced in child. |
| **J4** | Delegation budget + stall guards; parent reaps a looping child. | After J3. | Bounded child budget; honest terminal failure bubbles to parent. |

**Pair checkpoints:** (J1,J2) integration review; (J3,J4) integration review.
**Phase J DoD:** a parent task delegates a scoped in-app job to a child and consumes its verified result, with zero new safety holes and one coherent audit trail.

---

## Phase K — Voice Input `[Maintainer]`

| Step | What | Cascade | Item DoD |
|---|---|---|---|
| **K1** | `SFSpeechRecognizer` + mic TCC + bind transcription to `model.task`. | Independent; parallel to J after H. | Spoken task lands in composer; mic permission handled like AX/SR; off by default. |
| **K2** | Push-to-talk / command grammar; coexist with F13–F15 hands-free path without the synthetic-keystroke risk. | After K1. | Voice task entry + voice approval coexist; MANIFEST §voice updated. |

**Pair checkpoint:** (K1,K2) integration review (also the phase review — two-step phase).
**Phase K DoD:** a task can be started and approved entirely by voice; the new TCC surface is documented and floor-respecting.

---

## Phase L — Immersive Interface `[Maintainer + operator review]`

| Step | What | Item DoD |
|---|---|---|
| **L1** | Fluent **non-blocking approvals** — keep working while a gate is parked; no modal block. | Operator works in another app while a gate parks; AuDHD rules intact. |
| **L2** | Fullscreen / always-on working surface option. | Optional immersive mode; reduceMotion + persistence rules honored. |
| **L3** | Unified voice + chat surface. | One surface drives task entry, narration, and approvals via chat or voice. |

**Pair checkpoint:** (L1,L2) integration review. **L3** (trailing odd item) folds into the phase-level review.
**Phase L DoD:** the interface feels like a working partner, not a tool to babysit. Last — polish on a proven core.

---

## Phase M — Tier-3 Hardening `[Maintainer, opportunistic]`

Independent file-boundary items, each with its own full loop + DoD; none gate the critical path. Slotted where they help:
- elapsed-time staleness key for the supersede check
- 40a over-cautious AX-resolved-click yield
- writeFile `openat` / `O_NOFOLLOW` hardening
- CU question-heuristic widening

**Shell exec stays DEFERRED** by decision (`docs/design-fileops-shell.md`).

---

## Cascade / parallelism summary
- **Serial chokepoints:** H1 (schema + verify hook), J1 (ADR), I3 (re-score).
- **Fan-out:** H2 + H3 after H1; J and K in parallel after H; M items anytime; the I2 task corpus authored by parallel agents in advance.
- **Owner-gated (needs the operator's machine with TCC granted):** all of Phase I, plus H2's live run. the maintainer builds and analyzes; the operator runs.

## Immediate next action
1. `TaskCreate` the H–M phases for live tracking.
2. Start **H1 research** (`ActionLogEntry`, `ReceiptWriter`, the `Orchestrator` act→receipt path, `ReceiptReplayFormatter`), return the H1 plan + cascade assessment for sign-off before any edit.

## Status log (append per session)
- 2026-06-16 — roadmap created and approved (phases kept as-is; nested item/pair/phase cadence added). Not yet started. main at `45b1757`.
