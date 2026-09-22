#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Tomo"
BINARY_NAME="Tomo"
BRIDGE_BINARY_NAME="TomoAgentBridge"
VALIDATE_OAUTH_CONFIG_ONLY="false"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

if [[ "${1:-}" == "--validate-oauth-config" ]]; then
  VALIDATE_OAUTH_CONFIG_ONLY="true"
elif [[ "$#" -gt 0 ]]; then
  echo "Unknown option: $1" >&2
  exit 2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_VOLUME_NAME="${APP_NAME} ${VERSION}"
DMG_STAGING_DIR="${DIST_DIR}/dmg-staging"
BUILD_LOG="$(mktemp -t codexling-build)"
GEMINI_OAUTH_CONFIG_SOURCE=""
GEMINI_OAUTH_CONFIG_TEMP=""

cleanup_build_log() {
  rm -f "${BUILD_LOG}"
  if [[ -n "${GEMINI_OAUTH_CONFIG_TEMP}" ]]; then
    rm -f "${GEMINI_OAUTH_CONFIG_TEMP}"
  fi
}

trap cleanup_build_log EXIT

validate_gemini_oauth_config() {
  local config_path="$1" client_id
  plutil -lint "${config_path}" >/dev/null
  client_id="$(plutil -extract clientID raw -o - "${config_path}" 2>/dev/null || true)"
  [[ -n "${client_id}" ]]
}

prepare_gemini_oauth_config() {
  local explicit_path="${CODEXLING_GEMINI_OAUTH_CONFIG_PLIST:-}"
  local local_path="Resources/GeminiOAuthConfig.plist"
  local client_id="${CODEXLING_GEMINI_OAUTH_CLIENT_ID:-}"
  local legacy_client_secret="${CODEXLING_GEMINI_OAUTH_LEGACY_CLIENT_SECRET:-}"

  if [[ -n "${explicit_path}" ]]; then
    [[ -f "${explicit_path}" ]] || {
      echo "Gemini OAuth config file not found: ${explicit_path}" >&2
      exit 1
    }
    GEMINI_OAUTH_CONFIG_SOURCE="${explicit_path}"
  elif [[ -n "${client_id}" ]]; then
    GEMINI_OAUTH_CONFIG_TEMP="$(mktemp -t codexling-gemini-oauth).plist"
    plutil -create xml1 "${GEMINI_OAUTH_CONFIG_TEMP}"
    plutil -insert clientID -string "${client_id}" "${GEMINI_OAUTH_CONFIG_TEMP}"
    if [[ -n "${legacy_client_secret}" ]]; then
      plutil -insert legacyClientSecret -string "${legacy_client_secret}" "${GEMINI_OAUTH_CONFIG_TEMP}"
    fi
    GEMINI_OAUTH_CONFIG_SOURCE="${GEMINI_OAUTH_CONFIG_TEMP}"
  elif [[ -f "${local_path}" ]]; then
    GEMINI_OAUTH_CONFIG_SOURCE="${local_path}"
  fi

  if [[ -n "${GEMINI_OAUTH_CONFIG_SOURCE}" ]]; then
    if ! validate_gemini_oauth_config "${GEMINI_OAUTH_CONFIG_SOURCE}"; then
      echo "Gemini OAuth config must contain a non-empty clientID." >&2
      exit 1
    fi
    return
  fi

  if [[ "${CODEXLING_REQUIRE_GEMINI_OAUTH_CONFIG:-0}" == "1" ]]; then
    echo "Gemini OAuth config is required for release builds." >&2
    echo "Provide CODEXLING_GEMINI_OAUTH_CONFIG_PLIST or CODEXLING_GEMINI_OAUTH_CLIENT_ID." >&2
    exit 1
  fi

  echo "Warning: Gemini OAuth config not supplied; this development build cannot add Gemini accounts." >&2
}

prepare_gemini_oauth_config

if [[ "${VALIDATE_OAUTH_CONFIG_ONLY}" == "true" ]]; then
  echo "Gemini OAuth config validation passed."
  exit 0
