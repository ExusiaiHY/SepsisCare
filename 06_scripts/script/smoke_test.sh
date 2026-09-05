#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
API_BASE_URL="${SEPSISCARE_API_BASE_URL:-http://100.65.136.96:8788}"
MODEL_BASE_URL="${SEPSISCARE_MODEL_BASE_URL:-http://100.65.136.96:8788}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,0.0.0.0,::1,100.65.136.96}"
export no_proxy="${no_proxy:-$NO_PROXY}"

if [[ "${1:-}" == http://* || "${1:-}" == https://* ]]; then
  API_BASE_URL="$1"
  shift
fi

if [[ "${1:-}" == http://* || "${1:-}" == https://* ]]; then
  MODEL_BASE_URL="$1"
  shift
fi

MODE="${1:-local}"

"$PYTHON_BIN" "$SCRIPT_ROOT/smoke_test.py" "$API_BASE_URL" "$MODEL_BASE_URL" "$MODE"
