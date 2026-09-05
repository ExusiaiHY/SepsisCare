#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export SEPSISCARE_PORT=19865
export SEPSISCARE_MODEL_PORT=19888
export SEPSISCARE_LAUNCH_AGENT_DIR="$TMP_DIR/LaunchAgents"

"$SCRIPT_ROOT/sepsiscare_services.sh" write-agent-plists >/dev/null

API_PLIST="$SEPSISCARE_LAUNCH_AGENT_DIR/care.sepsis.api.19865.plist"
MODEL_PLIST="$SEPSISCARE_LAUNCH_AGENT_DIR/care.sepsis.model.19888.plist"
API_AGENT_LABEL="care.sepsis.api.19865"
MODEL_AGENT_LABEL="care.sepsis.model.19888"

test -f "$API_PLIST"
test -f "$MODEL_PLIST"

grep -q "<string>$API_AGENT_LABEL</string>" "$API_PLIST"
grep -q "<string>$MODEL_AGENT_LABEL</string>" "$MODEL_PLIST"
grep -q "<string>$APPS_ROOT/sepsiscare-studio/backend/server.py</string>" "$API_PLIST"
grep -q "<string>$MODEL_PACKAGE_ROOT/deploy/model_service.py</string>" "$MODEL_PLIST"
grep -q "<key>RunAtLoad</key>" "$API_PLIST"
grep -q "<key>KeepAlive</key>" "$MODEL_PLIST"
grep -q "<key>SEPSISCARE_DEPLOY_ROOT</key>" "$MODEL_PLIST"

STATUS_OUTPUT="$(
  SEPSISCARE_HOST=127.0.0.1 \
  SEPSISCARE_MODEL_HOST=0.0.0.0 \
  "$SCRIPT_ROOT/sepsiscare_services.sh" status
)"

grep -q "Remote access preflight:" <<<"$STATUS_OUTPUT"
grep -q "API bind: 127.0.0.1:19865 (loopback only; remote clients cannot reach this service)" <<<"$STATUS_OUTPUT"
grep -q "Model bind: 0.0.0.0:19888 (remote-capable bind; verify firewall and routing)" <<<"$STATUS_OUTPUT"
grep -q "$SCRIPT_ROOT/remote_deployment_check.sh TARGET_IP" <<<"$STATUS_OUTPUT"

FAKE_LSOF="$TMP_DIR/fake-lsof"
cat >"$FAKE_LSOF" <<'FAKE_LSOF'
#!/usr/bin/env bash
cat <<'LSOF'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
Python  12345 user    4u  IPv4 0xabc      0t0  TCP 127.0.0.1:19865 (LISTEN)
Python  12346 user   11u  IPv4 0xdef      0t0  TCP *:19888 (LISTEN)
LSOF
FAKE_LSOF
chmod +x "$FAKE_LSOF"

ACTUAL_BIND_STATUS_OUTPUT="$(
  SEPSISCARE_HOST=0.0.0.0 \
  SEPSISCARE_MODEL_HOST=0.0.0.0 \
  LSOF_BIN="$FAKE_LSOF" \
  "$SCRIPT_ROOT/sepsiscare_services.sh" status
)"

grep -q "API bind: 127.0.0.1:19865 (loopback only; remote clients cannot reach this service)" <<<"$ACTUAL_BIND_STATUS_OUTPUT"
grep -q "Model bind: 0.0.0.0:19888 (remote-capable bind; verify firewall and routing)" <<<"$ACTUAL_BIND_STATUS_OUTPUT"

FAKE_CURL_FAIL="$TMP_DIR/fake-curl-fail"
cat >"$FAKE_CURL_FAIL" <<'FAKE_CURL_FAIL'
#!/usr/bin/env bash
exit 22
FAKE_CURL_FAIL
chmod +x "$FAKE_CURL_FAIL"

FAKE_PYTHON_MARKER="$TMP_DIR/python-was-started"
FAKE_PYTHON="$TMP_DIR/fake-python"
cat >"$FAKE_PYTHON" <<FAKE_PYTHON
#!/usr/bin/env bash
touch "$FAKE_PYTHON_MARKER"
exit 1
FAKE_PYTHON
chmod +x "$FAKE_PYTHON"

PORT_CONFLICT_OUTPUT="$(
  SEPSISCARE_HOST=0.0.0.0 \
  SEPSISCARE_MODEL_HOST=0.0.0.0 \
  CURL_BIN="$FAKE_CURL_FAIL" \
  LSOF_BIN="$FAKE_LSOF" \
  PYTHON_BIN="$FAKE_PYTHON" \
  "$SCRIPT_ROOT/sepsiscare_services.sh" start 2>&1 || true
)"

grep -q "SepsisCare API port 19865 is already in use but health check failed" <<<"$PORT_CONFLICT_OUTPUT"
grep -q "TCP 127.0.0.1:19865 (LISTEN)" <<<"$PORT_CONFLICT_OUTPUT"
test ! -f "$FAKE_PYTHON_MARKER"

FAKE_PYTHON_AGENT="$TMP_DIR/fake-python-agent"
cat >"$FAKE_PYTHON_AGENT" <<'FAKE_PYTHON_AGENT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" ]]; then
  exit 0
fi
exit 1
FAKE_PYTHON_AGENT
chmod +x "$FAKE_PYTHON_AGENT"

FAKE_LAUNCHCTL_DIR="$TMP_DIR/fake-launchctl-bin"
mkdir -p "$FAKE_LAUNCHCTL_DIR"
FAKE_LAUNCHCTL="$FAKE_LAUNCHCTL_DIR/launchctl"
cat >"$FAKE_LAUNCHCTL" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
case "${1:-}" in
  bootout)
    exit 0
    ;;
  bootstrap)
    echo "Bootstrap failed: 5: Input/output error" >&2
    exit 5
    ;;
  enable|kickstart)
    echo "unexpected launchctl action after bootstrap failure: $1" >&2
    exit 9
    ;;
  *)
    echo "unexpected launchctl action: ${1:-}" >&2
    exit 9
    ;;
esac
FAKE_LAUNCHCTL
chmod +x "$FAKE_LAUNCHCTL"

LAUNCH_AGENT_FAILURE_OUTPUT="$(
  PATH="$FAKE_LAUNCHCTL_DIR:$PATH" \
  PYTHON_BIN="$FAKE_PYTHON_AGENT" \
  "$SCRIPT_ROOT/sepsiscare_services.sh" install-agent 2>&1 || true
)"

grep -q "launchctl bootstrap failed for $API_AGENT_LABEL" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "plist: $API_PLIST" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "Bootstrap failed: 5: Input/output error" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "launchctl print gui/" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "$API_AGENT_LABEL" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "$SCRIPT_ROOT/sepsiscare_services.sh agent-status" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "backend_19865.log" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
grep -q "model_19888.log" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"
! grep -q "unexpected launchctl action after bootstrap failure" <<<"$LAUNCH_AGENT_FAILURE_OUTPUT"

echo "sepsiscare service script tests passed"
