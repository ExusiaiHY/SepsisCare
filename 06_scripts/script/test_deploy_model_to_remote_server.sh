#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
DEPLOY_SCRIPT="$SCRIPT_ROOT/deploy_model_to_remote_server.sh"

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

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || {
    echo "--- $path ---" >&2
    cat "$path" >&2
    fail "expected $path to contain: $expected"
  }
}

capture_success() {
  local output
  output="$("$@" 2>&1)" || {
    printf '%s\n' "$output" >&2
    fail "command unexpectedly failed: $*"
  }
  printf '%s' "$output"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sepsiscare-remote-server-deploy-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
CALL_LOG="$TMP_DIR/calls.log"
export CALL_LOG

cat >"$TMP_DIR/fake-ssh" <<'SH'
#!/usr/bin/env bash
if [[ -n "${REQUIRE_OVERRIDE_AUDIT_LOG:-}" && ! -s "$REQUIRE_OVERRIDE_AUDIT_LOG" ]]; then
  echo "missing override audit before ssh" >&2
  exit 1
fi
echo "ssh $*" >> "$CALL_LOG"
SH
chmod +x "$TMP_DIR/fake-ssh"

cat >"$TMP_DIR/fake-rsync" <<'SH'
#!/usr/bin/env bash
echo "rsync $*" >> "$CALL_LOG"
SH
chmod +x "$TMP_DIR/fake-rsync"

cat >"$TMP_DIR/fake-curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$CALL_LOG"
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$out" ]]; then
  mkdir -p "$(dirname "$out")"
  printf 'zip-bytes' > "$out"
fi
SH
chmod +x "$TMP_DIR/fake-curl"

cat >"$TMP_DIR/fake-smoke" <<'SH'
#!/usr/bin/env bash
echo "smoke $*" >> "$CALL_LOG"
SH
chmod +x "$TMP_DIR/fake-smoke"

cat >"$TMP_DIR/fake-python" <<'SH'
#!/usr/bin/env bash
echo "python $*" >> "$CALL_LOG"
if [[ "$*" == *"audit_runtime_data.py"* && "${FAIL_AUDIT:-0}" == "1" ]]; then
  echo "runtime data audit failed" >&2
  exit 1
fi
if [[ "$*" == *"audit_sensitive_data.py"* && "${FAIL_SENSITIVE_AUDIT:-0}" == "1" ]]; then
  echo "sensitive data audit failed" >&2
  exit 1
fi
SH
chmod +x "$TMP_DIR/fake-python"

cat >"$TMP_DIR/fake-bash" <<'SH'
#!/usr/bin/env bash
echo "bash $*" >> "$CALL_LOG"
if [[ "$*" == *"pre_release_security_check.sh"* && "${FAIL_PRE_RELEASE_CHECK:-0}" == "1" ]]; then
  echo "pre-release security check failed" >&2
  exit 1
fi
SH
chmod +x "$TMP_DIR/fake-bash"

help_output="$(capture_success "$DEPLOY_SCRIPT" --help)"
assert_contains "$help_output" "all|preflight|sync|deploy|smoke|pull-artifacts"
assert_contains "$help_output" "REMOTE_SERVER_HOST=remote-server"
assert_contains "$help_output" "SEPSISCARE_ALLOW_REAL_TRAINING=0"

common_env=(
  REMOTE_SERVER_HOST=remote-server.example
  REMOTE_SERVER_DIR=/srv/sepsiscare
  REMOTE_SERVER_MODEL_URL=http://remote-server.example:8788
  LOCAL_API_URL=http://127.0.0.1:8765
  SSH_BIN="$TMP_DIR/fake-ssh"
  RSYNC_BIN="$TMP_DIR/fake-rsync"
  CURL_BIN="$TMP_DIR/fake-curl"
  PYTHON_BIN="$TMP_DIR/fake-python"
  BASH_BIN="$TMP_DIR/fake-bash"
  SMOKE_SCRIPT="$TMP_DIR/fake-smoke"
  LOCAL_ARTIFACT_DIR="$TMP_DIR/artifacts"
)

sync_output="$(capture_success env "${common_env[@]}" "$DEPLOY_SCRIPT" sync)"
assert_contains "$sync_output" "auditing runtime data before release"
assert_contains "$sync_output" "auditing release files for secrets and PHI before transfer"
assert_contains "$sync_output" "syncing model package to remote-server.example:/srv/sepsiscare/02_model_deploy_package/"
assert_file_contains "$CALL_LOG" "python $SCRIPT_ROOT/audit_runtime_data.py $MODEL_PACKAGE_ROOT/runtime_data"
assert_file_contains "$CALL_LOG" "python $SCRIPT_ROOT/audit_sensitive_data.py $MODEL_PACKAGE_ROOT $APPS_ROOT/sepsiscare-studio/backend $APPS_ROOT/sepsiscare-web-client $APPS_ROOT/SepsisCare-Windows/renderer/web $APPS_ROOT/SepsisCare-iOS/Resources/Web $APPS_ROOT/SepsisCare-Android/app/src/main/assets/web"
assert_file_contains "$CALL_LOG" "rsync -az --info=progress2"
assert_file_contains "$CALL_LOG" "--exclude .runtime/"
assert_file_contains "$CALL_LOG" "--exclude artifacts/"
assert_file_contains "$CALL_LOG" "--exclude .venv/"
assert_file_contains "$CALL_LOG" "02_model_deploy_package/"
assert_file_contains "$CALL_LOG" "remote-server.example:/srv/sepsiscare/02_model_deploy_package/"

deploy_output="$(capture_success env "${common_env[@]}" "$DEPLOY_SCRIPT" deploy)"
assert_contains "$deploy_output" "starting remote model service on remote-server.example"
assert_file_contains "$CALL_LOG" "ssh -o BatchMode=yes -o ConnectTimeout=12 remote-server.example"
assert_file_contains "$CALL_LOG" "SEPSISCARE_MODEL_HOST=0.0.0.0 SEPSISCARE_MODEL_PORT=8788 SEPSISCARE_ALLOW_REAL_TRAINING=0 bash deploy/remote_server_one_click_deploy.sh restart"
assert_file_contains "$CALL_LOG" "bash deploy/remote_server_one_click_deploy.sh smoke"

: > "$CALL_LOG"
default_home_output="$(capture_success env \
  REMOTE_SERVER_HOST=remote-server.example \
  SSH_BIN="$TMP_DIR/fake-ssh" \
  "$DEPLOY_SCRIPT" deploy)"
assert_contains "$default_home_output" "starting remote model service on remote-server.example"
assert_file_contains "$CALL_LOG" "cd ~/'SepsisCare_macOS_app_model_transfer_20260528/02_model_deploy_package'"

smoke_output="$(capture_success env "${common_env[@]}" "$DEPLOY_SCRIPT" smoke)"
assert_contains "$smoke_output" "verifying Mac API -> remote server model service"
assert_file_contains "$CALL_LOG" "smoke http://127.0.0.1:8765 http://remote-server.example:8788 --require-model"

pull_output="$(capture_success env "${common_env[@]}" "$DEPLOY_SCRIPT" pull-artifacts)"
assert_contains "$pull_output" "downloaded remote server artifact"
test -s "$TMP_DIR/artifacts/sepsiscare_model_artifacts_latest.zip" || fail "expected downloaded artifact"
assert_file_contains "$CALL_LOG" "curl --noproxy * -fsS --max-time 60 -o $TMP_DIR/artifacts/sepsiscare_model_artifacts_latest.zip http://remote-server.example:8788/api/artifacts/latest"

: > "$CALL_LOG"
token_pull_output="$(capture_success env "${common_env[@]}" SEPSISCARE_SERVICE_TOKEN=secure-token "$DEPLOY_SCRIPT" pull-artifacts)"
assert_contains "$token_pull_output" "downloaded remote server artifact"
assert_file_contains "$CALL_LOG" "curl --noproxy * -fsS --max-time 60 -H Authorization: Bearer secure-token -o $TMP_DIR/artifacts/sepsiscare_model_artifacts_latest.zip http://remote-server.example:8788/api/artifacts/latest"

: > "$CALL_LOG"
dry_run_token_output="$(capture_success env "${common_env[@]}" DRY_RUN=1 SEPSISCARE_SERVICE_TOKEN=super-secret-token "$DEPLOY_SCRIPT" pull-artifacts)"
assert_contains "$dry_run_token_output" "Authorization:"
assert_contains "$dry_run_token_output" "redacted"
assert_not_contains "$dry_run_token_output" "super-secret-token"

: > "$CALL_LOG"
signed_pull_output="$(capture_success env "${common_env[@]}" SEPSISCARE_ARTIFACT_SIGNING_KEY=release-key "$DEPLOY_SCRIPT" pull-artifacts)"
assert_contains "$signed_pull_output" "verified remote server artifact"
assert_file_contains "$CALL_LOG" "python $MODEL_PACKAGE_ROOT/deploy/verify_artifact_bundle.py $TMP_DIR/artifacts/sepsiscare_model_artifacts_latest.zip --hmac-key-env SEPSISCARE_ARTIFACT_SIGNING_KEY"

: > "$CALL_LOG"
failed_audit_output="$(
  env "${common_env[@]}" FAIL_AUDIT=1 "$DEPLOY_SCRIPT" sync 2>&1 || true
)"
assert_contains "$failed_audit_output" "runtime data audit failed"
grep -Fq "rsync " "$CALL_LOG" && fail "runtime data audit failure should stop rsync"

