#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacOSAgentV0.app"
DIST_APP="${ROOT_DIR}/dist/${APP_NAME}"
INSTALL_DIR="/Applications"
INSTALL_APP="${INSTALL_DIR}/${APP_NAME}"

# Build release binary and sign it.
echo "Building release…"
CONFIGURATION=release "${ROOT_DIR}/scripts/build-app.sh"

# Install — remove old copy first so codesign seals are not stale.
echo "Installing to ${INSTALL_DIR}…"
if [[ -d "${INSTALL_APP}" ]]; then
  rm -rf "${INSTALL_APP}"
fi
cp -R "${DIST_APP}" "${INSTALL_DIR}/"

# Strip quarantine and provenance xattrs macOS applies during the copy.
# Without these attributes Gatekeeper never assesses the app — it only checks
# apps that arrived from outside the machine (downloads, AirDrop, etc.).
echo "Clearing extended attributes…"
xattr -cr "${INSTALL_APP}"

# Confirm signature is intact after copy.
echo "Verifying install…"
codesign --verify --deep --strict "${INSTALL_APP}" && echo "Signature OK."

echo ""
echo "✓ Installed: ${INSTALL_APP}"
echo ""
echo "Next steps:"
echo "  • Spotlight (⌘Space) → type 'macOS Agent' → press Return"
echo "  • Or drag MacOSAgentV0.app from /Applications to your Dock"
echo "  • On first launch, approve Accessibility + Screen Recording in System Settings"
