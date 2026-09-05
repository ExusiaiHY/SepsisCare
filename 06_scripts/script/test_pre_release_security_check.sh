#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
CHECK_SCRIPT="$SCRIPT_ROOT/pre_release_security_check.sh"

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || {
    echo "--- $path ---" >&2
    cat "$path" >&2
    fail "expected $path to contain: $expected"
  }
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then
    echo "--- $path ---" >&2
    cat "$path" >&2
    fail "expected $path not to contain: $unexpected"
  fi
}

capture_success() {
  local output
  output="$("$@" 2>&1)" || {
    printf '%s\n' "$output" >&2
    fail "command unexpectedly failed: $*"
  }
  printf '%s' "$output"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sepsiscare-pre-release-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CALL_LOG="$TMP_DIR/calls.log"
export CALL_LOG

cat >"$TMP_DIR/fake-python" <<'SH'
#!/usr/bin/env bash
echo "python $(pwd) $*" >> "$CALL_LOG"
if [[ "$*" == *"audit_sensitive_data.py"* && "${FAIL_SENSITIVE_AUDIT:-0}" == "1" ]]; then
  echo "sensitive data audit failed" >&2
  exit 1
fi
if [[ "$*" == *"audit_runtime_data.py"* ]]; then
  printf '{"ok": true, "summary": {"violations": 0, "warnings": 1}}\n'
fi
if [[ "$*" == *"audit_sensitive_data.py"* ]]; then
  printf '{"ok": true, "roots": ["a", "b"], "summary": {"findings": 0}}\n'
fi
if [[ "$*" == *"audit_training_data_integrity.py"* ]]; then
  printf '{"ok": true, "summary": {"violations": 0, "sources": 4}}\n'
fi
SH
chmod +x "$TMP_DIR/fake-python"

cat >"$TMP_DIR/fake-bash" <<'SH'
#!/usr/bin/env bash
echo "bash $(pwd) $*" >> "$CALL_LOG"
SH
chmod +x "$TMP_DIR/fake-bash"

cat >"$TMP_DIR/fake-swift" <<'SH'
#!/usr/bin/env bash
echo "swift $(pwd) $*" >> "$CALL_LOG"
SH
chmod +x "$TMP_DIR/fake-swift"

check_output="$(capture_success env \
  PYTHON_BIN="$TMP_DIR/fake-python" \
  BASH_BIN="$TMP_DIR/fake-bash" \
  SWIFT_BIN="$TMP_DIR/fake-swift" \
  "$CHECK_SCRIPT")"

assert_contains "$check_output" "pre-release security check completed"
assert_contains "$check_output" "audit summary: ok=True violations=0 warnings=1"
assert_contains "$check_output" "audit summary: ok=True findings=0 roots=2"
assert_contains "$check_output" "audit summary: ok=True violations=0"
[[ "$check_output" != *'"warnings"'* ]] || fail "expected audit JSON to be saved, not printed inline"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $SCRIPT_ROOT/test_runtime_data_audit.py"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $SCRIPT_ROOT/test_sensitive_data_audit.py"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $SCRIPT_ROOT/test_training_data_integrity_audit.py"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR $SCRIPT_ROOT/audit_runtime_data.py $MODEL_PACKAGE_ROOT/runtime_data"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR $SCRIPT_ROOT/audit_runtime_data.py $APPS_ROOT/sepsiscare-studio/backend/runtime_data"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR $SCRIPT_ROOT/audit_sensitive_data.py $MODEL_PACKAGE_ROOT $APPS_ROOT/sepsiscare-studio/backend $APPS_ROOT/sepsiscare-web-client $APPS_ROOT/SepsisCare-Windows/renderer/web $APPS_ROOT/SepsisCare-iOS/Resources/Web $APPS_ROOT/SepsisCare-Android/app/src/main/assets/web"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR $SCRIPT_ROOT/audit_training_data_integrity.py $MODEL_PACKAGE_ROOT"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $MODEL_PACKAGE_ROOT/deploy/test_model_service.py"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $MODEL_PACKAGE_ROOT/deploy/test_verify_artifact_bundle.py"
assert_file_contains "$CALL_LOG" "python $ROOT_DIR -m unittest $ROOT_DIR/06_scripts/rog_actual_training_update/test_send_rog_remote_ops_command.py"
assert_file_contains "$CALL_LOG" "python $APPS_ROOT/sepsiscare-studio/backend -m unittest test_server.py"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_web_auth_token.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_demo_auth_boundary.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_web_content_escape.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_web_syntax.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_deployment_doc_secret_hygiene.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_deploy_model_to_remote_server.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/test_sepsiscare_services.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $MODEL_PACKAGE_ROOT/deploy/test_remote_server_one_click_deploy.sh"
assert_file_contains "$CALL_LOG" "bash $ROOT_DIR $SCRIPT_ROOT/build_rog_actual_training_update.sh $SECURITY_REPORT_DIR_DEFAULT/rog_actual_training_update_check.zip"
assert_file_contains "$CALL_LOG" "swift $PRIMARY_MACOS_ROOT build"
assert_file_contains "$CALL_LOG" "swift $MIRROR_MACOS_ROOT build"

: > "$CALL_LOG"
failed_output="$(
  env \
    PYTHON_BIN="$TMP_DIR/fake-python" \
    BASH_BIN="$TMP_DIR/fake-bash" \
    SWIFT_BIN="$TMP_DIR/fake-swift" \
    FAIL_SENSITIVE_AUDIT=1 \
    "$CHECK_SCRIPT" 2>&1 || true
)"
assert_contains "$failed_output" "audit: release files sensitive data"
assert_contains "$failed_output" "sensitive data audit failed"
assert_file_not_contains "$CALL_LOG" "test_model_service.py"

echo "pre-release security check script tests passed"
