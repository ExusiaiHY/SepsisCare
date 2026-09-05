#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-status}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CURL_BIN="${CURL_BIN:-curl}"
LSOF_BIN="${LSOF_BIN:-lsof}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,0.0.0.0,::1}"
export no_proxy="${no_proxy:-$NO_PROXY}"

API_HOST="${SEPSISCARE_HOST:-127.0.0.1}"
API_PORT="${SEPSISCARE_PORT:-8765}"
MODEL_HOST="${SEPSISCARE_MODEL_HOST:-0.0.0.0}"
MODEL_PORT="${SEPSISCARE_MODEL_PORT:-8788}"

RUNTIME_DIR="$ROOT_DIR/.sepsiscare-runtime/services"
LOG_DIR="$ROOT_DIR/.sepsiscare-runtime/logs"
BACKEND_PID_FILE="$RUNTIME_DIR/backend_${API_PORT}.pid"
MODEL_PID_FILE="$RUNTIME_DIR/model_${MODEL_PORT}.pid"
BACKEND_LOG="$LOG_DIR/backend_${API_PORT}.log"
MODEL_LOG="$LOG_DIR/model_${MODEL_PORT}.log"
MODEL_ROOT="$MODEL_PACKAGE_ROOT"
BACKEND_SERVER="$APPS_ROOT/sepsiscare-studio/backend/server.py"
LAUNCH_AGENT_DIR="${SEPSISCARE_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
API_AGENT_LABEL="${SEPSISCARE_API_AGENT_LABEL:-care.sepsis.api.${API_PORT}}"
MODEL_AGENT_LABEL="${SEPSISCARE_MODEL_AGENT_LABEL:-care.sepsis.model.${MODEL_PORT}}"
API_AGENT_PLIST="$LAUNCH_AGENT_DIR/$API_AGENT_LABEL.plist"
MODEL_AGENT_PLIST="$LAUNCH_AGENT_DIR/$MODEL_AGENT_LABEL.plist"

mkdir -p "$RUNTIME_DIR" "$LOG_DIR"

usage() {
  cat >&2 <<USAGE
usage: $0 [start|stop|restart|status|smoke|logs|write-agent-plists|install-agent|uninstall-agent|agent-status]

Environment:
  SEPSISCARE_HOST=127.0.0.1
  SEPSISCARE_PORT=8765
  SEPSISCARE_MODEL_HOST=0.0.0.0
  SEPSISCARE_MODEL_PORT=8788
  PYTHON_BIN=python3
  SEPSISCARE_LAUNCH_AGENT_DIR=$HOME/Library/LaunchAgents
USAGE
}

fail() {
  echo "not ok: $*" >&2
  exit 1
}

loopback_host() {
  local host="$1"
  if [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]]; then
    echo "127.0.0.1"
  else
    echo "$host"
  fi
}

api_base_url() {
  echo "http://$(loopback_host "$API_HOST"):$API_PORT"
}

model_base_url() {
  echo "http://$(loopback_host "$MODEL_HOST"):$MODEL_PORT"
}

health_ok() {
  local url="$1"
  "$CURL_BIN" --noproxy "*" -fsS --max-time 3 "$url" >/dev/null 2>&1
}

