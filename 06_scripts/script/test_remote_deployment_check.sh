#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$ROOT_DIR/script/remote_deployment_check.sh"
UNUSED_URL="http://127.0.0.1:9"

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  [[ "$output" != *"$unexpected"* ]] || fail "expected output not to contain: $unexpected"
}

capture_success() {
  local output
  output="$("$@" 2>&1)" || {
    printf '%s\n' "$output" >&2
    fail "command unexpectedly failed: $*"
  }
  printf '%s' "$output"
}

capture_failure() {
  local output
  if output="$("$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "command unexpectedly succeeded: $*"
  fi
  printf '%s' "$output"
}

help_output="$(capture_success "$CHECK_SCRIPT" --help)"
assert_contains "$help_output" "--skip-model"

too_many_args_output="$(capture_failure "$CHECK_SCRIPT" 127.0.0.1 extra third)"
assert_contains "$too_many_args_output" "too many target arguments"

invalid_api_url_output="$(capture_failure "$CHECK_SCRIPT" --api-url "http://" --no-smoke)"
assert_contains "$invalid_api_url_output" "invalid API URL: http://"

invalid_model_url_output="$(capture_failure "$CHECK_SCRIPT" \
  --api-url "http://127.0.0.1:8765" \
  --model-url "http://" \
  --no-smoke)"
assert_contains "$invalid_model_url_output" "invalid model service URL: http://"

custom_host_ports_output="$(capture_success env CURL_BIN=true "$CHECK_SCRIPT" \
  --host "server.local" \
  --api-port 18080 \
  --model-port 18081 \
  --no-smoke)"
assert_contains "$custom_host_ports_output" "API URL:   http://server.local:18080"
assert_contains "$custom_host_ports_output" "Model URL: http://server.local:18081"
assert_contains "$custom_host_ports_output" "checking API: http://server.local:18080/health"
assert_contains "$custom_host_ports_output" "checking model service: http://server.local:18081/health"

raw_ipv6_host_output="$(capture_success env CURL_BIN=true "$CHECK_SCRIPT" \
  --host "fe80::1" \
  --api-port 18080 \
  --model-port 18081 \
  --no-smoke)"
assert_contains "$raw_ipv6_host_output" "API URL:   http://[fe80::1]:18080"
assert_contains "$raw_ipv6_host_output" "Model URL: http://[fe80::1]:18081"

api_url_ipv6_output="$(capture_success env CURL_BIN=true "$CHECK_SCRIPT" \
  --api-url "http://[fe80::1]:18080" \
  --no-smoke)"
assert_contains "$api_url_ipv6_output" "API URL:   http://[fe80::1]:18080"
assert_contains "$api_url_ipv6_output" "Model URL: http://[fe80::1]:8788"

api_down_output="$(capture_failure "$CHECK_SCRIPT" --api-url "$UNUSED_URL" --model-url "$UNUSED_URL" --no-smoke)"
assert_contains "$api_down_output" "not ok API health"
assert_not_contains "$api_down_output" "remote deployment preflight passed"

optional_model_down_output="$(capture_success "$CHECK_SCRIPT" \
  --api-url "http://127.0.0.1:8765" \
  --model-url "$UNUSED_URL" \
  --skip-model \
  --no-smoke)"
assert_contains "$optional_model_down_output" "skip model failure because --skip-model was set"
assert_contains "$optional_model_down_output" "remote deployment preflight passed"
assert_not_contains "$optional_model_down_output" "curl:"

echo "remote deployment preflight script tests passed"
