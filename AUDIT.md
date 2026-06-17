# Audit Prompt — macOS Agent v0
# Use this to open any new Claude Code session on this repo.
# Purpose: audit what's been built, surface gaps against spec, and lock the
# agent to MANIFEST.md + AGENTS.md for the duration of the session.

---

## Mandatory first reads (do these before anything else)

Read both files completely before writing a single line of code or making any claim:

```
MANIFEST.md    — product spec, capability table, architecture, safety model, v1 queue
AGENTS.md      — engineering rules, non-negotiable constraints, rubric, vocabulary
```

These are the ground truth for this project. If there is any conflict between what
you observe in the code and what these docs say, surface the conflict. Do not resolve
it silently by choosing one side.

---

## Session opening: audit mode

Before taking any action, run this audit sequence in order. Report findings as a
structured table: `file:line | finding | severity (1–3) | notes`.

### Step 1 — Environment check

```bash
swift build 2>&1 | tail -20
swift test  2>&1 | tail -20
```

Report: pass / fail / warning count. Do not proceed if build fails — stop and report.

### Step 2 — Spec vs. code gap check

For each capability listed in MANIFEST.md §Core Capabilities, verify the named source
file exists and the capability is wired end-to-end in the live execution path.

Flag anything that is:
- Listed in MANIFEST.md but missing or stub-only in code
- Present in code but not documented in MANIFEST.md (undocumented surface area)
- In MANIFEST.md §Known Gaps but showing evidence of partial implementation
  (partial = worse than nothing — must be flagged)

### Step 3 — Non-negotiable rule check (from AGENTS.md)

Verify each of the following explicitly. Report PASS or FAIL with file:line for failures:

| Rule | How to verify |
|---|---|
| `SafetyPolicy.classify()` runs on every proposed action | `Orchestrator.swift` — confirm no execution path bypasses it |
| Every action (approved AND rejected) writes a receipt | `Orchestrator.swift` — confirm both branches call `writeReceipt()` |
| `Package.swift` has zero external dependencies | Read `Package.swift` dependencies array |
| No `@unchecked Sendable` without a comment explaining why | `grep -r "unchecked Sendable"` across Sources/ |
| `hardBoundaries` appears first in `AgentThroughline.promptBlock()` | Read `AgentThroughline.swift` |
| AX snapshot cache window is 200ms | Read `AXPerception.swift` — find the cache expiry |
| Gate parks + heartbeats on no answer (no auto-reject); self-rejects only at the park ceiling | Read `Orchestrator.gate()` |
| No `.confirm` tier action can be auto-approved | Read `AutonomyMode.adjustedTier()` — confirm `.confirm` is never downgraded |
| `disableParallelToolUse: true` is set on the tool call | Read `LLMClient.swift` `ClaudeTool.agentAction` |

### Step 4 — Test coverage check

Compare AGENTS.md §Testing §What Must Be Tested against the actual test files in
`Tests/MacAgentCoreTests/`. For each required item, report: covered / missing / partial.

### Step 5 — Known gaps check

For each item in MANIFEST.md §Known Gaps, verify its current state in code:
- Still a gap (nothing done) — OK, note as-is
- Partially started — flag as risk (partial impl with no spec is worse than none)
- Silently completed — flag for MANIFEST.md update

### Step 6 — DesktopAgentKit orphan

`Sources/DesktopAgentKit` exists but is not wired into `Package.swift`. Read its
contents and report: what is in there, does it duplicate anything in MacAgentCore,
and what is the correct disposition (wire it, delete it, or leave it)?

---

## Rules for this session (enforced from here forward)

These rules are in effect for every action taken after the audit completes.
They do not expire during the session.

1. **MANIFEST.md is the spec.** Any feature, change, or fix must be consistent with it.
   If a task would require changing the spec, stop and say so explicitly before proceeding.

2. **AGENTS.md is the contract.** Every rubric check in AGENTS.md §Rubric must pass
   before a change is considered done. Self-check against it before reporting completion.

3. **No scope creep.** If you notice something worth fixing that is outside the task,
   note it in one line. Do not act on it.

4. **No silent model changes.** Default action model is `claude-sonnet-4-6`.
   Planning model is `claude-haiku-4-5-20251001`. Do not swap, alias, or change these
   without a prompt from the operator explicitly authorizing it.

5. **No new dependencies.** `Package.swift` dependencies array stays empty.
   If a task seems to require a dependency, stop and report the tradeoff instead.

6. **Vocabulary is locked.** Use only the terms defined in AGENTS.md §Vocabulary.
   Do not invent synonyms. Snapshot, Receipt, Throughline, Tier, Gate, Planner, Loop.

7. **AuDHD-first UI rules are non-negotiable.** Any UI change must pass the checklist
   in AGENTS.md §AuDHD-First Defaults. No exceptions, no "it's just a small thing."

8. **Receipt chain is append-only.** `ActionLogEntry` schema: add fields freely, never
   remove them. Never add code that deletes receipt files.

9. **Safety gate cannot be bypassed.** If a proposed change would allow any action to
   execute without going through `SafetyPolicy.classify()` → `gate()`, refuse it.

10. **Commit shape.** One concern per commit. Format: `type(scope): description`.
    Scope = the module name. Do not bundle unrelated changes.

---

## How to update the spec

If during this session you discover that MANIFEST.md or AGENTS.md is wrong, outdated,
or missing something real that exists in code:

1. Call it out explicitly with a diff-style description of what needs to change.
2. Do not update the docs unilaterally. Propose the change, wait for operator confirmation.
3. After confirmation, update the doc first, then update the code to match — never the reverse.

---

## Closing the session

Before ending the session, confirm:

- [ ] `swift build` passes
- [ ] `swift test` passes  
- [ ] `swift run MacOSAgentSmoke` exits 0 (run this after any change to LLMClient.swift or Orchestrator.swift)
- [ ] Every change is consistent with MANIFEST.md
- [ ] Every rubric check in AGENTS.md §Rubric passes
- [ ] No fields removed from `ActionLogEntry`, `AgentThroughline`, or `TaskRecord`
- [ ] MANIFEST.md §Known Gaps updated if any gap was resolved or newly discovered
- [ ] PHASES.md phase status updated if a phase completed or a new gap was discovered
- [ ] Commit message follows `type(scope): description` format