listener_line_for_port() {
  local port="$1"
  local line
  while IFS= read -r line; do
    [[ "$line" == *"TCP "*":$port (LISTEN)"* ]] || continue
    printf '%s\n' "$line"
    return 0
  done < <("$LSOF_BIN" -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  return 1
}

port_conflict_if_unhealthy() {
  local name="$1"
  local port="$2"
  local url="$3"
  local listener
  listener="$(listener_line_for_port "$port" || true)"
  [[ -n "$listener" ]] || return 1

  echo "$name port $port is already in use but health check failed: $url" >&2
  echo "Listener holding the port:" >&2
  echo "$listener" >&2
  echo "Hints:" >&2
  echo "  - run: $0 status" >&2
  echo "  - if this is a stale process, stop it or choose another SEPSISCARE_PORT/SEPSISCARE_MODEL_PORT" >&2
  echo "  - if this should be SepsisCare, inspect the log path printed by status and retry after it becomes healthy" >&2
  return 0
}

wait_until_healthy() {
  local name="$1"
  local url="$2"
  local log_file="$3"
  local attempts="${4:-60}"

  for _ in $(seq 1 "$attempts"); do
    if health_ok "$url"; then
      echo "$name healthy: $url"
      return 0
    fi
    sleep 1
  done

  echo "$name did not become healthy: $url" >&2
  if [[ -f "$log_file" ]]; then
    echo "--- $log_file tail ---" >&2
    tail -80 "$log_file" >&2 || true
  fi
  return 1
}

pid_running() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

start_backend() {
  local url
  url="$(api_base_url)/health"
  if health_ok "$url"; then
    echo "SepsisCare API already healthy: $url"
    return 0
  fi
  if port_conflict_if_unhealthy "SepsisCare API" "$API_PORT" "$url"; then
    return 1
  fi

  echo "Starting SepsisCare API on http://$API_HOST:$API_PORT"
  nohup env \
  SEPSISCARE_DEPLOY_ROOT="$MODEL_ROOT" \
  "$PYTHON_BIN" "$BACKEND_SERVER" \
    --host "$API_HOST" \
    --port "$API_PORT" \
    >"$BACKEND_LOG" 2>&1 &
  echo "$!" >"$BACKEND_PID_FILE"
  wait_until_healthy "SepsisCare API" "$url" "$BACKEND_LOG"
}

model_python() {
  if "$PYTHON_BIN" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    echo "$PYTHON_BIN"
    return 0
  fi

  local venv_python="$MODEL_ROOT/.venv/bin/python"
  if [[ ! -x "$venv_python" ]]; then
    echo "Creating model service virtualenv at $MODEL_ROOT/.venv" >&2
    "$PYTHON_BIN" -m venv "$MODEL_ROOT/.venv"
  fi

  echo "Installing model service requirements" >&2
  "$venv_python" -m pip install --upgrade pip >/dev/null
  "$venv_python" -m pip install -r "$MODEL_ROOT/deploy/requirements_model_deploy.txt" >/dev/null
  echo "$venv_python"
}

python_executable_path() {
  local resolved
  resolved="$(command -v "$PYTHON_BIN" 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    echo "$resolved"
  else
    echo "$PYTHON_BIN"
  fi
}

model_python_for_agent() {
  if "$PYTHON_BIN" -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    python_executable_path
    return 0
  fi

  echo "$MODEL_ROOT/.venv/bin/python"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

write_api_agent_plist() {
  local python_path
  python_path="$(python_executable_path)"
  cat >"$API_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$API_AGENT_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$python_path")</string>
    <string>$(xml_escape "$BACKEND_SERVER")</string>
    <string>--host</string>
    <string>$(xml_escape "$API_HOST")</string>
    <string>--port</string>
    <string>$(xml_escape "$API_PORT")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$ROOT_DIR")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NO_PROXY</key>
    <string>$(xml_escape "$NO_PROXY")</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
    <key>SEPSISCARE_DEPLOY_ROOT</key>
    <string>$(xml_escape "$MODEL_ROOT")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$BACKEND_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$BACKEND_LOG")</string>
</dict>
</plist>
PLIST
}

write_model_agent_plist() {
  local python_path
  python_path="$(model_python_for_agent)"
  cat >"$MODEL_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$MODEL_AGENT_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$python_path")</string>
    <string>$(xml_escape "$MODEL_ROOT/deploy/model_service.py")</string>
    <string>--host</string>
    <string>$(xml_escape "$MODEL_HOST")</string>
    <string>--port</string>
    <string>$(xml_escape "$MODEL_PORT")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$MODEL_ROOT")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NO_PROXY</key>
    <string>$(xml_escape "$NO_PROXY")</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
    <key>SEPSISCARE_DEPLOY_ROOT</key>
    <string>$(xml_escape "$MODEL_ROOT")</string>
    <key>SEPSISCARE_MODEL_HOST</key>
    <string>$(xml_escape "$MODEL_HOST")</string>
    <key>SEPSISCARE_MODEL_PORT</key>
    <string>$(xml_escape "$MODEL_PORT")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$MODEL_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$MODEL_LOG")</string>
</dict>
</plist>
PLIST
}

write_agent_plists() {
  mkdir -p "$LAUNCH_AGENT_DIR"
  write_api_agent_plist
  write_model_agent_plist
  echo "Wrote LaunchAgent plist: $API_AGENT_PLIST"
  echo "Wrote LaunchAgent plist: $MODEL_AGENT_PLIST"
}

