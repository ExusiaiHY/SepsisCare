#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BASH_BIN="${BASH_BIN:-bash}"
SWIFT_BIN="${SWIFT_BIN:-swift}"
SEPSISCARE_SKIP_SWIFT_BUILD="${SEPSISCARE_SKIP_SWIFT_BUILD:-0}"
REPORT_DIR="${SEPSISCARE_SECURITY_REPORT_DIR:-$SECURITY_REPORT_DIR_DEFAULT}"
ROG_UPDATE_CHECK_ZIP="${SEPSISCARE_ROG_UPDATE_CHECK_ZIP:-$REPORT_DIR/rog_actual_training_update_check.zip}"

SENSITIVE_AUDIT_ROOTS=(
  "$MODEL_PACKAGE_ROOT"
  "$APPS_ROOT/sepsiscare-studio/backend"
  "$APPS_ROOT/sepsiscare-web-client"
  "$APPS_ROOT/SepsisCare-Windows/renderer/web"
  "$APPS_ROOT/SepsisCare-iOS/Resources/Web"
  "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web"
)

run_step() {
  local label="$1"
  shift
  echo "==> $label"
  "$@"
}

run_json_report() {
  local label="$1"
  local output_path="$2"
  shift 2
  mkdir -p "$REPORT_DIR"
  echo "==> $label"
  if ! "$@" > "$output_path"; then
    cat "$output_path" >&2 || true
    return 1
  fi
  python3 - "$output_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
report = json.loads(path.read_text(encoding="utf-8"))
summary = report.get("summary") or {}
parts = [f"ok={report.get('ok')}"]
if "violations" in summary:
    parts.append(f"violations={summary.get('violations')}")
if "warnings" in summary:
    parts.append(f"warnings={summary.get('warnings')}")
if "findings" in summary:
    parts.append(f"findings={summary.get('findings')}")
if "roots" in report:
    parts.append(f"roots={len(report.get('roots') or [])}")
parts.append(f"report={path}")
print("audit summary: " + " ".join(parts))
PY
}

run_in_dir() {
  local label="$1"
  local dir="$2"
  shift 2
  echo "==> $label"
  (cd "$dir" && "$@")
}

run_step "unit: runtime data audit" "$PYTHON_BIN" -m unittest "$SCRIPT_ROOT/test_runtime_data_audit.py"
run_step "unit: sensitive data audit" "$PYTHON_BIN" -m unittest "$SCRIPT_ROOT/test_sensitive_data_audit.py"
run_step "unit: training data integrity audit" "$PYTHON_BIN" -m unittest "$SCRIPT_ROOT/test_training_data_integrity_audit.py"

run_json_report "audit: deploy runtime data" "$REPORT_DIR/deploy_runtime_data_audit.json" "$PYTHON_BIN" "$SCRIPT_ROOT/audit_runtime_data.py" "$MODEL_PACKAGE_ROOT/runtime_data"
run_json_report "audit: backend runtime data" "$REPORT_DIR/backend_runtime_data_audit.json" "$PYTHON_BIN" "$SCRIPT_ROOT/audit_runtime_data.py" "$APPS_ROOT/sepsiscare-studio/backend/runtime_data"
run_json_report "audit: release files sensitive data" "$REPORT_DIR/release_sensitive_data_audit.json" "$PYTHON_BIN" "$SCRIPT_ROOT/audit_sensitive_data.py" "${SENSITIVE_AUDIT_ROOTS[@]}"
run_json_report "audit: training data integrity" "$REPORT_DIR/training_data_integrity_audit.json" "$PYTHON_BIN" "$SCRIPT_ROOT/audit_training_data_integrity.py" "$MODEL_PACKAGE_ROOT"

run_step "unit: remote model service" "$PYTHON_BIN" -m unittest "$MODEL_PACKAGE_ROOT/deploy/test_model_service.py"
run_step "unit: artifact verifier" "$PYTHON_BIN" -m unittest "$MODEL_PACKAGE_ROOT/deploy/test_verify_artifact_bundle.py"
run_step "unit: ROG remote-ops sender" "$PYTHON_BIN" -m unittest "$ROOT_DIR/06_scripts/rog_actual_training_update/test_send_rog_remote_ops_command.py"
run_in_dir "unit: local backend server" "$APPS_ROOT/sepsiscare-studio/backend" "$PYTHON_BIN" -m unittest test_server.py

run_step "web: auth token storage" "$BASH_BIN" "$SCRIPT_ROOT/test_web_auth_token.sh"
run_step "web: demo auth boundary" "$BASH_BIN" "$SCRIPT_ROOT/test_demo_auth_boundary.sh"
run_step "web: content escaping" "$BASH_BIN" "$SCRIPT_ROOT/test_web_content_escape.sh"
run_step "web: syntax parse" "$BASH_BIN" "$SCRIPT_ROOT/test_web_syntax.sh"
run_step "docs: deployment secret hygiene" "$BASH_BIN" "$SCRIPT_ROOT/test_deployment_doc_secret_hygiene.sh"
run_step "deploy: Mac to remote server orchestration" "$BASH_BIN" "$SCRIPT_ROOT/test_deploy_model_to_remote_server.sh"
run_step "services: local service orchestration" "$BASH_BIN" "$SCRIPT_ROOT/test_sepsiscare_services.sh"
run_step "deploy: model one-click smoke" "$BASH_BIN" "$MODEL_PACKAGE_ROOT/deploy/test_remote_server_one_click_deploy.sh"
run_step "package: ROG actual training update" "$BASH_BIN" "$SCRIPT_ROOT/build_rog_actual_training_update.sh" "$ROG_UPDATE_CHECK_ZIP"

if [[ "$SEPSISCARE_SKIP_SWIFT_BUILD" != "1" ]]; then
  run_in_dir "build: primary macOS Swift package" "$PRIMARY_MACOS_ROOT" "$SWIFT_BIN" build
  run_in_dir "build: app macOS Swift package" "$MIRROR_MACOS_ROOT" "$SWIFT_BIN" build
else
  echo "==> build: Swift packages skipped by SEPSISCARE_SKIP_SWIFT_BUILD=1"
fi

echo "pre-release security check completed"
