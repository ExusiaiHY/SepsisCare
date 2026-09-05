#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPS_ROOT="$ROOT_DIR/04_client_source/apps"

check_file() {
  local path="$1"
  grep -Fq 'function safeText' "$path" || {
    echo "not ok: $path does not define safeText for HTML text insertion" >&2
    exit 1
  }
  grep -Fq 'function safeJSON' "$path" || {
    echo "not ok: $path does not define safeJSON for JSON-in-pre insertion" >&2
    exit 1
  }
  grep -Fq 'function safeAttr' "$path" || {
    echo "not ok: $path does not define safeAttr for HTML attributes" >&2
    exit 1
  }
  if grep -Fq '<pre>${JSON.stringify(' "$path"; then
    echo "not ok: $path directly injects JSON into <pre>" >&2
    exit 1
  fi
  if grep -Fq '${m.text}</div>' "$path"; then
    echo "not ok: $path directly injects chat message text into HTML" >&2
    exit 1
  fi
  if grep -Fq 'data-patient="${p.masked_id}"' "$path"; then
    echo "not ok: $path directly injects patient ids into HTML attributes" >&2
    exit 1
  fi
  if grep -Fq '${r.masked_id}</td>' "$path"; then
    echo "not ok: $path directly injects history patient ids into table HTML" >&2
    exit 1
  fi
}

check_file "$APPS_ROOT/sepsiscare-web-client/app.js"
check_file "$APPS_ROOT/SepsisCare-Windows/renderer/web/app.js"
check_file "$APPS_ROOT/SepsisCare-iOS/Resources/Web/app.js"
check_file "$APPS_ROOT/SepsisCare-Android/app/src/main/assets/web/app.js"

echo "web content escaping checks passed"