: > "$CALL_LOG"
failed_sensitive_audit_output="$(
  env "${common_env[@]}" FAIL_SENSITIVE_AUDIT=1 "$DEPLOY_SCRIPT" sync 2>&1 || true
)"
assert_contains "$failed_sensitive_audit_output" "sensitive data audit failed"
grep -Fq "rsync " "$CALL_LOG" && fail "sensitive data audit failure should stop rsync"

: > "$CALL_LOG"
all_output="$(capture_success env "${common_env[@]}" "$DEPLOY_SCRIPT" all)"
assert_contains "$all_output" "running pre-release security check"
assert_contains "$all_output" "ok ssh preflight"
assert_contains "$all_output" "auditing runtime data before release"
assert_contains "$all_output" "auditing release files for secrets and PHI before transfer"
assert_contains "$all_output" "downloaded remote server artifact"
assert_file_contains "$CALL_LOG" "bash $SCRIPT_ROOT/pre_release_security_check.sh"

: > "$CALL_LOG"
failed_pre_release_output="$(
  env "${common_env[@]}" FAIL_PRE_RELEASE_CHECK=1 "$DEPLOY_SCRIPT" all 2>&1 || true
)"
assert_contains "$failed_pre_release_output" "pre-release security check failed"
grep -Fq "ssh " "$CALL_LOG" && fail "pre-release check failure should stop ssh preflight"
grep -Fq "rsync " "$CALL_LOG" && fail "pre-release check failure should stop rsync"

