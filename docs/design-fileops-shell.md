# Design: File-write and Shell capabilities (Units 36–37)

Status: **File-write SHIPPED (Unit 36).** Sandboxed `writeFile` is implemented
(`ActionType.writeFile`, `.confirm` tier, 0700 workspace; documented in
MANIFEST §"What It Is Not"). **Shell exec remains DEFERRED** by decision; the
rationale below stands. This doc is retained as the decision record.

## Why this is a fork, not a routine unit

Every capability shipped so far drives the *same* surface a human already
operates by hand — mouse, keys, menus, clipboard read. The OS, the focused
app, and the AX permission boundary all still apply. File-write and shell are
categorically different: they let the agent act *outside* the visible UI, on
the filesystem and the command interpreter, where there is no on-screen
artifact to perceive, no app-level sandbox, and (for shell) arbitrary
code execution. This is the single largest threat-model change in the
project's history. MANIFEST currently states "No file system access" and (via
the shell-context escalation) treats Terminal as confirm-only precisely
because the project chose NOT to give the agent a direct exec path.

The recommendation below is therefore **narrow, not the obvious general
capability.**

## Unit 36 — file writes

### Options considered
- **A. General `writeFile(path, contents)`** — agent writes anywhere it has
  POSIX permission. Rejected: unbounded blast radius (overwrite `~/.zshrc`,
  drop a LaunchAgent, corrupt a project). No on-screen artifact, so the
  perception loop and the stale-snapshot guard provide zero protection.
- **B. `applyPatch` (unified-diff against an existing file)** — narrower, but
  still arbitrary-path and arbitrary-content; the diff format adds parsing
  surface without reducing reach.
- **C. Sandboxed scratch writes only** — `writeFile` restricted to a single
  opt-in directory (`~/Library/Application Support/MacAgent/workspace/`,
  0700), no path traversal, size-capped, every write `.confirm`-tiered and
  receipted with a content hash. **Recommended.**

### Recommended design (Option C)
- New `ActionType.writeFile`; `text` carries contents, a new `path` field
  (relative only) names the file *within the workspace root*.
- Executor resolves `workspaceRoot.appending(sanitized(path))`, rejects any
  `..` / absolute / symlink-escaping path, caps size (e.g. 256 KB), writes
  0600.
- SafetyPolicy: **always `.confirm`** (never auto, never widened by autonomy —
  same rule class as the held-mouse floor). The approval card shows path +
  byte count + a content preview.
- Receipt records path + SHA-256 of contents (not the contents — replay stays
  small; the file itself is the artifact). Off by default; the feature is
  inert unless the operator enables "Agent workspace" in Settings (mirrors
  the snapshot-sidecar opt-in).
- Explicitly NOT in scope: writing outside the workspace, executing what's
  written, modifying existing user files.

### Residual risk (accepted if approved)
The workspace is real disk the operator can later use; the agent could write
misleading content there. Bounded by: confirm-tier on every write, opt-in,
size cap, content-hash receipt, no execution path.

## Unit 37 — graduated shell

### Options considered
- **A. General `shell(command)`** — arbitrary command execution. Rejected
  outright: this is RCE-as-a-feature. The existing red-team suite
  (`isDangerousText`: `rm -rf`, `sudo`, `> /dev/…`) exists to *prevent* the
  agent from typing these into a terminal; handing it a direct exec path
  deletes that entire defense.
- **B. Allowlisted read-only commands** — a fixed set of side-effect-free
  introspection commands (`ls`, `cat`, `pwd`, `git status`, `git diff`) with
  no shell interpolation (exec the argv directly, never `sh -c`). Confirm-
  tiered, output-capped, receipted. **Recommended IF shell is wanted at all.**
- **C. Defer entirely** — keep shell out of v0; the agent can already drive a
  terminal app through the UI under the existing confirm-tier shell-context
  escalation, which preserves human-in-the-loop on every command.

### Recommendation: **C (defer), or B if the use case is concrete**
Shell is the one capability where the safer option is to NOT build it. The
agent already has a path to the terminal (type into Terminal.app, confirm-
tiered) that keeps every command human-approved and on-screen. A direct exec
path's only advantage is removing that friction — which is exactly the
safety property. If a specific read-only workflow needs it (e.g. "summarize
`git status` without a terminal window"), Option B with a fixed argv
allowlist and no `sh -c` is the bounded form. Anything mutating stays out.

## Cross-cutting requirements (either capability)
- New `ActionType` → schema + executor + LLM schema enum + SafetyPolicy
  review + CU translator (AGENTS.md checklist).
- MANIFEST "What It Is Not" updated to scope the new boundary precisely
  (e.g. "No file system access *except the opt-in agent workspace*").
- Heaviest fleet review in the project (per the Tier-2 plan).
- Capability-rule interaction: `alwaysAllow` must be FORBIDDEN for these
  action types (a standing rule auto-running shell/file-write defeats the
  confirm floor) — enforce in the rule-persistence path.

## Decision needed
1. File writes: ship Option C (sandboxed workspace), or defer?
2. Shell: defer (C), ship read-only allowlist (B), or defer pending a
   concrete use case?
