#!/bin/bash
# Build sepsiscare iOS archive and export an IPA when signing is configured.
# Requires Xcode, xcodegen, and an Apple signing team/profile for device IPA export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
EXPORT_OPTIONS="$PROJECT_DIR/ExportOptions.plist"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen is required to generate SepsisCare-iOS.xcodeproj." >&2
    echo "  Install: brew install xcodegen" >&2
    exit 1
fi

if [[ ! -f "$ROOT/apps/sepsiscare-web-client/index.html" ]]; then
    echo "Missing shared web client at $ROOT/apps/sepsiscare-web-client" >&2
    exit 1
fi

bash "$ROOT/scripts/sync_sepsiscare_shared_web.sh"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Archiving iOS app"
xcodebuild archive \
  -project SepsisCare-iOS.xcodeproj \
  -scheme SepsisCare-iOS \
  -configuration Release \
  -archivePath build/sepsiscare.xcarchive \
  ${SEPSISCARE_IOS_TEAM_ID:+DEVELOPMENT_TEAM="$SEPSISCARE_IOS_TEAM_ID"} \
  ${SEPSISCARE_IOS_ALLOW_UPDATES:+-allowProvisioningUpdates}

if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    cat > "$EXPORT_OPTIONS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
EOF
fi

echo "==> Exporting IPA"
xcodebuild -exportArchive \
  -archivePath build/sepsiscare.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  ${SEPSISCARE_IOS_ALLOW_UPDATES:+-allowProvisioningUpdates}

echo ""
echo "==> IPA outputs:"
find "$PROJECT_DIR/build/ipa" -name "*.ipa" -exec ls -lh {} \;
