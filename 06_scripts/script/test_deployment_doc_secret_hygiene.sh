#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || fail "expected $path to contain: $expected"
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then
    grep -Fn -- "$unexpected" "$path" >&2 || true
    fail "expected $path not to contain literal token placeholder: $unexpected"
  fi
}

DOCS=(
  "$TRANSFER_README"
  "$MODEL_PACKAGE_ROOT/README_DEPLOY.md"
  "$MODEL_PACKAGE_ROOT/deploy/README_DEPLOY.md"
)

for doc in "${DOCS[@]}"; do
  assert_file_not_contains "$doc" "同一个token"
  assert_file_not_contains "$doc" "Authorization: Bearer 同一个token"
  assert_file_not_contains "$doc" "SEPSISCARE_SERVICE_TOKEN=同一个token"
  assert_file_contains "$doc" "shell history"
  assert_file_contains "$doc" "at least 16 characters"
done

assert_file_contains "$TRANSFER_README" 'export SEPSISCARE_SERVICE_TOKEN="$(openssl rand -hex 24)"'
assert_file_contains "$TRANSFER_README" 'SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" ./script/smoke_test.sh'
assert_file_contains "$TRANSFER_README" 'Authorization: Bearer $SEPSISCARE_SERVICE_TOKEN'
assert_file_contains "$TRANSFER_README" 'unset SEPSISCARE_SERVICE_TOKEN'

echo "deployment doc secret hygiene tests passed"
