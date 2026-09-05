#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/deploy/remote_server_one_click_deploy.sh"
TEST_RUNTIME="$(mktemp -d /tmp/sepsiscare-remote-server-one-click.XXXXXX)"
PORT="${SEPSISCARE_TEST_REMOTE_SERVER_PORT:-19888}"

cleanup() {
  SEPSISCARE_MODEL_HOST=127.0.0.1 \
  SEPSISCARE_MODEL_PORT="$PORT" \
  SEPSISCARE_RUNTIME_ROOT="$TEST_RUNTIME" \
  SEPSISCARE_ARTIFACT_DIR="$TEST_RUNTIME/artifacts" \
  SEPSISCARE_USE_SYSTEM_PYTHON=1 \
  "$DEPLOY_SCRIPT" stop >/dev/null 2>&1 || true
  rm -rf "$TEST_RUNTIME"
}
trap cleanup EXIT

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

[[ -x "$DEPLOY_SCRIPT" ]] || fail "missing executable deploy script: $DEPLOY_SCRIPT"

help_output="$("$DEPLOY_SCRIPT" --help)"
assert_contains "$help_output" "start|stop|restart|status|smoke|doctor|logs"

doctor_output="$(
  SEPSISCARE_MODEL_HOST=127.0.0.1 \
  SEPSISCARE_MODEL_PORT="$PORT" \
  SEPSISCARE_RUNTIME_ROOT="$TEST_RUNTIME" \
  SEPSISCARE_ARTIFACT_DIR="$TEST_RUNTIME/artifacts" \
  SEPSISCARE_USE_SYSTEM_PYTHON=1 \
  "$DEPLOY_SCRIPT" doctor
)"
assert_contains "$doctor_output" "model files: ok"
assert_contains "$doctor_output" "database: ok"
assert_contains "$doctor_output" "runtime data audit: ok"

SEPSISCARE_MODEL_HOST=127.0.0.1 \
SEPSISCARE_MODEL_PORT="$PORT" \
SEPSISCARE_RUNTIME_ROOT="$TEST_RUNTIME" \
SEPSISCARE_ARTIFACT_DIR="$TEST_RUNTIME/artifacts" \
SEPSISCARE_USE_SYSTEM_PYTHON=1 \
"$DEPLOY_SCRIPT" restart

status_output="$(
  SEPSISCARE_MODEL_HOST=127.0.0.1 \
  SEPSISCARE_MODEL_PORT="$PORT" \
  SEPSISCARE_RUNTIME_ROOT="$TEST_RUNTIME" \
  SEPSISCARE_ARTIFACT_DIR="$TEST_RUNTIME/artifacts" \
  SEPSISCARE_USE_SYSTEM_PYTHON=1 \
  "$DEPLOY_SCRIPT" status
)"
assert_contains "$status_output" "online: http://127.0.0.1:$PORT/health"

SEPSISCARE_MODEL_HOST=127.0.0.1 \
SEPSISCARE_MODEL_PORT="$PORT" \
SEPSISCARE_RUNTIME_ROOT="$TEST_RUNTIME" \
SEPSISCARE_ARTIFACT_DIR="$TEST_RUNTIME/artifacts" \
SEPSISCARE_USE_SYSTEM_PYTHON=1 \
"$DEPLOY_SCRIPT" smoke

echo "remote server one-click deploy script tests passed"
