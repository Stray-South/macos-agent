#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT_NAME="MacOSAgentV0"
APP_NAME="${PRODUCT_NAME}.app"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

if [[ "${CONFIGURATION:l}" == "release" ]]; then
  BUILD_FLAG="--configuration release"
  BUILD_SUBDIR="release"
else
  BUILD_FLAG=""
  BUILD_SUBDIR="debug"
fi

echo "Building ${PRODUCT_NAME} (${CONFIGURATION})..."
cd "${ROOT_DIR}"
swift build ${=BUILD_FLAG}

BIN_PATH="${ROOT_DIR}/.build/${BUILD_SUBDIR}/${PRODUCT_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Expected executable not found at ${BIN_PATH}" >&2
  exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/App/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${BIN_PATH}" "${MACOS_DIR}/${PRODUCT_NAME}"
chmod +x "${MACOS_DIR}/${PRODUCT_NAME}"

if [[ -d "${ROOT_DIR}/Sources/MacOSAgentV0/Resources" ]]; then
  cp -R "${ROOT_DIR}/Sources/MacOSAgentV0/Resources/." "${RESOURCES_DIR}/"
fi

# Sign with Developer ID for distribution. Falls back to ad-hoc for local debug builds
# when DEVELOPER_ID is not set (CI, contributors without the cert).
DEVELOPER_ID="${DEVELOPER_ID:-}"
ENTITLEMENTS="${ROOT_DIR}/App/MacOSAgentV0.entitlements"

if [[ -n "${DEVELOPER_ID}" ]]; then
  echo "Signing app bundle (Developer ID: ${DEVELOPER_ID})…"
  codesign --force --deep --strict \
    --sign "${DEVELOPER_ID}" \
    --entitlements "${ENTITLEMENTS}" \
    --options runtime \
    "${APP_DIR}"
else
  echo "DEVELOPER_ID not set — signing ad-hoc (local use only, not notarizable)."
  codesign --force --deep --sign - "${APP_DIR}"
fi

echo "Verifying signature…"
codesign --verify --deep --strict "${APP_DIR}" && echo "Signature OK."

echo "Built app bundle at ${APP_DIR}"