launchctl_domain() {
  echo "gui/$(id -u)"
}

launchctl_failure_diagnostics() {
  local action="$1"
  local label="$2"
  local plist="$3"
  local output="$4"
  local domain
  domain="$(launchctl_domain)"

  echo "not ok: launchctl $action failed for $label" >&2
  echo "plist: $plist" >&2
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  fi
  echo "Hints:" >&2
  echo "  - run: $0 agent-status" >&2
  echo "  - run: launchctl print $domain/$label" >&2
  echo "  - inspect logs: $BACKEND_LOG" >&2
  echo "  - inspect logs: $MODEL_LOG" >&2
}

launchctl_checked() {
  local action="$1"
  local label="$2"
  local plist="$3"
  shift 3

  local output status
  if output="$("$LAUNCHCTL_BIN" "$@" 2>&1)"; then
    if [[ -n "$output" ]]; then
      echo "$output"
    fi
    return 0
  else
    status=$?
  fi

  launchctl_failure_diagnostics "$action" "$label" "$plist" "$output"
  return "$status"
}

install_one_agent() {
  local label="$1"
  local plist="$2"
  local domain
  domain="$(launchctl_domain)"
  "$LAUNCHCTL_BIN" bootout "$domain/$label" >/dev/null 2>&1 || true
  launchctl_checked "bootstrap" "$label" "$plist" bootstrap "$domain" "$plist"
  launchctl_checked "enable" "$label" "$plist" enable "$domain/$label"
  launchctl_checked "kickstart" "$label" "$plist" kickstart -k "$domain/$label"
}

install_agents() {
  model_python >/dev/null
  write_agent_plists
  install_one_agent "$API_AGENT_LABEL" "$API_AGENT_PLIST"
  install_one_agent "$MODEL_AGENT_LABEL" "$MODEL_AGENT_PLIST"
  wait_until_healthy "SepsisCare API" "$(api_base_url)/health" "$BACKEND_LOG"
  wait_until_healthy "SepsisCare model service" "$(model_base_url)/health" "$MODEL_LOG"
  agent_status
}

uninstall_one_agent() {
  local label="$1"
  local plist="$2"
  local domain
  domain="$(launchctl_domain)"
  "$LAUNCHCTL_BIN" bootout "$domain/$label" >/dev/null 2>&1 || true
  rm -f "$plist"
}

uninstall_agents() {
  uninstall_one_agent "$MODEL_AGENT_LABEL" "$MODEL_AGENT_PLIST"
  uninstall_one_agent "$API_AGENT_LABEL" "$API_AGENT_PLIST"
  echo "Removed LaunchAgent plists from $LAUNCH_AGENT_DIR"
}

agent_status_one() {
  local label="$1"
  local plist="$2"
  local domain
  domain="$(launchctl_domain)"
  if "$LAUNCHCTL_BIN" print "$domain/$label" >/dev/null 2>&1; then
    echo "$label: loaded, $plist"
  elif [[ -f "$plist" ]]; then
    echo "$label: plist exists but is not loaded, $plist"
  else
    echo "$label: not installed, $plist"
  fi
}

agent_status() {
  agent_status_one "$API_AGENT_LABEL" "$API_AGENT_PLIST"
  agent_status_one "$MODEL_AGENT_LABEL" "$MODEL_AGENT_PLIST"
  status_services
}

start_model() {
  local url
  url="$(model_base_url)/health"
  if health_ok "$url"; then
    echo "SepsisCare model service already healthy: $url"
    return 0
  fi
  if port_conflict_if_unhealthy "SepsisCare model service" "$MODEL_PORT" "$url"; then
    return 1
  fi

  local python_for_model
  python_for_model="$(model_python)"
  echo "Starting SepsisCare model service on http://$MODEL_HOST:$MODEL_PORT"
  nohup env \
  SEPSISCARE_DEPLOY_ROOT="$MODEL_ROOT" \
  SEPSISCARE_MODEL_HOST="$MODEL_HOST" \
  SEPSISCARE_MODEL_PORT="$MODEL_PORT" \
  "$python_for_model" "$MODEL_ROOT/deploy/model_service.py" \
    --host "$MODEL_HOST" \
    --port "$MODEL_PORT" \
    >"$MODEL_LOG" 2>&1 &
  echo "$!" >"$MODEL_PID_FILE"
  wait_until_healthy "SepsisCare model service" "$url" "$MODEL_LOG"
}

