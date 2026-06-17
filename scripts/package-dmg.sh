#!/bin/zsh
# package-dmg.sh — Package the signed+notarized .app into a distributable .dmg.
#
# Run AFTER notarize.sh (the .app must already be stapled).
#
# Output: dist/MacOSAgentV0.dmg
#
# Usage:
#   ./scripts/package-dmg.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="MacOSAgentV0"
DIST_DIR="${ROOT_DIR}/dist"
APP_PATH="${DIST_DIR}/${PRODUCT_NAME}.app"
DMG_PATH="${DIST_DIR}/${PRODUCT_NAME}.dmg"
TMP_DMG="${DIST_DIR}/${PRODUCT_NAME}-tmp.dmg"
VOLUME_NAME="macOS Agent v0"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "App bundle not found at ${APP_PATH} — run build-app.sh first." >&2
  exit 1
fi

# Verify the bundle is notarized before packaging.
if ! spctl --assess --type exec "${APP_PATH}" 2>/dev/null; then
  echo "Warning: bundle did not pass Gatekeeper assessment." \
       "Run notarize.sh before package-dmg.sh for a distributable DMG." >&2
fi

rm -f "${DMG_PATH}" "${TMP_DMG}"

echo "Creating DMG…"
hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${APP_PATH}" \
  -ov \
  -format UDRW \
  "${TMP_DMG}"

echo "Converting to compressed read-only DMG…"
hdiutil convert "${TMP_DMG}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${DMG_PATH}"

rm -f "${TMP_DMG}"

echo "DMG ready: ${DMG_PATH}"
ls -lh "${DMG_PATH}"
