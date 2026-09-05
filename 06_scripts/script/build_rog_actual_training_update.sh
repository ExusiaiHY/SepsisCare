#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_ROOT="$DELIVERY_ROOT/03_remote_server_model_package/02_model_deploy_package/deploy"
SOURCE_ROOT="$DELIVERY_ROOT/06_scripts/rog_actual_training_update"
OUTPUT="${1:-$DELIVERY_ROOT/02_installers/rog_actual_training_update_20260605.zip}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/rog-actual-training-update.XXXXXX")"
PACKAGE_ROOT="$STAGING/rog_actual_training_update"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$PACKAGE_ROOT/deploy" "$PACKAGE_ROOT/scripts" "$(dirname "$OUTPUT")"

for deploy_file in \
    audit_runtime_data.py \
    model_service.py \
    requirements_model_deploy.txt \
    start_model_service_windows.ps1 \
    test_model_service.py \
    test_verify_artifact_bundle.py \
    verify_artifact_bundle.py
do
    cp "$DEPLOY_ROOT/$deploy_file" "$PACKAGE_ROOT/deploy/$deploy_file"
done
cp "$SOURCE_ROOT/update_rog_model_service.ps1" "$PACKAGE_ROOT/scripts/update_rog_model_service.ps1"
cp "$SOURCE_ROOT/verify_rog_actual_training.ps1" "$PACKAGE_ROOT/scripts/verify_rog_actual_training.ps1"
cp "$SOURCE_ROOT/install_and_verify_rog_actual_training.cmd" "$PACKAGE_ROOT/install_and_verify_rog_actual_training.cmd"
cp "$SOURCE_ROOT/README_ROG_ACTUAL_TRAINING_UPDATE.md" "$PACKAGE_ROOT/README_ROG_ACTUAL_TRAINING_UPDATE.md"
cp "$SOURCE_ROOT/send_rog_remote_ops_command.py" "$PACKAGE_ROOT/send_rog_remote_ops_command.py"

rm -f "$OUTPUT"
(
    cd "$STAGING"
    zip -qr "$OUTPUT" rog_actual_training_update
)

shasum -a 256 "$OUTPUT"
