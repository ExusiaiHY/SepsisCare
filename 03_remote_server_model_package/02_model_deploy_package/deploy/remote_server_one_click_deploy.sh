#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-start}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_BIN="${CURL_BIN:-curl}"
HOST="${SEPSISCARE_MODEL_HOST:-0.0.0.0}"
PORT="${SEPSISCARE_MODEL_PORT:-8788}"
RUNTIME_ROOT="${SEPSISCARE_RUNTIME_ROOT:-$ROOT_DIR/.runtime}"
ARTIFACT_DIR="${SEPSISCARE_ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
DATABASE_ROOT="${SEPSISCARE_DATABASE_ROOT:-$ROOT_DIR/runtime_data}"
PID_FILE="$RUNTIME_ROOT/model_${PORT}.pid"
LOG_FILE="$RUNTIME_ROOT/model_${PORT}.log"
RUNTIME_DATA_AUDIT_SCRIPT="${SEPSISCARE_RUNTIME_DATA_AUDIT_SCRIPT:-$ROOT_DIR/deploy/audit_runtime_data.py}"
RUNTIME_DATA_AUDIT_REPORT="${SEPSISCARE_RUNTIME_DATA_AUDIT_REPORT:-$RUNTIME_ROOT/runtime_data_audit.json}"
VENV_DIR="$ROOT_DIR/.venv"

usage() {
  cat <<USAGE
usage: $0 [start|stop|restart|status|smoke|doctor|logs]

Environment:
  SEPSISCARE_MODEL_HOST=0.0.0.0
  SEPSISCARE_MODEL_PORT=8788
  SEPSISCARE_ALLOW_REAL_TRAINING=0
  SEPSISCARE_RUNTIME_ROOT=$ROOT_DIR/.runtime
  SEPSISCARE_ARTIFACT_DIR=$ROOT_DIR/artifacts
  SEPSISCARE_DATABASE_ROOT=$ROOT_DIR/runtime_data
  SEPSISCARE_USE_SYSTEM_PYTHON=1   # skip venv, useful for smoke tests
USAGE
}

fail() {
  echo "not ok: $*" >&2
  exit 1
}

loopback_host() {
  if [[ "$HOST" == "0.0.0.0" || "$HOST" == "::" || "$HOST" == "[::]" ]]; then
    echo "127.0.0.1"
  else
    echo "$HOST"
  fi
}

base_url() {
  echo "http://$(loopback_host):$PORT"
}

health_ok() {
  "$CURL_BIN" --noproxy "*" -fsS --max-time 5 "$(base_url)/health" >/dev/null 2>&1
}

audit_runtime_data() {
  [[ -f "$DATABASE_ROOT/history_patients.json" && -f "$DATABASE_ROOT/history_details.json" ]] || return 0
  [[ -f "$RUNTIME_DATA_AUDIT_SCRIPT" ]] || fail "missing runtime data audit script: $RUNTIME_DATA_AUDIT_SCRIPT"
  mkdir -p "$RUNTIME_ROOT"
  if "$PYTHON_BIN" "$RUNTIME_DATA_AUDIT_SCRIPT" "$DATABASE_ROOT" >"$RUNTIME_DATA_AUDIT_REPORT"; then
    local summary
    summary="$("$PYTHON_BIN" - "$RUNTIME_DATA_AUDIT_REPORT" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
summary = data.get("summary", {})
print(f"{summary.get('violations', 0)} fatal violations, {summary.get('warnings', 0)} warnings")
PY
)"
    echo "runtime data audit: ok ($summary)"
  else
    echo "runtime data audit: failed" >&2
    if [[ -s "$RUNTIME_DATA_AUDIT_REPORT" ]]; then
      tail -80 "$RUNTIME_DATA_AUDIT_REPORT" >&2 || true
    fi
    exit 1
  fi
}

wait_until_healthy() {
  for _ in $(seq 1 60); do
    if health_ok; then
      echo "online: $(base_url)/health"
      return 0
    fi
    sleep 1
  done
  echo "model server did not become healthy: $(base_url)/health" >&2
  if [[ -f "$LOG_FILE" ]]; then
    echo "--- $LOG_FILE tail ---" >&2
    tail -120 "$LOG_FILE" >&2 || true
  fi
  return 1
}

python_for_service() {
  if [[ "${SEPSISCARE_USE_SYSTEM_PYTHON:-}" == "1" ]]; then
    echo "$PYTHON_BIN"
    return 0
  fi

  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "creating virtualenv: $VENV_DIR" >&2
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  echo "installing model server requirements" >&2
  "$VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
  "$VENV_DIR/bin/python" -m pip install -r "$ROOT_DIR/deploy/requirements_model_deploy.txt" >/dev/null
  echo "$VENV_DIR/bin/python"
}

