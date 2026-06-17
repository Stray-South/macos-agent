#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/MacOSAgentV0.app"

if [[ ! -d "${APP_PATH}" ]]; then
  DEVELOPER_ID="${DEVELOPER_ID:-}" \
    "${ROOT_DIR}/scripts/build-app.sh"
fi

# Inject API key into launchd so the GUI app inherits it (GUI apps don't
# inherit shell env vars). Falls back to keychain if env var is not set.
_KEY="${ANTHROPIC_API_KEY:-$(security find-generic-password -s 'com.southernreach.macos-agent-v0' -a 'anthropic-api-key' -w 2>/dev/null || true)}"
if [[ -n "${_KEY}" ]]; then
  launchctl setenv ANTHROPIC_API_KEY "${_KEY}"
fi

# Remove the quarantine flag that macOS places on freshly-built binaries.
# Without this, Gatekeeper may block the app silently.
xattr -cr "${APP_PATH}" 2>/dev/null || true

open -na "${APP_PATH}"
