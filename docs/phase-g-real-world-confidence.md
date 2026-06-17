# Phase G — Real-World Confidence

Born from the 2026-06-10 confidence audit. Honest finding: the project has
strong *logic* and *safety-design* coverage (621 tests) and **near-zero
behavioral evidence it works on a real computer** — the test suite mocks the
LLM, the perception, and the executor; the "smoke" checks grade the model's
*proposed* action and never click, type, or touch a live app. Confidence in
software that autonomously drives a computer comes from *observed behavior*,
not from tests.

This phase exists to close that gap. Each section is tagged by who can
actually execute it, because honesty about ownership is the point.

DoD discipline (per item): research → plan → cascade → execute → adversarial
review → repeat until the item's stated DoD holds. Every code unit: build
clean, suite green, doc-drift gate green, fleet-reviewed.

## The confidence ladder (from the audit)

| Rung | What | Owner |
|---|---|---|
| 1 | One real, watched, end-to-end run | **the operator** (TCC + machine) |
| 2 | Each safety claim fired for real, once | **the operator**, from the protocol |
| 3 | Dogfood burn-in: 20–30 real tasks, logged | **the operator** runs, maintainer analyzes |
| 4 | Close the *testable* behavioral blind spots | **Maintainer** |
| 5 | Independent security read of the critical surface | **Maintainer** (tool) + operator |
| Meta | Process hardening (scripted-edit drift) | **Maintainer** |

## Sections (each a unit through the loop)

### G1 — Verify the executor's pure math (Rung 4) · Maintainer
The descale/coordinate logic in `resolveTarget` (vision-box → screen point:
`origin + box/scale`, centre computation) and `modifierFlags` parsing are
PURE arithmetic trapped inside display-bound methods, so today they have no
behavioral coverage — a wrong descale would only surface live. Extract them
to `internal static` pure functions (the established seam pattern) and pin
them with an input/output matrix (scales 1/2/3, non-zero capture origins,
off-origin boxes). **DoD:** the coordinate the agent would click is proven
correct for the matrix, with zero behavior change to the live path.

### G2 — Security review of the diff (Rung 5) · Maintainer
Run `/security-review` over the two-branch diff (8027577..HEAD) — a pass that
is NOT another self-review of the same author's code. Triage + fix real
findings, especially on the new egress/disk surface (readClipboard,
writeFile). **DoD:** no unaddressed high/medium security finding on the
capability surface.

### G3 — Live-verification protocol (Rungs 1+2 enabler) · Maintainer → Operator
A numbered, watch-this-happen checklist: every safety claim as one concrete
action + the exact observable that proves it (HUD appears; `rm -rf` blocks;
F13 approves from another app; writeFile lands only in the sandbox + shows
path on the card; drift yields). Plus a result-log template. Turns the operator's
first real run into a deliberate test of every claim, not a hope. **DoD:**
every safety invariant in MANIFEST has a corresponding live check with a
pass/fail observable.

### G4 — Dogfood evidence harness (Rung 3 enabler) · Maintainer → Operator
A `MacAgentReplay` summary mode that turns a real session's receipts into a
confidence report: task count, success/stall/yield/expired/rejected rates,
gate-tier histogram, the actual failures. So burn-in produces structured
evidence, not vibes. **DoD:** point it at a receipts dir, get a one-screen
confidence report.

### G5 — Process hardening (Meta) · Maintainer
The scripted-edit drift class bit the project 3× during development (inert fix, mangled
prompt, detached HEAD). Add a lightweight post-edit guard: a `scripts/`
check that greps for the known-bad shapes (a `case` added to an enum but
missing from a switch the build would catch — but ALSO doc/comment/intent
drift the build won't catch) and a discipline note in AGENTS. **DoD:** a
re-runnable check that would have caught at least the inert-edit class.

## Honest non-goals
- Some rungs cannot be done from the dev environment: granting TCC, watching
  the live app, running autonomous tasks. G1/G2/G4/G5 are maintainer-side;
  G3 and the live runs are the operator's, enabled by the G3/G4 artifacts.
  "Merged" ≠ "confident" until Rungs 1–3 are actually done.
