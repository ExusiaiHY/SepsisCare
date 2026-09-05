#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SepsisCare-macOS"
PRODUCTION_BUNDLE_ID="care.sepsis.desktop"
DEVELOPMENT_BUNDLE_ID="${PRODUCTION_BUNDLE_ID}.dev"
DMG_VOLUME_NAME="sepsiscare Installer"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layout_paths.sh"
DEV_APP="$ROOT_DIR/06_scripts/dist/$APP_NAME.app"
DIST_APP="$PRIMARY_MACOS_ROOT/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
DMG_PATH="$PRIMARY_MACOS_ROOT/dist/sepsiscare-1.0.1-macOS.dmg"

fail() {
  echo "not ok: $*" >&2
  exit 1
}

assert_no_quarantine() {
  local path="$1"
  if /usr/bin/xattr -lr "$path" 2>/dev/null | /usr/bin/grep -q "com.apple.quarantine"; then
    fail "$path contains com.apple.quarantine metadata"
  fi
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || fail "$plist missing $key"
  [[ "$actual" == "$expected" ]] || fail "$plist $key expected $expected, got $actual"
}

check_app_bundle() {
  local app="$1"
  local label="$2"
  local expected_bundle_id="$3"
  local plist="$app/Contents/Info.plist"
  local executable

  [[ -d "$app" ]] || fail "$label app bundle is missing: $app"
  [[ -f "$plist" ]] || fail "$label Info.plist is missing"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || fail "$label code signature verification failed"
  assert_no_quarantine "$app"

  assert_plist_value "$plist" "CFBundleIdentifier" "$expected_bundle_id"
  assert_plist_value "$plist" "CFBundlePackageType" "APPL"
  assert_plist_value "$plist" "LSMultipleInstancesProhibited" "true"
  assert_plist_value "$plist" "NSPrincipalClass" "NSApplication"

  executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null)" || fail "$label missing CFBundleExecutable"
  [[ -x "$app/Contents/MacOS/$executable" ]] || fail "$label executable is missing or not executable"

  [[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "$label app icon missing"
  [[ -f "$app/Contents/Resources/backend/server.py" ]] || fail "$label packaged backend server.py missing"

  echo "ok $label app bundle"
}

check_mounted_dmg() {
  local mount_point="/Volumes/$DMG_VOLUME_NAME"
  local mounted_here=0

  [[ -f "$DMG_PATH" ]] || fail "DMG is missing: $DMG_PATH"

  if [[ ! -d "$mount_point/$APP_NAME.app" ]]; then
    /usr/bin/hdiutil attach -nobrowse -noverify "$DMG_PATH" >/dev/null
    mounted_here=1
  fi

  check_app_bundle "$mount_point/$APP_NAME.app" "DMG" "$PRODUCTION_BUNDLE_ID"
  [[ -L "$mount_point/Applications" ]] || fail "DMG Applications symlink missing"

  if [[ "$mounted_here" == "1" ]]; then
    /usr/bin/hdiutil detach "$mount_point" >/dev/null
  fi

  echo "ok DMG contents"
}

[[ "$DEVELOPMENT_BUNDLE_ID" != "$PRODUCTION_BUNDLE_ID" ]] || fail "development bundle id must not match production bundle id"

if [[ -d "$DEV_APP" ]]; then
  check_app_bundle "$DEV_APP" "development" "$DEVELOPMENT_BUNDLE_ID"
else
  echo "skip development app bundle: $DEV_APP not present"
fi
check_app_bundle "$DIST_APP" "distribution" "$PRODUCTION_BUNDLE_ID"

if [[ -d "$INSTALLED_APP" ]]; then
  check_app_bundle "$INSTALLED_APP" "installed" "$PRODUCTION_BUNDLE_ID"
else
  echo "skip installed app bundle: $INSTALLED_APP not present"
fi

check_mounted_dmg

echo "macOS app bundle tests passed"
