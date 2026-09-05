#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-all}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"

REMOTE_SERVER_HOST="${REMOTE_SERVER_HOST:-remote-server}"
REMOTE_SERVER_DIR="${REMOTE_SERVER_DIR:-~/SepsisCare_macOS_app_model_transfer_20260528}"
REMOTE_SERVER_MODEL_HOST="${REMOTE_SERVER_MODEL_HOST:-0.0.0.0}"
REMOTE_SERVER_MODEL_PORT="${REMOTE_SERVER_MODEL_PORT:-8788}"
REMOTE_SERVER_MODEL_URL="${REMOTE_SERVER_MODEL_URL:-http://$REMOTE_SERVER_HOST:$REMOTE_SERVER_MODEL_PORT}"
LOCAL_API_URL="${LOCAL_API_URL:-http://127.0.0.1:8765}"
LOCAL_ARTIFACT_DIR="${LOCAL_ARTIFACT_DIR:-$ROOT_DIR/.sepsiscare-runtime/remote-server-artifacts}"
SECURITY_REPORT_DIR="${SEPSISCARE_SECURITY_REPORT_DIR:-$SECURITY_REPORT_DIR_DEFAULT}"
PRE_RELEASE_OVERRIDE_AUDIT_LOG="${SEPSISCARE_PRE_RELEASE_OVERRIDE_AUDIT_LOG:-$SECURITY_REPORT_DIR/pre_release_override_audit.jsonl}"
SEPSISCARE_ALLOW_REAL_TRAINING="${SEPSISCARE_ALLOW_REAL_TRAINING:-0}"
SEPSISCARE_SERVICE_TOKEN="${SEPSISCARE_SERVICE_TOKEN:-${SEPSISCARE_TRAINING_TOKEN:-}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-12}"

SSH_BIN="${SSH_BIN:-ssh}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
CURL_BIN="${CURL_BIN:-curl}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BASH_BIN="${BASH_BIN:-bash}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-$SCRIPT_ROOT/smoke_test.sh}"
DRY_RUN="${DRY_RUN:-0}"

REMOTE_PACKAGE_DIR="${REMOTE_SERVER_DIR%/}/02_model_deploy_package"
LOCAL_PACKAGE_DIR="$MODEL_PACKAGE_ROOT"
ARTIFACT_PATH="$LOCAL_ARTIFACT_DIR/sepsiscare_model_artifacts_latest.zip"
VERIFY_ARTIFACT_SCRIPT="$LOCAL_PACKAGE_DIR/deploy/verify_artifact_bundle.py"
AUDIT_RUNTIME_DATA_SCRIPT="$SCRIPT_ROOT/audit_runtime_data.py"
AUDIT_SENSITIVE_DATA_SCRIPT="$SCRIPT_ROOT/audit_sensitive_data.py"
PRE_RELEASE_CHECK_SCRIPT="$SCRIPT_ROOT/pre_release_security_check.sh"
SENSITIVE_AUDIT_ROOTS=(
  "$LOCAL_PACKAGE_DIR"
  "$APPS_ROOT/sepsiscare-studio/backend"
  "$APPS_ROOT/sepsiscare-web-client"
  "$APPS_ROOT/SepsisCare-Windows/renderer/web"
  "$APPS_ROOT/SepsisCare-iOS/Resources/Web"
  "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web"
)

usage() {
  cat <<USAGE
usage: $0 [all|preflight|sync|deploy|smoke|pull-artifacts]

Default flow:
  all = preflight + sync + deploy + smoke + pull-artifacts

Environment:
  REMOTE_SERVER_HOST=remote-server
  REMOTE_SERVER_DIR=~/SepsisCare_macOS_app_model_transfer_20260528
  REMOTE_SERVER_MODEL_HOST=0.0.0.0
  REMOTE_SERVER_MODEL_PORT=8788
  REMOTE_SERVER_MODEL_URL=http://remote-server:8788
  LOCAL_API_URL=http://127.0.0.1:8765
  LOCAL_ARTIFACT_DIR=$ROOT_DIR/.sepsiscare-runtime/remote-server-artifacts
  SEPSISCARE_ALLOW_REAL_TRAINING=0
  SEPSISCARE_SERVICE_TOKEN=...   # optional Bearer token for secured remote model endpoints
  SEPSISCARE_ARTIFACT_SIGNING_KEY=... # optional HMAC key for artifact manifest verification
  SEPSISCARE_SKIP_PRE_RELEASE_CHECK=0 # set to 1 only for emergency/manual override
  SEPSISCARE_SKIP_PRE_RELEASE_REASON=... # required operational reason for skip override audit
  SEPSISCARE_PRE_RELEASE_OVERRIDE_AUDIT_LOG=$PRE_RELEASE_OVERRIDE_AUDIT_LOG
  DRY_RUN=1
USAGE
}

