#!/usr/bin/env bash
set -euo pipefail

# Run before signing: copy the exact library linked by the executable and make
# the bundle independent of the build machine's Homebrew installation.
app_bundle="$1"
binary="${app_bundle}/Contents/MacOS/Tomo"
frameworks="${app_bundle}/Contents/Frameworks"
linked_zstd="$(otool -L "${binary}" | awk 'NR > 1 && $1 ~ /(^|\/)libzstd[^[:space:]]*\.dylib$/ { print $1 }')"
if [[ -z "${linked_zstd}" || "${linked_zstd}" == *$'\n'* || "${linked_zstd}" != /* || ! -f "${linked_zstd}" ]]; then
  echo "Expected one accessible absolute libzstd dependency in ${binary}; found: ${linked_zstd}" >&2
  exit 1
fi
mkdir -p "${frameworks}"
cp -L "${linked_zstd}" "${frameworks}/libzstd.1.dylib"
chmod u+w "${frameworks}/libzstd.1.dylib"
install_name_tool -id '@rpath/libzstd.1.dylib' "${frameworks}/libzstd.1.dylib"
install_name_tool -change "${linked_zstd}" '@executable_path/../Frameworks/libzstd.1.dylib' "${binary}"

# Fail the release rather than ship any binary that depends on a local brew.
for binary in "${app_bundle}/Contents/MacOS/Tomo" "${app_bundle}/Contents/Helpers/TomoAgentBridge" "${app_bundle}/Contents/Helpers/TomoGateway" "${frameworks}/libzstd.1.dylib"; do
  if otool -L "${binary}" | tail -n +2 | grep -E '^[[:space:]]*/(opt/homebrew|usr/local)/' >/dev/null; then
    echo "Unbundled local dependency in ${binary}:" >&2
    otool -L "${binary}" >&2
    exit 1
  fi
done
codesign --force --sign - "${frameworks}/libzstd.1.dylib"
