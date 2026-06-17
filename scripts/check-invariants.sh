#!/bin/zsh
# Phase G5 — cross-file parity invariants the Swift compiler does NOT enforce.
#
# Born from the confidence audit: scripted multi-file edits silently produced
# wrong state three times in one session (an inert fix that never hit disk, a
# mangled prompt line, a detached-HEAD commit). The build catches missing
# enum cases in exhaustive switches — but NOT a hand-maintained string list
# drifting from the enum it mirrors. The worst version: a new ActionType the
# model literally cannot emit because someone forgot to add it to the LLM
# tool schema, or an action in the schema with no executor case. Both compile
# clean and fail only at runtime / in the wild.
#
# Run after any scripted edit and in CI. Exit 1 on any drift.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail=0
note() { print -r -- "  ✘ $1"; fail=1; }

AGENT_ACTION="Sources/MacAgentCore/Schema/AgentAction.swift"
LLM_CLIENT="Sources/MacAgentCore/Orchestrator/LLMClient.swift"
EXECUTOR="Sources/MacAgentCore/Executor/Executor.swift"

print -r -- "check-invariants:"

# --- Invariant 1: ActionType ↔ LLM tool-schema enum parity --------------
# Every ActionType case must EITHER be in allCasesForSchema (the model can
# emit it via the JSON tool) OR be on the documented schema-excluded list
# (actions that arrive only through the Computer-Use translator, never the
# JSON tool: the stateful-mouse trio).
SCHEMA_EXCLUDED=(mouseDown mouseUp mouseMove)

# Cases declared between `enum ActionType` and its closing brace.
action_cases=($(awk '/enum ActionType/{f=1} f&&/^[[:space:]]*case /{gsub(/,/," ");for(i=2;i<=NF;i++)print $i} f&&/^}/{exit}' "$AGENT_ACTION" | sort -u))
# Strings inside the allCasesForSchema DECLARATION's array literal. Anchor on
# the `static let allCasesForSchema` line (not the `"enum": .array(…)` usage
# elsewhere), collect from the NEXT line until the closing `]`.
schema_cases=($(awk '
  /static let allCasesForSchema/ {f=1; next}
  f && /\]/ {exit}
  f {print}
' "$LLM_CLIENT" | grep -oE '"[a-zA-Z]+"' | tr -d '"' | sort -u))

for c in "${action_cases[@]}"; do
  if (( ${schema_cases[(I)$c]} )); then continue; fi
  if (( ${SCHEMA_EXCLUDED[(I)$c]} )); then continue; fi
  note "ActionType '.$c' is neither in allCasesForSchema (LLMClient) nor the documented schema-excluded list — the model cannot emit it. Add it to the JSON tool schema, or to SCHEMA_EXCLUDED here with a reason."
done

# Reverse: a schema string with no matching ActionType case = dead schema entry.
for c in "${schema_cases[@]}"; do
  if (( ${action_cases[(I)$c]} )); then continue; fi
  note "allCasesForSchema lists '$c' but ActionType has no such case — dead/typo'd schema entry."
done

# --- Invariant 2: every ActionType has an executor switch arm -----------
# performAction switches over action.type; a missing arm IS a compile error,
# so this is a belt-and-suspenders presence check that the executor file at
# least mentions each case (catches an accidental file-region deletion that
# a stale build cache might mask).
for c in "${action_cases[@]}"; do
  if ! grep -qE "case \.$c\b|\.$c:" "$EXECUTOR"; then
    note "ActionType '.$c' is never referenced in Executor.swift — missing executor handling?"
  fi
done

if (( fail )); then
  print -r -- "check-invariants: FAILED — cross-file parity drift above."
  exit 1
fi
print -r -- "  ✓ ActionType ↔ schema ↔ executor parity holds (${#action_cases} action types)."
