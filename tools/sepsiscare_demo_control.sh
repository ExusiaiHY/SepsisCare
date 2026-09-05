#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_BIN="${CURL_BIN:-curl}"
API_HOST="${SEPSISCARE_HOST:-127.0.0.1}"
API_PORT="${SEPSISCARE_PORT:-8765}"
MODEL_HOST="${SEPSISCARE_MODEL_HOST:-127.0.0.1}"
MODEL_PORT="${SEPSISCARE_MODEL_PORT:-8788}"
REMOTE_MODEL_BASE_URL="${SEPSISCARE_REMOTE_MODEL_URL:-${SEPSISCARE_PUBLIC_MODEL_BASE_URL:-http://100.65.136.96:8788}}"
RUNTIME_DIR="${SEPSISCARE_RUNTIME_DIR:-$ROOT_DIR/.sepsiscare-demo}"
LOG_DIR="$RUNTIME_DIR/logs"
BACKEND_RUNTIME="$RUNTIME_DIR/backend-runtime"
MODEL_RUNTIME="$RUNTIME_DIR/model-runtime"
ARTIFACT_RUNTIME="$RUNTIME_DIR/artifacts"
SERVICE_TOKEN_FILE="${SEPSISCARE_SERVICE_TOKEN_FILE:-$BACKEND_RUNTIME/sepsiscare_service_token.txt}"
BACKEND_PID="$RUNTIME_DIR/backend_${API_PORT}.pid"
MODEL_PID="$RUNTIME_DIR/model_${MODEL_PORT}.pid"
BACKEND_LOG="$LOG_DIR/backend_${API_PORT}.log"
MODEL_LOG="$LOG_DIR/model_${MODEL_PORT}.log"
MODEL_ROOT="$ROOT_DIR/03_remote_server_model_package/02_model_deploy_package"
BACKEND_ROOT="$ROOT_DIR/04_client_source/apps/sepsiscare-studio/backend"
DMG_PATH="$ROOT_DIR/02_installers/sepsiscare-1.0.1-macOS.dmg"
APP_TARGET="${SEPSISCARE_APP_TARGET:-$HOME/Applications/SepsisCare-macOS.app}"
VENV_DIR="$RUNTIME_DIR/venv"
NO_PROXY_VALUE="127.0.0.1,localhost,0.0.0.0,::1"

export NO_PROXY="${NO_PROXY:-$NO_PROXY_VALUE}"
export no_proxy="${no_proxy:-$NO_PROXY}"

usage() {
  cat <<USAGE
Usage:
  ./install_and_verify_macos.command
  ./start_local_demo.command
  ./verify_local_demo.command
  ./stop_local_demo.command

Advanced:
  tools/sepsiscare_demo_control.sh install-verify
  tools/sepsiscare_demo_control.sh start
  tools/sepsiscare_demo_control.sh verify
  tools/sepsiscare_demo_control.sh stop
  tools/sepsiscare_demo_control.sh status

Environment:
  SEPSISCARE_PORT=8765
  SEPSISCARE_MODEL_PORT=8788
  SEPSISCARE_REMOTE_MODEL_URL="$REMOTE_MODEL_BASE_URL"
  SEPSISCARE_SERVICE_TOKEN_FILE="$SERVICE_TOKEN_FILE"
  SEPSISCARE_APP_TARGET="$APP_TARGET"
  SEPSISCARE_SKIP_APP_INSTALL=1
  SEPSISCARE_SKIP_APP_OPEN=1
  SEPSISCARE_SKIP_DMG_VERIFY=1
USAGE
}

fail() {
  echo "not ok: $*" >&2
  exit 1
}

api_url() {
  echo "http://$API_HOST:$API_PORT"
}

model_url() {
  echo "http://$MODEL_HOST:$MODEL_PORT"
}

public_model_url() {
  echo "$REMOTE_MODEL_BASE_URL"
}

