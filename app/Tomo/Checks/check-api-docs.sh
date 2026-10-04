#!/usr/bin/env bash
set -euo pipefail
TOMO_CHECK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOMO_CHECK_TEMP="$(mktemp -d -t tomo-docs-check)"
trap 'rm -rf "$TOMO_CHECK_TEMP"' EXIT
swiftc -swift-version 6 -module-cache-path "$TOMO_CHECK_TEMP/module-cache" \
  "$TOMO_CHECK_ROOT/Sources/Tomo/ApiDocsAssets.swift" \
  "$TOMO_CHECK_ROOT/Sources/Tomo/ApiDocsServer.swift" \
  "$TOMO_CHECK_ROOT/Sources/Tomo/HTTPRequestFramer.swift" \
  "$TOMO_CHECK_ROOT/Checks/ApiDocsCheck.swift" -o "$TOMO_CHECK_TEMP/check"
"$TOMO_CHECK_TEMP/check"