fail() {
  echo "not ok: $*" >&2
  exit 1
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

remote_shell_path() {
  local value="$1"
  if [[ "$value" == "~/"* ]]; then
    printf '~/%s' "$(shell_quote "${value:2}")"
  else
    shell_quote "$value"
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_cmd "$@"
    return 0
  fi
  "$@"
}

log_cmd() {
  local arg
  printf '+'
  for arg in "$@"; do
    case "$arg" in
      [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:\ [Bb][Ee][Aa][Rr][Ee][Rr]\ *)
        printf ' %q' "Authorization: Bearer [redacted]"
        ;;
      *)
        printf ' %q' "$arg"
        ;;
    esac
  done
  printf '\n'
}

check_local_package() {
  [[ -d "$LOCAL_PACKAGE_DIR/deploy" ]] || fail "missing local model deploy package: $LOCAL_PACKAGE_DIR"
  [[ -f "$LOCAL_PACKAGE_DIR/deploy/remote_server_one_click_deploy.sh" ]] || fail "missing remote server deploy entrypoint: $LOCAL_PACKAGE_DIR/deploy/remote_server_one_click_deploy.sh"
}

audit_runtime_data() {
  [[ -f "$AUDIT_RUNTIME_DATA_SCRIPT" ]] || fail "missing runtime data audit script: $AUDIT_RUNTIME_DATA_SCRIPT"
  echo "auditing runtime data before release"
  run_cmd "$PYTHON_BIN" "$AUDIT_RUNTIME_DATA_SCRIPT" "$LOCAL_PACKAGE_DIR/runtime_data"
}

audit_sensitive_data() {
  [[ -f "$AUDIT_SENSITIVE_DATA_SCRIPT" ]] || fail "missing sensitive data audit script: $AUDIT_SENSITIVE_DATA_SCRIPT"
  echo "auditing release files for secrets and PHI before transfer"
  run_cmd "$PYTHON_BIN" "$AUDIT_SENSITIVE_DATA_SCRIPT" "${SENSITIVE_AUDIT_ROOTS[@]}"
}

audit_pre_release_override() {
  local audit_dir
  local reason
  audit_dir="$(dirname "$PRE_RELEASE_OVERRIDE_AUDIT_LOG")"
  reason="${SEPSISCARE_SKIP_PRE_RELEASE_REASON:-}"
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  [[ -n "$reason" ]] || fail "SEPSISCARE_SKIP_PRE_RELEASE_REASON is required when skipping the pre-release security check"
  mkdir -p "$audit_dir"
  python3 - "$PRE_RELEASE_OVERRIDE_AUDIT_LOG" "$COMMAND" "$reason" <<'PY'
import getpass
import json
import os
import socket
import sys
from datetime import datetime, timezone

log_path, command, reason = sys.argv[1:4]
event = {
    "event": "pre_release_check_skipped",
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "command": command,
    "reason": reason,
    "user": getpass.getuser() or "unknown",
    "host": socket.gethostname() or "unknown",
}
fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
os.chmod(log_path, 0o600)
PY
  chmod 600 "$PRE_RELEASE_OVERRIDE_AUDIT_LOG"
  echo "pre-release override audit: $PRE_RELEASE_OVERRIDE_AUDIT_LOG"
}

