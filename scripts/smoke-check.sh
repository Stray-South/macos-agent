#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ANTHROPIC_API_KEY is required for smoke check." >&2
  exit 1
fi

cd "${ROOT_DIR}"
swift run MacOSAgentSmoke "$@"
