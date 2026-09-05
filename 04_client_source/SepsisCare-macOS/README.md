# sepsiscare macOS

Native SwiftUI macOS application for sepsiscare.

## Requirements

- macOS 14.0+
- Xcode 15+ / Swift 5.9+

## Build & Run (Development)

```bash
./script/build_and_run.sh --verify
```

This SwiftPM target is a SwiftUI GUI app. Launch it as a staged `.app` bundle
from the project root; direct `swift run` can behave like a raw command-line
binary and may not foreground a normal macOS window.

For compiler-only checks:

```bash
cd SepsisCare-macOS
swift build
swift test
```

## Build DMG Installer

```bash
cd apps/SepsisCare-macOS
./scripts/build-dmg.sh
```

Output: `dist/sepsiscare-1.0.1-macOS.dmg`

The DMG includes:
- `SepsisCare-macOS.app` (signed ad-hoc)
- `Applications` symlink for drag-and-drop install
- Branded volume icon

## What the Installer Does

1. Builds release binary via `swift build -c release`
2. Assembles `.app` bundle with `Info.plist` and `AppIcon.icns`
3. Ad-hoc signs the bundle (`codesign -s -`)
4. Packages into a compressed, read-only DMG

## App Icon

The app icon is generated from the brand color palette. To regenerate:

```bash
cd apps
python3 scripts/generate-icons.py
```

## Distribution Notes

- For distribution outside the Mac App Store, notarize the DMG with your Apple Developer ID.
- For Mac App Store, convert the project to an Xcode project with a proper provisioning profile.
