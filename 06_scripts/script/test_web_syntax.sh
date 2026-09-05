#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPS_ROOT="$ROOT_DIR/04_client_source/apps"
NODE_BIN="${NODE_BIN:-node}"

check_file() {
  local path="$1"
  if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    echo "not ok: node is required for Web syntax checks" >&2
    exit 1
  fi
  "$NODE_BIN" --check "$path" >/dev/null
}

check_file "$APPS_ROOT/sepsiscare-web-client/app.js"
check_file "$APPS_ROOT/SepsisCare-Windows/renderer/web/app.js"
check_file "$APPS_ROOT/SepsisCare-iOS/Resources/Web/app.js"
check_file "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web/app.js"

echo "web syntax checks passed"
