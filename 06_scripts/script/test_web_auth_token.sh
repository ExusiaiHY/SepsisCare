#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPS_ROOT="$ROOT_DIR/04_client_source/apps"

check_file() {
  local path="$1"
  grep -Fq 'sessionStorage.getItem("sepsiscare.apiToken")' "$path" || {
    echo "not ok: $path does not read API tokens from session storage" >&2
    exit 1
  }
  grep -Fq 'sessionStorage.setItem("sepsiscare.apiToken", next)' "$path" || {
    echo "not ok: $path does not keep API tokens session-scoped" >&2
    exit 1
  }
  grep -Fq 'localStorage.setItem("sepsiscare.apiToken"' "$path" && {
    echo "not ok: $path persists API tokens in localStorage" >&2
    exit 1
  }
  grep -Fq 'scrubLaunchSecretsFromUrl()' "$path" || {
    echo "not ok: $path does not remove launch tokens from the URL" >&2
    exit 1
  }
  grep -Fq 'function normalizeApiToken' "$path" || {
    echo "not ok: $path does not normalize API tokens" >&2
    exit 1
  }
  grep -Fq 'Authorization' "$path" || {
    echo "not ok: $path does not add Authorization headers" >&2
    exit 1
  }
}

check_file "$APPS_ROOT/sepsiscare-web-client/app.js"
check_file "$APPS_ROOT/SepsisCare-Windows/renderer/web/app.js"
check_file "$APPS_ROOT/SepsisCare-iOS/Resources/Web/app.js"
check_file "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web/app.js"

echo "web auth token checks passed"
