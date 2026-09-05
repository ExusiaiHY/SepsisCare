#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SepsisCare-macOS"
PRODUCTION_BUNDLE_ID="care.sepsis.desktop"
DEV_BUNDLE_ID="${SEPSISCARE_DEV_BUNDLE_ID:-${PRODUCTION_BUNDLE_ID}.dev}"
BUNDLE_ID="$DEV_BUNDLE_ID"
APP_DISPLAY_NAME="${SEPSISCARE_DEV_DISPLAY_NAME:-SepsisCare Dev}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/SepsisCare-macOS"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SWIFT_HOME="$PROJECT_DIR/.swift_home"
CLANG_CACHE="$PROJECT_DIR/.swift_module_cache"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_existing_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return 0
  fi

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done

  pkill -9 -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_swiftpm_app() {
  mkdir -p "$SWIFT_HOME" "$CLANG_CACHE"
  HOME="$SWIFT_HOME" CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift build --package-path "$PROJECT_DIR"
}

stage_app_bundle() {
  local build_bin_path
  build_bin_path="$(HOME="$SWIFT_HOME" CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift build --package-path "$PROJECT_DIR" --show-bin-path)"
  local build_binary="$build_bin_path/$APP_NAME"

  if [[ ! -x "$build_binary" ]]; then
    echo "missing build binary: $build_binary" >&2
    exit 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$build_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.1</string>
  <key>CFBundleVersion</key>
  <string>2026.06.07</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.medical</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  if [[ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/scripts/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$INFO_PLIST" >/dev/null 2>&1 || true
  fi

  if [[ -d "$ROOT_DIR/apps/sepsiscare-studio/backend" ]]; then
    rsync -a --delete \
      --exclude "runtime_data/audit.jsonl" \
      --exclude "__pycache__/" \
      "$ROOT_DIR/apps/sepsiscare-studio/backend/" \
      "$APP_RESOURCES/backend/"
  else
    echo "warning: backend resources not found at $ROOT_DIR/apps/sepsiscare-studio/backend" >&2
  fi

  /usr/bin/xattr -dr com.apple.quarantine "$APP_BUNDLE" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app_process() {
  sleep 2
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME is running from $APP_BUNDLE"
    return 0
  fi
  echo "$APP_NAME did not stay running after launch." >&2
  return 1
}

stop_existing_app
build_swiftpm_app
stage_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_app_process
    ;;
  *)
    usage
    exit 2
    ;;
esac
