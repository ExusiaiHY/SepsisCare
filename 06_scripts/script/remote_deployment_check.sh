#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
CURL_BIN="${CURL_BIN:-curl}"
API_PORT="8765"
MODEL_PORT="8788"
API_URL=""
MODEL_URL=""
REQUIRE_MODEL=1
RUN_SMOKE=1

usage() {
  cat >&2 <<USAGE
usage:
  $0 <target-host-or-ip>
  $0 <api-url> <model-url>
  $0 --host <target-host-or-ip> [--api-port 8765] [--model-port 8788]
  $0 --api-url <url> [--model-url <url>] [--skip-model] [--no-smoke]

Examples:
  $0 192.168.1.20
  $0 http://192.168.1.20:8765 http://192.168.1.20:8788
  $0 --host server.local --api-port 18080 --model-port 18081
  $0 --host fd00::20 --api-port 8765 --model-port 8788
  $0 --api-url http://server.local:8765 --skip-model
USAGE
}

fail() {
  echo "not ok: $*" >&2
  exit 1
}

is_url() {
  [[ "$1" == http://* || "$1" == https://* ]]
}

strip_trailing_slash() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "$value"
}

host_from_url() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  if [[ "$value" == \[*\]* ]]; then
    value="${value#\[}"
    value="${value%%\]*}"
  else
    value="${value%%:*}"
  fi
  printf '%s' "$value"
}

authority_from_url() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  printf '%s' "$value"
}

host_for_url() {
  local host="$1"
  if [[ "$host" == \[*\] ]]; then
    printf '%s' "$host"
  elif [[ "$host" == *:* ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

normalize_url() {
  local target="$1"
  local default_port="$2"
  if is_url "$target"; then
    printf '%s' "$target"
  else
    printf 'http://%s:%s' "$(host_for_url "$target")" "$default_port"
  fi
}

validate_base_url() {
  local name="$1"
  local value="$2"
  local authority
  local host
  if ! is_url "$value"; then
    fail "invalid $name URL: $value"
  fi
  authority="$(authority_from_url "$value")"
  if [[ -z "$authority" || "$authority" == :* ]]; then
    fail "invalid $name URL: $value"
  fi
  if [[ "$authority" != \[* && "$authority" == *:*:* ]]; then
    fail "invalid $name URL: $value"
  fi
  host="$(host_from_url "$value")"
  if [[ -z "$host" ]]; then
    fail "invalid $name URL: $value"
  fi
}

append_no_proxy_host() {
  local host="$1"
  [[ -n "$host" ]] || return 0
  case ",${NO_PROXY:-}," in
    *,"$host",*) ;;
    *) NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,0.0.0.0,::1},$host" ;;
  esac
  export NO_PROXY
  export no_proxy="$NO_PROXY"
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

check_health() {
  local name="$1"
  local base_url="$2"
  local health_url="$base_url/health"

  echo "checking $name: $health_url"
  if "$CURL_BIN" --noproxy "*" -fsS --max-time 5 "$health_url" >/dev/null 2>&1; then
    echo "ok $name health"
    return 0
  fi

  echo "not ok $name health: $health_url" >&2
  echo "hints:" >&2
  echo "  - on the target computer, run: ./script/sepsiscare_services.sh status" >&2
  echo "  - services must bind to 0.0.0.0, not only 127.0.0.1, for remote clients" >&2
  echo "  - check macOS firewall, VPN/LAN routing, target IP, and port $API_PORT/$MODEL_PORT exposure" >&2
  echo "  - from the target computer, verify local health first with curl --noproxy '*' $health_url" >&2
  return 1
}

warn_if_loopback_remote() {
  local api_host
  api_host="$(host_from_url "$API_URL")"
  if [[ "$api_host" == "127.0.0.1" || "$api_host" == "localhost" || "$api_host" == "::1" ]]; then
    echo "warning: API target is loopback ($api_host). This only verifies the current computer, not cross-machine access." >&2
  fi
}

TARGET_HOST=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || fail "--host requires a value"
      TARGET_HOST="$2"
      shift 2
      ;;
    --api-url)
      [[ $# -ge 2 ]] || fail "--api-url requires a value"
      API_URL="$2"
      shift 2
      ;;
    --model-url)
      [[ $# -ge 2 ]] || fail "--model-url requires a value"
      MODEL_URL="$2"
      shift 2
      ;;
    --api-port)
      [[ $# -ge 2 ]] || fail "--api-port requires a value"
      API_PORT="$2"
      shift 2
      ;;
    --model-port)
      [[ $# -ge 2 ]] || fail "--model-port requires a value"
      MODEL_PORT="$2"
      shift 2
      ;;
    --skip-model)
      REQUIRE_MODEL=0
      shift
      ;;
    --no-smoke)
      RUN_SMOKE=0
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -gt 2 ]]; then
  fail "too many target arguments"
fi

if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  if [[ -z "$API_URL" && -z "$TARGET_HOST" ]]; then
    if is_url "${POSITIONAL[0]}"; then
      API_URL="${POSITIONAL[0]}"
    else
      TARGET_HOST="${POSITIONAL[0]}"
    fi
  else
    fail "too many target arguments"
  fi
fi

if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  if [[ -z "$MODEL_URL" ]]; then
    MODEL_URL="$(normalize_url "${POSITIONAL[1]}" "$MODEL_PORT")"
  else
    fail "too many target arguments"
  fi
fi

if [[ -n "$TARGET_HOST" ]]; then
  API_URL="$(normalize_url "$TARGET_HOST" "$API_PORT")"
  MODEL_URL="$(normalize_url "$TARGET_HOST" "$MODEL_PORT")"
fi

if [[ -z "$API_URL" ]]; then
  API_URL="http://127.0.0.1:$API_PORT"
fi

if [[ -z "$MODEL_URL" ]]; then
  MODEL_URL="http://$(host_for_url "$(host_from_url "$API_URL")"):$MODEL_PORT"
fi

validate_base_url "API" "$API_URL"
API_URL="$(strip_trailing_slash "$API_URL")"
validate_base_url "model service" "$MODEL_URL"
MODEL_URL="$(strip_trailing_slash "$MODEL_URL")"

check_command "$CURL_BIN"
append_no_proxy_host "$(host_from_url "$API_URL")"
append_no_proxy_host "$(host_from_url "$MODEL_URL")"

echo "SepsisCare remote deployment preflight"
echo "API URL:   $API_URL"
if [[ "$REQUIRE_MODEL" == "1" ]]; then
  echo "Model URL: $MODEL_URL"
else
  echo "Model URL: $MODEL_URL (health optional)"
fi

warn_if_loopback_remote
check_health "API" "$API_URL"

if [[ "$REQUIRE_MODEL" == "1" ]]; then
  check_health "model service" "$MODEL_URL"
else
  check_health "model service" "$MODEL_URL" || echo "skip model failure because --skip-model was set"
fi

if [[ "$RUN_SMOKE" == "1" ]]; then
  echo "running API smoke via script/smoke_test.sh"
  if [[ "$REQUIRE_MODEL" == "1" ]]; then
    "$SCRIPT_ROOT/smoke_test.sh" "$API_URL" "$MODEL_URL" --require-model
  else
    "$SCRIPT_ROOT/smoke_test.sh" "$API_URL" "$MODEL_URL"
  fi
fi

echo "remote deployment preflight passed"
