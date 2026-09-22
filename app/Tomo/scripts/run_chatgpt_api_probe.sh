#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "==> 使用 Keychain 中 Codexling OAuth token 探测 ChatGPT API（需已登录）"
swift build -c release >/dev/null
BIN="${ROOT_DIR}/.build/release/Codexling"
if [[ ! -x "${BIN}" ]]; then
  echo "error: 未找到 ${BIN}" >&2
  exit 1
fi

"${BIN}" --probe-chatgpt-apis

LATEST="${HOME}/Library/Application Support/Codexling/api-probes/latest/manifest.json"
if [[ -f "${LATEST}" ]]; then
  echo ""
  echo "==> manifest 摘要（recommendation）："
  /usr/bin/python3 - <<'PY' "${LATEST}" 2>/dev/null || cat "${LATEST}"
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
print(m.get("recommendation", ""))
print("落盘目录键名 wham usage:", ", ".join(m.get("whamUsageTopLevelKeys", [])[:20]))
PY
fi
