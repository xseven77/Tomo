#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${ROOT_DIR}/dist/Codexling.app"

cd "${ROOT_DIR}"
if [[ ! -x "${ROOT_DIR}/package_local.sh" ]]; then
  echo "缺少本地打包脚本：${ROOT_DIR}/package_local.sh" >&2
  echo "请先创建被 .gitignore 排除的 package_local.sh 并写入本机 OAuth 配置。" >&2
  exit 1
fi
"${ROOT_DIR}/package_local.sh"

pkill -x Codexling 2>/dev/null || true
pkill -x CodexlingGateway 2>/dev/null || true
sleep 0.5
open "${APP_PATH}"
sleep 0.6
if pgrep -x Codexling >/dev/null; then
  echo "已重启 Codexling（dist/Codexling.app，PID $(pgrep -x Codexling | head -1)）"
  echo "请在菜单栏查看 Codexling 图标；独立窗口需从菜单打开。"
else
  echo "启动失败：未检测到 Codexling 进程" >&2
  exit 1
fi
