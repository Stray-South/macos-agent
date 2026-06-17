#!/bin/zsh
# notarize.sh — Submit the app bundle to Apple notarization and staple the ticket.
#
# Required env vars:
#   APPLE_ID          Your Apple ID email
#   NOTARIZE_PASSWORD App-specific password from appleid.apple.com/account/manage
#   TEAM_ID           Your Developer Team ID (see Apple Developer account)
#
# Optional:
#   SUBMIT_PATH       Path to the .app or .dmg to submit (default: dist/MacOSAgentV0.app)
#
# Usage:
#   APPLE_ID=you@example.com \
#   NOTARIZE_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#   TEAM_ID=YOUR_TEAM_ID \
#   ./scripts/notarize.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMIT_PATH="${SUBMIT_PATH:-${ROOT_DIR}/dist/MacOSAgentV0.app}"

: "${APPLE_ID:?APPLE_ID must be set}"
: "${NOTARIZE_PASSWORD:?NOTARIZE_PASSWORD must be set (app-specific password from appleid.apple.com)}"
: "${TEAM_ID:?TEAM_ID must be set}"

if [[ ! -e "${SUBMIT_PATH}" ]]; then
  echo "Submit path not found: ${SUBMIT_PATH}" >&2
  exit 1
fi

# Zip the .app for submission (notarytool accepts .zip, .dmg, or .pkg).
ZIP_PATH="${SUBMIT_PATH%.*}.zip"
echo "Zipping ${SUBMIT_PATH} → ${ZIP_PATH}…"
ditto -c -k --keepParent "${SUBMIT_PATH}" "${ZIP_PATH}"

echo "Submitting to Apple notarization (this takes 1–5 min)…"
xcrun notarytool submit "${ZIP_PATH}" \
  --apple-id "${APPLE_ID}" \
  --password "${NOTARIZE_PASSWORD}" \
  --team-id "${TEAM_ID}" \
  --wait

rm -f "${ZIP_PATH}"

echo "Stapling notarization ticket to ${SUBMIT_PATH}…"
xcrun stapler staple "${SUBMIT_PATH}"

echo "Notarization complete. Verifying Gatekeeper acceptance…"
spctl --assess --type exec --verbose "${SUBMIT_PATH}"
echo "Done."
