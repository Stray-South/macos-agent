# CLAUDE.md — macOS Agent v0

> Auto-loaded by Claude Code on every session in this repo.

## Read these before anything else

MANIFEST.md   — product spec, architecture, safety model, v1 queue
AGENTS.md     — engineering rules, constraints, rubric, vocabulary
PHASES.md     — phase map to personal beta, DoD per phase, burn-in matrix

Read all three in full before writing any code or making any claims.

## Current phase

Check PHASES.md — confirm the task is in scope before starting.
Do not implement work from a later phase without explicit operator instruction.

## Ground rules (always in effect)

- SafetyPolicy.classify() runs on every action. No bypass.
- Package.swift dependencies array stays empty.
- ActionLogEntry schema is append-only. Never remove fields.
- Every action (approved or rejected) writes a receipt. Both branches.
- No .confirm tier action can ever be auto-approved.
- Vocabulary locked to AGENTS.md §Vocabulary.
- AuDHD-first UI rules are structural requirements, not preferences.
- MANIFEST.md updated before code if spec changes — never after.

## DoD (runs before declaring any phase done)

swift build                 # zero errors, zero new warnings
swift test                  # all pass
swift run MacOSAgentSmoke   # exits 0
./scripts/build-app.sh && ./scripts/run-app.sh  # app launches clean

Plus Layer C behavioral checks in PHASES.md for the current phase.

## Stack

Swift 6.2 · SwiftUI + AppKit · macOS 14+ · zero external dependencies
Anthropic API via raw URLSession · AXUIElement · Vision · ScreenCaptureKit