backend_listener_pid() {
  local pid
  for pid in $(lsof -nP -tiTCP:"$API_PORT" -sTCP:LISTEN 2>/dev/null || true); do
    local command_line
    command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command_line" == *"$BACKEND_ROOT/server.py"* ]] || [[ "$command_line" == *"/Contents/Resources/backend/server.py"* ]]; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}

stop_backend_listener() {
  local pid
  pid="$(backend_listener_pid || true)"
  [[ -n "$pid" ]] || return 0
  echo "stopping SepsisCare API listener pid=$pid"
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
}

ensure_service_token_file_permissions() {
  if [[ -f "$SERVICE_TOKEN_FILE" ]]; then
    chmod 600 "$SERVICE_TOKEN_FILE" >/dev/null 2>&1 || true
  else
    echo "warning: service token file is missing: $SERVICE_TOKEN_FILE" >&2
    echo "         Copy the ROG token from D:\\PredictionService\\models\\production\\02_model_deploy_package\\.runtime\\sepsiscare_service_token.txt" >&2
  fi
}

health_ok() {
  "$CURL_BIN" --noproxy "*" -fsS --max-time 5 "$1" >/dev/null 2>&1
}

wait_until_healthy() {
  local name="$1"
  local url="$2"
  local log_file="$3"
  for _ in $(seq 1 45); do
    if health_ok "$url"; then
      echo "ok: $name healthy at $url"
      return 0
    fi
    sleep 1
  done
  echo "not ok: $name did not become healthy at $url" >&2
  if [[ -f "$log_file" ]]; then
    echo "--- $log_file tail ---" >&2
    tail -100 "$log_file" >&2 || true
  fi
  exit 1
}

pid_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

stop_pid() {
  local name="$1"
  local pid_file="$2"
  if ! [[ -f "$pid_file" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  rm -f "$pid_file"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "stopping $name pid=$pid"
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.2
    wait "$pid" 2>/dev/null || true
    kill -0 "$pid" >/dev/null 2>&1 || return 0
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        wait "$pid" 2>/dev/null || true
        return 0
      fi
      sleep 0.2
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  fi
}

stop_services() {
  stop_pid "SepsisCare API" "$BACKEND_PID"
  stop_backend_listener
  stop_pid "SepsisCare model service" "$MODEL_PID"
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing directory: $1"
}

check_layout() {
  require_file "$ROOT_DIR/SHA256SUMS.txt"
  require_file "$DMG_PATH"
  require_file "$BACKEND_ROOT/server.py"
  require_file "$MODEL_ROOT/deploy/model_service.py"
  require_file "$MODEL_ROOT/deploy/audit_runtime_data.py"
  require_file "$ROOT_DIR/06_scripts/script/smoke_test.py"
  require_dir "$MODEL_ROOT/runtime_data"
  require_dir "$MODEL_ROOT/models/cloud_production/s7_phenotype_contrastive_full_20260516"
}

verify_checksums() {
  echo "==> Verifying packaged checksums"
  (cd "$ROOT_DIR" && shasum -c SHA256SUMS.txt >/tmp/sepsiscare-sha-check.log)
  tail -5 /tmp/sepsiscare-sha-check.log
}

python_has_demo_deps() {
  "$1" - <<'PY' >/dev/null 2>&1
import fastapi
import uvicorn
PY
}

python_for_demo() {
  command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "python3 was not found"
  if python_has_demo_deps "$PYTHON_BIN"; then
    echo "$PYTHON_BIN"
    return 0
  fi
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "creating local Python environment: $VENV_DIR" >&2
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  if ! python_has_demo_deps "$VENV_DIR/bin/python"; then
    echo "installing demo API dependencies" >&2
    "$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
    "$VENV_DIR/bin/python" -m pip install -r "$SCRIPT_DIR/requirements_demo.txt" >/dev/null
  fi
  echo "$VENV_DIR/bin/python"
}

verify_runtime_data() {
  echo "==> Auditing packaged runtime data"
  mkdir -p "$RUNTIME_DIR"
  "$PYTHON_BIN" "$MODEL_ROOT/deploy/audit_runtime_data.py" "$MODEL_ROOT/runtime_data" > "$RUNTIME_DIR/runtime_data_audit.json"
  "$PYTHON_BIN" - "$RUNTIME_DIR/runtime_data_audit.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
summary = data.get("summary", {})
if not data.get("ok"):
    raise SystemExit(f"not ok: runtime data audit failed: {summary}")
print(f"ok: runtime data audit patients={summary.get('patients')} detail_rows={summary.get('detail_rows')} violations={summary.get('violations')} warnings={summary.get('warnings')}")
PY
}

verify_dmg() {
  [[ "${SEPSISCARE_SKIP_DMG_VERIFY:-0}" != "1" ]] || {
    echo "skip: DMG verification disabled"
    return 0
  }
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "skip: DMG verification is macOS-only"
    return 0
  fi
  echo "==> Verifying macOS DMG"
  local mount_point="$RUNTIME_DIR/dmg-verify"
  rm -rf "$mount_point"
  mkdir -p "$mount_point"
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
  local app_path
  app_path="$(find "$mount_point" -maxdepth 2 -type d -name '*.app' | head -n 1)"
  [[ -n "$app_path" ]] || {
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fail "DMG did not contain a .app bundle"
  }
  test -x "$app_path/Contents/MacOS/SepsisCare-macOS" || {
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fail "DMG app executable is missing"
  }
  codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null
  hdiutil detach "$mount_point" >/dev/null
  echo "ok: DMG app bundle verified"
}

install_app() {
  [[ "${SEPSISCARE_SKIP_APP_INSTALL:-0}" != "1" ]] || {
    echo "skip: app install disabled"
    return 0
  }
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "skip: macOS app install is Darwin-only"
    return 0
  fi
  echo "==> Installing macOS app to $APP_TARGET"
  local mount_point="$RUNTIME_DIR/dmg-install"
  rm -rf "$mount_point"
  mkdir -p "$mount_point" "$(dirname "$APP_TARGET")"
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null
  local app_path
  app_path="$(find "$mount_point" -maxdepth 2 -type d -name '*.app' | head -n 1)"
  [[ -n "$app_path" ]] || {
    hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fail "DMG did not contain a .app bundle"
  }
  rm -rf "$APP_TARGET"
  ditto "$app_path" "$APP_TARGET"
  xattr -dr com.apple.quarantine "$APP_TARGET" >/dev/null 2>&1 || true
  codesign --verify --deep --strict --verbose=2 "$APP_TARGET" >/dev/null
  hdiutil detach "$mount_point" >/dev/null
  echo "ok: app installed at $APP_TARGET"
}

start_backend() {
  local py="$1"
  mkdir -p "$LOG_DIR" "$BACKEND_RUNTIME"
  ensure_service_token_file_permissions
  stop_backend_listener
  echo "==> Starting SepsisCare API at $(api_url)"
  nohup env \
    NO_PROXY="$NO_PROXY" \
    no_proxy="$no_proxy" \
    PYTHONUNBUFFERED=1 \
    SEPSISCARE_DEPLOY_ROOT="$MODEL_ROOT" \
    SEPSISCARE_RUNTIME_ROOT="$BACKEND_RUNTIME" \
    SEPSISCARE_SERVICE_TOKEN_FILE="$SERVICE_TOKEN_FILE" \
    SEPSISCARE_PUBLIC_API_BASE_URL="$(api_url)" \
    SEPSISCARE_PUBLIC_MODEL_BASE_URL="$(public_model_url)" \
    "$py" "$BACKEND_ROOT/server.py" --host "$API_HOST" --port "$API_PORT" \
    >"$BACKEND_LOG" 2>&1 &
  local backend_pid="$!"
  echo "$backend_pid" > "$BACKEND_PID"
  disown "$backend_pid" 2>/dev/null || true
  wait_until_healthy "SepsisCare API" "$(api_url)/health" "$BACKEND_LOG"
}

start_model() {
  local py="$1"
  mkdir -p "$LOG_DIR" "$MODEL_RUNTIME" "$ARTIFACT_RUNTIME"
  if health_ok "$(model_url)/health"; then
    echo "ok: SepsisCare model service already healthy at $(model_url)"
    return 0
  fi
  echo "==> Starting SepsisCare model service at $(model_url)"
  nohup env \
    NO_PROXY="$NO_PROXY" \
    no_proxy="$no_proxy" \
    PYTHONUNBUFFERED=1 \
    SEPSISCARE_DEPLOY_ROOT="$MODEL_ROOT" \
    SEPSISCARE_MODEL_HOST="$MODEL_HOST" \
    SEPSISCARE_MODEL_PORT="$MODEL_PORT" \
    SEPSISCARE_RUNTIME_ROOT="$MODEL_RUNTIME" \
    SEPSISCARE_ARTIFACT_DIR="$ARTIFACT_RUNTIME" \
    SEPSISCARE_DATABASE_ROOT="$MODEL_ROOT/runtime_data" \
    "$py" "$MODEL_ROOT/deploy/model_service.py" --host "$MODEL_HOST" --port "$MODEL_PORT" \
    >"$MODEL_LOG" 2>&1 &
  local model_pid="$!"
  echo "$model_pid" > "$MODEL_PID"
  disown "$model_pid" 2>/dev/null || true
  wait_until_healthy "SepsisCare model service" "$(model_url)/health" "$MODEL_LOG"
}

start_services() {
  check_layout
  local py
  py="$(python_for_demo)"
  start_model "$py"
  start_backend "$PYTHON_BIN"
  status_services
}

status_services() {
  echo "API:   $(api_url)"
  echo "Model: $(model_url)"
  echo "Cloud: $(public_model_url)"
  echo "Token: $SERVICE_TOKEN_FILE"
  echo "Logs:  $LOG_DIR"
  if health_ok "$(api_url)/health"; then echo "ok: API health"; else echo "offline: API health"; fi
  if health_ok "$(model_url)/health"; then echo "ok: model health"; else echo "offline: model health"; fi
}

run_full_smoke() {
  echo "==> Running full API/model smoke test"
  NO_PROXY="$NO_PROXY" no_proxy="$no_proxy" PYTHONUNBUFFERED=1 \
    SEPSISCARE_SERVICE_TOKEN_FILE="$SERVICE_TOKEN_FILE" \
    "$PYTHON_BIN" "$ROOT_DIR/06_scripts/script/smoke_test.py" "$(api_url)" "$(model_url)" --require-model
}

verify_generated_artifact() {
  echo "==> Downloading and verifying generated model artifact"
  mkdir -p "$ARTIFACT_RUNTIME"
  local artifact="$ARTIFACT_RUNTIME/sepsiscare_model_artifacts_latest.zip"
  "$CURL_BIN" --noproxy "*" -fsS "$(model_url)/api/artifacts/latest" -o "$artifact"
  "$PYTHON_BIN" "$MODEL_ROOT/deploy/verify_artifact_bundle.py" "$artifact"
  echo "ok: generated artifact verified at $artifact"
}

verify_all() {
  check_layout
  verify_checksums
  verify_runtime_data
  verify_dmg
  if [[ "${SEPSISCARE_KEEP_RUNNING_AFTER_VERIFY:-0}" != "1" ]]; then
    trap stop_services EXIT
  fi
  start_services
  run_full_smoke
  verify_generated_artifact
  echo "ok: full local SepsisCare verification completed"
}

open_app() {
  [[ "${SEPSISCARE_SKIP_APP_OPEN:-0}" != "1" ]] || {
    echo "skip: app open disabled"
    return 0
  }
  if [[ "$(uname -s)" == "Darwin" && -d "$APP_TARGET" ]]; then
    echo "==> Opening SepsisCare app"
    open "$APP_TARGET" || true
  fi
}

install_verify() {
  check_layout
  install_app
  SEPSISCARE_KEEP_RUNNING_AFTER_VERIFY=1 verify_all
  open_app
  echo "System ready."
  echo "Research/admin/family demo password: 123123"
  echo "Stop services later with: ./stop_local_demo.command"
}

case "$COMMAND" in
  install-verify)
    install_verify
    ;;
  verify)
    verify_all
    ;;
  start)
    start_services
    open_app
    ;;
  stop)
    stop_services
    ;;
  status)
    status_services
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