required_model_files=(
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder.pt"
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/phenotype_readout.pkl"
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/transition_probs.npy"
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/transition_init_probs.npy"
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder_report.json"
  "$ROOT_DIR/models/cloud_production/s7_phenotype_contrastive_full_20260516/s7_all_source_training_summary.json"
)

doctor() {
  local missing=0
  for path in "${required_model_files[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "missing model file: $path" >&2
      missing=1
    fi
  done
  if [[ "$missing" == "0" ]]; then
    echo "model files: ok"
  else
    echo "model files: missing" >&2
  fi

  if [[ -f "$DATABASE_ROOT/history_patients.json" && -f "$DATABASE_ROOT/history_details.json" ]]; then
    echo "database: ok ($DATABASE_ROOT)"
    audit_runtime_data
  else
    echo "database: generated fallback (missing $DATABASE_ROOT/history_patients.json or history_details.json)"
  fi

  command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "missing python: $PYTHON_BIN"
  echo "python: $(command -v "$PYTHON_BIN")"
  echo "bind: $HOST:$PORT"
  echo "health: $(base_url)/health"
  [[ "$missing" == "0" ]] || exit 1
}

pid_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

start() {
  mkdir -p "$RUNTIME_ROOT" "$ARTIFACT_DIR"
  doctor >/dev/null
  if health_ok; then
    echo "already online: $(base_url)/health"
    return 0
  fi

  local service_python
  service_python="$(python_for_service)"
  echo "starting remote server SepsisCare model server on http://$HOST:$PORT"
  nohup env \
    SEPSISCARE_DEPLOY_ROOT="$ROOT_DIR" \
    SEPSISCARE_MODEL_HOST="$HOST" \
    SEPSISCARE_MODEL_PORT="$PORT" \
    SEPSISCARE_RUNTIME_ROOT="$RUNTIME_ROOT" \
    SEPSISCARE_ARTIFACT_DIR="$ARTIFACT_DIR" \
    SEPSISCARE_DATABASE_ROOT="$DATABASE_ROOT" \
    SEPSISCARE_ALLOW_REAL_TRAINING="${SEPSISCARE_ALLOW_REAL_TRAINING:-0}" \
    "$service_python" "$ROOT_DIR/deploy/model_service.py" --host "$HOST" --port "$PORT" \
    >"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
  wait_until_healthy
  echo "log: $LOG_FILE"
}

stop() {
  if ! pid_running; then
    rm -f "$PID_FILE"
    echo "model server not managed by pid file: $PID_FILE"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  echo "stopping model server pid=$pid"
  kill "$pid" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$PID_FILE"
      return 0
    fi
    sleep 0.2
  done
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
}

status() {
  if health_ok; then
    echo "online: $(base_url)/health"
  else
    echo "offline: $(base_url)/health"
  fi
  if pid_running; then
    echo "managed pid: $(cat "$PID_FILE")"
  else
    echo "managed pid: none"
  fi
  echo "database: $DATABASE_ROOT"
  echo "artifacts: $ARTIFACT_DIR"
  echo "log: $LOG_FILE"
}

smoke() {
  "$PYTHON_BIN" - "$(base_url)" <<'PY'
import json
import os
import sys
import urllib.request

base = sys.argv[1].rstrip("/")
token = (os.environ.get("SEPSISCARE_SERVICE_TOKEN") or os.environ.get("SEPSISCARE_TRAINING_TOKEN") or "").strip()

def request(method, path, payload=None):
    data = None
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=12) as response:
        body = response.read()
        if response.headers.get_content_type() == "application/json":
            return json.loads(body.decode("utf-8"))
        return body

checks = [
    ("GET", "/health", None, "ok"),
    ("GET", "/api/patients?page=1&per_page=3", None, "patients"),
    ("GET", "/api/history/patients?page=1&per_page=3", None, "patients"),
    ("GET", "/api/training-terminal/status", None, "model_profile"),
    ("GET", "/predict/predict", None, "method"),
    ("POST", "/predict/predict", {"vitals": {"map": 68}, "labs": {"lactate": 3.2}}, "latest"),
    ("POST", "/api/training-terminal/action", {"action": "stream_metrics"}, "cloud_response"),
    ("POST", "/api/training/command", {"action": "download_artifacts"}, "artifacts"),
]
for method, path, payload, key in checks:
    result = request(method, path, payload)
    if not isinstance(result, dict) or key not in result:
        raise SystemExit(f"not ok {method} {path}: missing {key}")
    print(f"ok {method} {path}")
artifact = request("GET", "/api/artifacts/latest")
if len(artifact) < 100:
    raise SystemExit("not ok GET /api/artifacts/latest: artifact too small")
print("ok GET /api/artifacts/latest")
PY
}

case "$COMMAND" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  status)
    status
    ;;
  smoke)
    smoke
    ;;
  doctor)
    doctor
    ;;
  logs)
    touch "$LOG_FILE"
    tail -f "$LOG_FILE"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
