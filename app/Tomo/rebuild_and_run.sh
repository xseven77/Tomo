#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${ROOT_DIR}/dist/Tomo.app"

cd "${ROOT_DIR}"
"${ROOT_DIR}/package_env.sh"

echo "打包成功，准备重启应用..."
if pgrep -x Tomo >/dev/null || pgrep -x TomoGateway >/dev/null; then
  pkill -x Tomo 2>/dev/null || true
  pkill -x TomoGateway 2>/dev/null || true
  for _ in {1..30}; do
    if ! pgrep -x Tomo >/dev/null && ! pgrep -x TomoGateway >/dev/null; then
      break
    fi
    sleep 0.1
  done
  pkill -9 -x Tomo 2>/dev/null || true
  pkill -9 -x TomoGateway 2>/dev/null || true
fi

open "${APP_PATH}"
sleep 0.6
if pgrep -x Tomo >/dev/null; then
  echo "已重启 Tomo（dist/Tomo.app，PID $(pgrep -x Tomo | head -1)）"
  echo "请在菜单栏查看 Tomo 图标；独立窗口需从菜单打开。"
else
  echo "启动失败：未检测到 Tomo 进程" >&2
  exit 1
fi