fi

build_release_binary() {
  : > "${BUILD_LOG}"
  swift build -c release 2>&1 | tee "${BUILD_LOG}"
}

use_existing_binary_or_fail() {
  if [[ -x ".build/release/${BINARY_NAME}" ]]; then
    local newest_source binary_mtime
    newest_source="$(find Sources Resources Package.swift -type f -print0 | xargs -0 stat -f '%m %N' | sort -nr | head -1 | cut -d' ' -f1)"
    binary_mtime="$(stat -f '%m' ".build/release/${BINARY_NAME}")"

    if [[ "${binary_mtime}" -ge "${newest_source}" ]]; then
      echo "swift build failed; packaging existing up-to-date .build/release/${BINARY_NAME}" >&2
      return
    fi
  fi

  echo "swift build failed and no up-to-date release binary is available." >&2
  echo "Review the Swift compiler errors above, then retry ./package_app.sh." >&2
  exit 1
}

if ! build_release_binary; then
  if grep -Eq "compiled with module cache path|missing required module 'SwiftShims'" "${BUILD_LOG}"; then
    echo "Detected a stale Swift module cache after the project path changed." >&2
    echo "Cleaning .build and retrying once..." >&2
    swift package clean
    if ! build_release_binary; then
      use_existing_binary_or_fail
    fi
  else
    use_existing_binary_or_fail
  fi
fi

echo "Building Gateway for production..."
cargo build --release --manifest-path ../../crates/gateway-server/Cargo.toml

rm -rf "${DIST_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Helpers" "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${BINARY_NAME}" "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"
cp ".build/release/${BRIDGE_BINARY_NAME}" "${APP_BUNDLE}/Contents/Helpers/${BRIDGE_BINARY_NAME}"
if [[ -f "../../target/release/tomo-gateway" ]]; then
  cp "../../target/release/tomo-gateway" "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
  chmod +x "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
elif [[ -f "../../target/release/codexling-gateway" ]]; then
  cp "../../target/release/codexling-gateway" "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
  chmod +x "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
fi
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# OAuth 配置只进入最终 App bundle，不进入源码仓库；临时配置由 EXIT trap 删除。
if [[ -n "${GEMINI_OAUTH_CONFIG_SOURCE}" ]]; then
  cp "${GEMINI_OAUTH_CONFIG_SOURCE}" "${APP_BUNDLE}/Contents/Resources/GeminiOAuthConfig.plist"
fi

cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "../landing/public/brand/codexling-logo.webp" "${APP_BUNDLE}/Contents/Resources/tomo-logo.webp"
if [[ -f "../landing/public/brand/codexling-logo.webp" ]]; then
  cp "../landing/public/brand/codexling-logo.webp" "${APP_BUNDLE}/Contents/Resources/codexling-logo.webp"
fi
cp "Resources/github-mark.svg" "${APP_BUNDLE}/Contents/Resources/github-mark.svg"
cp -R "Resources/Pets" "${APP_BUNDLE}/Contents/Resources/Pets"
cp -R "Resources/Fonts" "${APP_BUNDLE}/Contents/Resources/Fonts"
mkdir -p "${APP_BUNDLE}/Contents/Resources/BrandAssets"
cp -R "../../assets/brands/catalog" "${APP_BUNDLE}/Contents/Resources/BrandAssets/catalog"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${BINARY_NAME}"
chmod +x "${APP_BUNDLE}/Contents/Helpers/${BRIDGE_BINARY_NAME}"

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

rm -rf "${DMG_STAGING_DIR}"
mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${DMG_STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

hdiutil create \
  -volname "${DMG_VOLUME_NAME}" \
  -srcfolder "${DMG_STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${DMG_STAGING_DIR}"

echo "Built ${APP_BUNDLE}"
echo "Version ${VERSION} (${BUILD_NUMBER})"
echo "Archive ${ZIP_PATH}"
echo "Disk image ${DMG_PATH}"
