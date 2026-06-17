#!/bin/zsh
# check.sh — local CI equivalent. Run before every commit/push.
#
# Stages:
#   1. swift build  (zero-warning gate — strict mode)
#   2. swift test   (all pass)
#   3. build-app.sh (bundle + codesign verify)
#   4. smoke        (live Claude API — auto-runs if key in env or keychain)
#
# Full output is mirrored to .local-ci.log (gitignored). On failure the
# trap prints the log path so you can scroll back without re-running.
#
# Exits 0 on full success, non-zero on first failure.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

LOG_FILE="${ROOT_DIR}/.local-ci.log"

# Mirror everything to the log file. Trap surfaces the log path on failure.
exec > >(tee "${LOG_FILE}") 2>&1
trap 'rc=$?; [[ $rc -ne 0 ]] && echo "" && echo "✗ check failed (exit $rc) — full output: ${LOG_FILE}"; exit $rc' EXIT

echo "── Toolchain ──"
swift --version | head -1
echo "macOS $(sw_vers -productVersion) · $(uname -m)"
echo

# ── 1/4 build (with warning gate) ──
echo "── 1/4 build ──"
t0=$SECONDS
build_out="$(mktemp)"
swift build 2>&1 | tee "${build_out}"
warnings=$(grep -cE "\.swift:[0-9]+:[0-9]+: warning:" "${build_out}" || true)
rm -f "${build_out}"
if [[ "${warnings}" -gt 0 ]]; then
  echo ""
  echo "✗ ${warnings} compiler warning(s) — strict mode rejects."
  exit 1
fi
echo "✓ build clean ($((SECONDS - t0))s)"
echo

# ── invariants — cross-file parity the compiler can't catch (G5) ──
echo "── invariants ──"
./scripts/check-invariants.sh
echo

# ── 2/4 test ──
echo "── 2/4 test ──"
t0=$SECONDS
swift test 2>&1 | tail -3
echo "✓ tests pass ($((SECONDS - t0))s)"
echo

# ── 3/4 .app bundle ──
echo "── 3/4 .app bundle ──"
t0=$SECONDS
./scripts/build-app.sh 2>&1 | tail -3
codesign --verify --deep --strict dist/MacOSAgentV0.app
echo "✓ bundle verified ($((SECONDS - t0))s)"
echo

# ── 4/4 smoke (auto if key available) ──
echo "── 4/4 smoke ──"
RESOLVED_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "${RESOLVED_KEY}" ]]; then
  RESOLVED_KEY=$(security find-generic-password \
    -s "com.southernreach.macos-agent-v0" \
    -a "anthropic-api-key" -w 2>/dev/null || echo "")
fi

if [[ -z "${RESOLVED_KEY}" ]]; then
  echo "⚠  skipped — no API key in env or keychain"
else
  t0=$SECONDS
  ANTHROPIC_API_KEY="${RESOLVED_KEY}" swift run MacOSAgentSmoke > /dev/null
  echo "✓ smoke passed ($((SECONDS - t0))s)"
fi
echo

echo "═══ all checks passed ═══"