: > "$CALL_LOG"
checked_all_output="$(capture_success env "${common_env[@]}" SEPSISCARE_PRE_RELEASE_CHECKED=1 "$DEPLOY_SCRIPT" all)"
assert_contains "$checked_all_output" "pre-release security check already completed"
assert_contains "$checked_all_output" "ok ssh preflight"
assert_file_contains "$CALL_LOG" "rsync -az --info=progress2"
grep -Fq "pre_release_security_check.sh" "$CALL_LOG" && fail "pre-release check should not recurse when already completed"

: > "$CALL_LOG"
missing_override_reason_output="$(
  env "${common_env[@]}" SEPSISCARE_SKIP_PRE_RELEASE_CHECK=1 "$DEPLOY_SCRIPT" all 2>&1 || true
)"
assert_contains "$missing_override_reason_output" "SEPSISCARE_SKIP_PRE_RELEASE_REASON is required when skipping the pre-release security check"
grep -Fq "ssh " "$CALL_LOG" && fail "missing pre-release override reason should stop ssh preflight"
grep -Fq "rsync " "$CALL_LOG" && fail "missing pre-release override reason should stop rsync"

: > "$CALL_LOG"
override_audit_log="$TMP_DIR/pre_release_override_audit.jsonl"
skip_all_output="$(capture_success env "${common_env[@]}" \
  SEPSISCARE_SKIP_PRE_RELEASE_CHECK=1 \
  SEPSISCARE_SKIP_PRE_RELEASE_REASON="offline break-glass validation" \
  SEPSISCARE_SERVICE_TOKEN="must-not-be-written" \
  SEPSISCARE_PRE_RELEASE_OVERRIDE_AUDIT_LOG="$override_audit_log" \
  REQUIRE_OVERRIDE_AUDIT_LOG="$override_audit_log" \
  "$DEPLOY_SCRIPT" all)"
assert_contains "$skip_all_output" "pre-release security check skipped by SEPSISCARE_SKIP_PRE_RELEASE_CHECK=1"
assert_contains "$skip_all_output" "pre-release override audit:"
assert_contains "$skip_all_output" "ok ssh preflight"
test -s "$override_audit_log" || fail "expected pre-release override audit log"
python3 - "$override_audit_log" <<'PY'
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
if len(events) != 1:
    raise SystemExit(f"expected one audit event, got {len(events)}")
event = events[0]
expected = {
    "event": "pre_release_check_skipped",
    "command": "all",
    "reason": "offline break-glass validation",
}
for key, value in expected.items():
    if event.get(key) != value:
        raise SystemExit(f"expected {key}={value!r}, got {event.get(key)!r}")
if not event.get("timestamp_utc", "").endswith("Z"):
    raise SystemExit("expected UTC timestamp")
if not event.get("user"):
    raise SystemExit("expected audit user")
if not event.get("host"):
    raise SystemExit("expected audit host")
serialized = json.dumps(event, sort_keys=True)
if "must-not-be-written" in serialized or "SEPSISCARE_SERVICE_TOKEN" in serialized:
    raise SystemExit("override audit leaked a token")
PY
audit_mode="$(stat -f '%Lp' "$override_audit_log")"
[[ "$audit_mode" == "600" ]] || fail "expected override audit log mode 600, got $audit_mode"

assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "audit_runtime_data.py"
assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "runtime data audit: ok"
assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "Get-PortListenerPids"
assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "Set-PidFileToPortListener"
assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "sepsiscare_service_token.txt"
assert_file_contains "$MODEL_PACKAGE_ROOT/deploy/start_model_service_windows.ps1" "Resolve-ServiceToken"

echo "remote server deploy orchestration script tests passed"
