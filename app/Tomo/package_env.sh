#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root_dir"

if [[ -f .env.local ]]; then
  set -a
  # shellcheck source=/dev/null
  source ./.env.local
  set +a
fi

exec "$root_dir/package_app.sh" "$@"
