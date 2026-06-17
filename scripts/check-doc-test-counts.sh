#!/bin/bash
# scripts/check-doc-test-counts.sh
#
# Unit 12 (Path B) — fail-fast guard against test-count drift between
# the suite's actual size and the numbers cited in PHASES.md + MANIFEST.md.
#
# During the H3 chain this session the count went stale 4 times across
# 12 commits (368 → 371 → 375 → 377 → 383 → 388 → 390 → 391 → 401 → 407)
# and each drift required reactive fix-up commits. This script automates
# the check.
#
# Two modes:
#   ./scripts/check-doc-test-counts.sh           — run swift test, then check
#   ./scripts/check-doc-test-counts.sh --count N — use pre-supplied count
#                                                   (CI calls it this way
#                                                    to avoid double-running)
#
# Exit codes:
#   0 = counts match
#   1 = drift (swift test count differs from PHASES.md or MANIFEST.md)
#   2 = could not parse one of the inputs (treat as drift — fix immediately)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# --- Resolve the actual swift test count ---
ACTUAL=""
if [[ "${1:-}" == "--count" && -n "${2:-}" ]]; then
  ACTUAL="$2"
else
  echo "Running swift test to determine actual count..."
  # Capture stderr+stdout. swift test prints the summary as a passed-test line
  # at the very end: "✔ Test run with 407 tests in 0 suites passed after 1.2s."
  # Grep the line, extract the integer before "tests".
  #
  # `|| true` at end of pipe: pipefail (set above) affects exit codes WITHIN
  # the pipeline, but `|| true` as a list-op overrides the aggregate exit.
  # If grep finds nothing, ACTUAL becomes empty and the -z check below fires
  # an exit-2 with a clear error. Don't "fix" the `|| true` — removing it
  # makes the script crash without the diagnostic message.
  OUTPUT=$(swift test 2>&1)
  ACTUAL=$(echo "$OUTPUT" \
           | grep -oE "Test run with [0-9]+ tests" \
           | head -1 \
           | grep -oE "[0-9]+" || true)
fi

if [[ -z "$ACTUAL" ]]; then
  echo "::error::Could not parse test count from 'swift test' output." >&2
  echo "::error::Expected a line containing 'Test run with N tests'." >&2
  exit 2
fi
echo "Actual test count (swift test): ${ACTUAL}"

# --- Parse PHASES.md header ---
# Format: "> Last updated: ... — 407/407 tests pass, build clean. ..."
PHASES_COUNT=$(grep -oE "[0-9]+/[0-9]+ tests pass" PHASES.md \
               | head -1 \
               | grep -oE "^[0-9]+" || true)

if [[ -z "$PHASES_COUNT" ]]; then
  echo "::error file=PHASES.md::Could not find an 'N/N tests pass' string." >&2
  echo "::error file=PHASES.md::Expected the 'Last updated' header line." >&2
  exit 2
fi
echo "PHASES.md count:               ${PHASES_COUNT}"

# --- Parse MANIFEST.md Known Gaps "Test coverage" row ---
# Format-LOCKED: "| Test coverage | 407 tests. Loop ... | Low |".
# The regex below requires the literal sequence
#     "Test coverage SP | SP <digits> SP tests"
# (where SP = one space). If the table is ever reflowed to collapse
# whitespace (e.g. `|Test coverage|407 tests|`), this grep silently
# misses → exit 2 with diagnostic. Update the regex AND the grep in
# .github/workflows/test-count-drift.yml in lockstep with any table
# reformat.
MANIFEST_COUNT=$(grep -oE "Test coverage \| [0-9]+ tests" MANIFEST.md \
                 | head -1 \
                 | grep -oE "[0-9]+" || true)

if [[ -z "$MANIFEST_COUNT" ]]; then
  echo "::error file=MANIFEST.md::Could not find 'Test coverage | N tests' row." >&2
  echo "::error file=MANIFEST.md::Expected the Known Gaps test-coverage entry." >&2
  exit 2
fi
echo "MANIFEST.md count:             ${MANIFEST_COUNT}"

# --- Compare ---
DRIFTED=0
if [[ "$PHASES_COUNT" != "$ACTUAL" ]]; then
  echo "::error file=PHASES.md::Test count drift: PHASES.md says ${PHASES_COUNT}, swift test ran ${ACTUAL}." >&2
  echo "::error file=PHASES.md::Update the 'Last updated: ... — N/N tests pass' header line." >&2
  DRIFTED=1
fi
if [[ "$MANIFEST_COUNT" != "$ACTUAL" ]]; then
  echo "::error file=MANIFEST.md::Test count drift: MANIFEST.md says ${MANIFEST_COUNT}, swift test ran ${ACTUAL}." >&2
  echo "::error file=MANIFEST.md::Update the '| Test coverage | N tests.' row in §Known Gaps." >&2
  DRIFTED=1
fi

if [[ $DRIFTED -eq 1 ]]; then
  echo ""
  echo "💡 To fix: edit both docs to say ${ACTUAL} tests, then re-run this script."
  exit 1
fi

echo ""
echo "✅ Test counts match across swift test, PHASES.md, and MANIFEST.md (${ACTUAL})."
