#!/usr/bin/env bash

SEPSISCARE_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")/.." && pwd)"

if [[ -d "$SEPSISCARE_SCRIPT_ROOT/apps" && -d "$SEPSISCARE_SCRIPT_ROOT/02_model_deploy_package" ]]; then
  ROOT_DIR="$SEPSISCARE_SCRIPT_ROOT"
  SCRIPT_ROOT="$ROOT_DIR/script"
  APPS_ROOT="$ROOT_DIR/apps"
  MODEL_PACKAGE_ROOT="$ROOT_DIR/02_model_deploy_package"
  PRIMARY_MACOS_ROOT="$ROOT_DIR/SepsisCare-macOS"
  MIRROR_MACOS_ROOT="$ROOT_DIR/apps/SepsisCare-macOS"
  TRANSFER_README="$ROOT_DIR/TRANSFER_README.md"
  SECURITY_REPORT_DIR_DEFAULT="$ROOT_DIR/.sepsiscare-runtime/security-checks"
else
  ROOT_DIR="$(cd "$SEPSISCARE_SCRIPT_ROOT/.." && pwd)"
  SCRIPT_ROOT="$ROOT_DIR/06_scripts/script"
  APPS_ROOT="$ROOT_DIR/04_client_source/apps"
  MODEL_PACKAGE_ROOT="$ROOT_DIR/03_remote_server_model_package/02_model_deploy_package"
  PRIMARY_MACOS_ROOT="$ROOT_DIR/04_client_source/SepsisCare-macOS"
  MIRROR_MACOS_ROOT="$ROOT_DIR/04_client_source/apps/SepsisCare-macOS"
  TRANSFER_README="$ROOT_DIR/05_quality_security/TRANSFER_README.md"
  SECURITY_REPORT_DIR_DEFAULT="$ROOT_DIR/05_quality_security/security-checks"
fi