start_services() {
  start_backend
  start_model
  status_services
}

stop_pid_file() {
  local name="$1"
  local pid_file="$2"
  if ! [[ -f "$pid_file" ]]; then
    echo "$name pid file not found: $pid_file"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    echo "$name pid file was empty."
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "Stopping $name pid=$pid"
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  else
    echo "$name pid=$pid is not running."
  fi
  rm -f "$pid_file"
}

stop_services() {
  stop_pid_file "SepsisCare model service" "$MODEL_PID_FILE"
  stop_pid_file "SepsisCare API" "$BACKEND_PID_FILE"
}

status_one() {
  local name="$1"
  local url="$2"
  local pid_file="$3"
  if health_ok "$url"; then
    if pid_running "$pid_file"; then
      echo "$name: online, managed pid=$(cat "$pid_file"), $url"
    else
      echo "$name: online, external/unmanaged, $url"
    fi
  else
    echo "$name: offline, $url"
  fi
}

bind_access_note() {
  local host="$1"
  if [[ "$host" == "127.0.0.1" || "$host" == "localhost" || "$host" == "::1" || "$host" == "[::1]" ]]; then
    echo "loopback only; remote clients cannot reach this service"
  elif [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]]; then
    echo "remote-capable bind; verify firewall and routing"
  else
    echo "specific-interface bind; verify clients use the matching target IP"
  fi
}

listener_host_for_port() {
  local port="$1"
  local line endpoint host
  line="$(listener_line_for_port "$port" || true)"
  [[ -n "$line" ]] || return 1
  endpoint="${line% (LISTEN)}"
  endpoint="${endpoint##*TCP }"
  endpoint="${endpoint%% *}"
  host="${endpoint%:$port}"
  host="${host#[}"
  host="${host%]}"
  if [[ "$host" == "*" ]]; then
    echo "0.0.0.0"
  else
    echo "$host"
  fi
}

effective_bind_host() {
  local configured_host="$1"
  local port="$2"
  local actual_host
  actual_host="$(listener_host_for_port "$port" || true)"
  if [[ -n "$actual_host" ]]; then
    echo "$actual_host"
  else
    echo "$configured_host"
  fi
}

status_remote_access() {
  local api_bind_host model_bind_host
  api_bind_host="$(effective_bind_host "$API_HOST" "$API_PORT")"
  model_bind_host="$(effective_bind_host "$MODEL_HOST" "$MODEL_PORT")"
  echo "Remote access preflight:"
  echo "  API bind: $api_bind_host:$API_PORT ($(bind_access_note "$api_bind_host"))"
  echo "  Model bind: $model_bind_host:$MODEL_PORT ($(bind_access_note "$model_bind_host"))"
  echo "  Target services should bind to 0.0.0.0 for another computer to connect."
  echo "  Check macOS firewall, VPN/LAN routing, target IP, and exposed ports $API_PORT/$MODEL_PORT."
  echo "  From the client computer, run: $SCRIPT_ROOT/remote_deployment_check.sh TARGET_IP"
}

status_services() {
  status_one "SepsisCare API" "$(api_base_url)/health" "$BACKEND_PID_FILE"
  status_one "SepsisCare model service" "$(model_base_url)/health" "$MODEL_PID_FILE"
  echo "Backend log: $BACKEND_LOG"
  echo "Model log:   $MODEL_LOG"
  status_remote_access
}

smoke_services() {
  SEPSISCARE_API_BASE_URL="$(api_base_url)" \
  SEPSISCARE_MODEL_BASE_URL="$(model_base_url)" \
  "$SCRIPT_ROOT/smoke_test.sh" --require-model
}

logs_services() {
  echo "Following logs. Press Ctrl-C to stop tailing."
  touch "$BACKEND_LOG" "$MODEL_LOG"
  tail -f "$BACKEND_LOG" "$MODEL_LOG"
}

case "$COMMAND" in
  start)
    start_services
    ;;
  stop)
    stop_services
    ;;
  restart)
    stop_services
    start_services
    ;;
  status)
    status_services
    ;;
  smoke)
    smoke_services
    ;;
  logs)
    logs_services
    ;;
  write-agent-plists)
    write_agent_plists
    ;;
  install-agent)
    install_agents
    ;;
  uninstall-agent)
    uninstall_agents
    ;;
  agent-status)
    agent_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