pre_release_check() {
  if [[ "${SEPSISCARE_SKIP_PRE_RELEASE_CHECK:-0}" == "1" ]]; then
    echo "pre-release security check skipped by SEPSISCARE_SKIP_PRE_RELEASE_CHECK=1"
    audit_pre_release_override
    return
  fi
  if [[ "${SEPSISCARE_PRE_RELEASE_CHECKED:-0}" == "1" ]]; then
    echo "pre-release security check already completed"
    return
  fi
  [[ -f "$PRE_RELEASE_CHECK_SCRIPT" ]] || fail "missing pre-release security check script: $PRE_RELEASE_CHECK_SCRIPT"
  echo "running pre-release security check"
  run_cmd env SEPSISCARE_PRE_RELEASE_CHECKED=1 "$BASH_BIN" "$PRE_RELEASE_CHECK_SCRIPT"
}

preflight() {
  echo "checking SSH access to $REMOTE_SERVER_HOST"
  run_cmd "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$REMOTE_SERVER_HOST" true
  echo "ok ssh preflight"
}

sync_package() {
  check_local_package
  audit_runtime_data
  audit_sensitive_data
  echo "syncing model package to $REMOTE_SERVER_HOST:$REMOTE_PACKAGE_DIR/"
  run_cmd "$RSYNC_BIN" -az --info=progress2 \
    --exclude .runtime/ \
    --exclude artifacts/ \
    --exclude .venv/ \
    --exclude __pycache__/ \
    --exclude '*.pyc' \
    "$LOCAL_PACKAGE_DIR/" \
    "$REMOTE_SERVER_HOST:$REMOTE_PACKAGE_DIR/"
}

deploy_remote() {
  local quoted_dir
  local remote_command
  quoted_dir="$(remote_shell_path "$REMOTE_PACKAGE_DIR")"
  remote_command="cd $quoted_dir && SEPSISCARE_MODEL_HOST=$REMOTE_SERVER_MODEL_HOST SEPSISCARE_MODEL_PORT=$REMOTE_SERVER_MODEL_PORT SEPSISCARE_ALLOW_REAL_TRAINING=$SEPSISCARE_ALLOW_REAL_TRAINING bash deploy/remote_server_one_click_deploy.sh restart && bash deploy/remote_server_one_click_deploy.sh smoke"

  echo "starting remote model service on $REMOTE_SERVER_HOST"
  run_cmd "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$REMOTE_SERVER_HOST" "$remote_command"
}

smoke_from_mac() {
  echo "verifying Mac API -> remote server model service"
  run_cmd "$SMOKE_SCRIPT" "$LOCAL_API_URL" "$REMOTE_SERVER_MODEL_URL" --require-model
}

pull_artifacts() {
  local artifact_url
  artifact_url="${REMOTE_SERVER_MODEL_URL%/}/api/artifacts/latest"
  mkdir -p "$LOCAL_ARTIFACT_DIR"
  echo "pulling remote server artifact from $artifact_url"
  if [[ -n "$SEPSISCARE_SERVICE_TOKEN" ]]; then
    run_cmd "$CURL_BIN" --noproxy "*" -fsS --max-time 60 -H "Authorization: Bearer $SEPSISCARE_SERVICE_TOKEN" -o "$ARTIFACT_PATH" "$artifact_url"
  else
    run_cmd "$CURL_BIN" --noproxy "*" -fsS --max-time 60 -o "$ARTIFACT_PATH" "$artifact_url"
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    [[ -s "$ARTIFACT_PATH" ]] || fail "artifact download is empty: $ARTIFACT_PATH"
    if [[ -n "${SEPSISCARE_ARTIFACT_SIGNING_KEY:-}" ]]; then
      run_cmd "$PYTHON_BIN" "$VERIFY_ARTIFACT_SCRIPT" "$ARTIFACT_PATH" --hmac-key-env SEPSISCARE_ARTIFACT_SIGNING_KEY
      echo "verified remote server artifact: $ARTIFACT_PATH"
    fi
  fi
  echo "downloaded remote server artifact: $ARTIFACT_PATH"
}

case "$COMMAND" in
  all)
    pre_release_check
    preflight
    sync_package
    deploy_remote
    smoke_from_mac
    pull_artifacts
    ;;
  preflight)
    preflight
    ;;
  sync)
    sync_package
    ;;
  deploy)
    deploy_remote
    ;;
  smoke)
    smoke_from_mac
    ;;
  pull-artifacts)
    pull_artifacts
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    fail "unknown command: $COMMAND"
    ;;
esac
