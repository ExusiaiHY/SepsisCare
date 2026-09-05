#!/bin/bash
set -e

# macOS DMG Installer Builder for sepsiscare
# Usage: ./scripts/build-dmg.sh [--skip-build]

APP_NAME="sepsiscare"
BUNDLE_NAME="SepsisCare-macOS"
BUNDLE_ID="care.sepsis.desktop"
VERSION="1.0.1"
BUILD="2026.06.07"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$BUNDLE_NAME.app"
DMG_NAME="${APP_NAME}-${VERSION}-macOS.dmg"
VOL_NAME="sepsiscare Installer"
SWIFT_HOME="$PROJECT_DIR/.swift_home"
CLANG_CACHE="$PROJECT_DIR/.swift_module_cache"
BACKEND_SOURCE=""

for candidate in "$PROJECT_DIR/../sepsiscare-studio/backend" "$PROJECT_DIR/../../apps/sepsiscare-studio/backend"; do
    if [[ -d "$candidate" ]]; then
        BACKEND_SOURCE="$candidate"
        break
    fi
done

echo "==> Building sepsiscare macOS DMG installer…"

# 1. Swift build (unless skipped)
if [[ "${1:-}" != "--skip-build" ]]; then
    echo "--> Running swift build -c release"
    cd "$PROJECT_DIR"
    mkdir -p "$SWIFT_HOME" "$CLANG_CACHE"
    HOME="$SWIFT_HOME" CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift build -c release
else
    echo "--> Skipping swift build (using existing binary)"
fi

# 2. Assemble .app bundle
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$BUNDLE_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
if [[ -n "$BACKEND_SOURCE" ]]; then
  rsync -a --delete \
    --exclude "runtime_data/audit.jsonl" \
    --exclude "__pycache__/" \
    "$BACKEND_SOURCE/" \
    "$APP_BUNDLE/Contents/Resources/backend/"
else
  echo "warning: backend resources not found; packaged app will require an external API." >&2
fi

# Fix plist executable name (optional sanity)
# Info.plist already uses SepsisCare-macOS

# 3. Sign ad-hoc (required for Gatekeeper on modern macOS)
echo "--> Ad-hoc signing app bundle"
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE"

# 4. Create DMG
echo "--> Creating DMG image"
rm -f "$DIST_DIR/$DMG_NAME"
mkdir -p "$DIST_DIR"

# Use hdiutil for a clean DMG
TMP_DMG="$DIST_DIR/tmp.dmg"
MOUNT_POINT="/Volumes/$VOL_NAME"

# Detach if already mounted (cleanup)
hdiutil detach "$MOUNT_POINT" 2>/dev/null || true

# Create temporary DMG from app bundle
hdiutil create -srcfolder "$APP_BUNDLE" -volname "$VOL_NAME" -fs HFS+ -format UDRW -size 100m "$TMP_DMG"

# Mount and customize appearance
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" | grep "Apple_HFS" | awk '{print $1}')
echo "   Mounted on $DEVICE"

# Wait for mount
sleep 1

# Create a symlink to /Applications for drag-and-drop install
ln -sf /Applications "/Volumes/$VOL_NAME/Applications"

# Optional: set custom background (requires extra files, keeping it simple)
# Just ensure the window opens nicely

# Set volume icon (same as app icon)
cp "$SCRIPT_DIR/AppIcon.icns" "/Volumes/$VOL_NAME/.VolumeIcon.icns"
SetFile -c icnC "/Volumes/$VOL_NAME/.VolumeIcon.icns" 2>/dev/null || true

# Hide hidden files
SetFile -a V "/Volumes/$VOL_NAME/.VolumeIcon.icns" 2>/dev/null || true

# Finalize
hdiutil detach "$DEVICE" 2>/dev/null || hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
sleep 1

# Convert to compressed read-only DMG
hdiutil convert "$TMP_DMG" -format UDZO -o "$DIST_DIR/$DMG_NAME"
rm -f "$TMP_DMG"

# Optional: sign DMG ad-hoc
codesign --sign - "$DIST_DIR/$DMG_NAME" 2>/dev/null || true

echo ""
echo "==> DMG ready: $DIST_DIR/$DMG_NAME"
echo "    Drag '$BUNDLE_NAME.app' → 'Applications' to install."
