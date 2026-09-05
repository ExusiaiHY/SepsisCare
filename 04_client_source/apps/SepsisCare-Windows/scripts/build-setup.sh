#!/bin/bash
# Build Windows NSIS Setup.exe on Windows, macOS, or Linux via electron-builder.
# Requires: node and npm. Cross-builds are unsigned unless signing is configured.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"

cd "$PROJECT_DIR"

if [[ ! -f "$ROOT/apps/sepsiscare-web-client/index.html" ]]; then
    echo "Missing shared web client at $ROOT/apps/sepsiscare-web-client" >&2
    exit 1
fi

echo "==> Installing dependencies…"
npm install

echo "==> Syncing web client assets…"
npm run sync:web

echo "==> Building Windows NSIS installer…"
# Build Windows target on macOS/Linux when electron-builder supports it.
# A production build should be signed on Windows with a valid code-signing cert.
npx electron-builder --win nsis --x64

echo ""
echo "==> Installer should be in: $PROJECT_DIR/dist/"
ls -la "$PROJECT_DIR/dist/" 2>/dev/null || true
