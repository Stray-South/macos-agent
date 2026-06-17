# Security review — feat/aesthetic-multiapp (Phase G2)

Independent pass (the `/security-review` tool + a parallel false-positive
filter), NOT another instance of the author reviewing their own code — the
exact concern the confidence audit raised. Scope: the new egress/disk
attack surface (writeFile, readClipboard, PendingGateJournal, drift guard,
replay --report).

## Result: no HIGH/MEDIUM findings at ≥8 confidence.

### Dismissed (filtered, confidence 2/10)
- **TOCTOU symlink-swap in `Executor.performWriteFile`.** A same-user
  process could race the containment re-check vs the `.atomic` write to
  redirect a write outside the sandbox. NOT a vulnerability: the sandbox's
  adversary is the untrusted LLM (one path string, cannot run a race loop —
  deterministic guards hold). The only actor who could win the race is a
  same-user process that ALREADY has full same-user write access and gains
  nothing. Crosses no privilege boundary. Optional hardening only
  (`openat`+`O_NOFOLLOW`), already acknowledged in-code.

### Verified clean
- writeFile gate-bypass: `.confirm` hard-returned top of classify, never
  downgraded by autonomy, floor-bound, alwaysAllow forbidden.
- writeFile deterministic escape: absolute/`~`/`..`/leaf-symlink/
  intermediate-symlink/sibling-prefix all rejected.
- PendingGateJournal injection: decoded action never re-executed; tier
  validated; unknown type → decode fail → .unreadable; strings capped;
  receipt JSON-escaped; UI is plain SwiftUI Text.
- readClipboard / drift guard / replay: no injection surface; replay
  read-only.

### Optional hardening backlog (not blocking)
- writeFile: open parent by fd + `openat(O_CREAT|O_EXCL|O_NOFOLLOW)` to
  close the residual same-user TOCTOU window deterministically.
