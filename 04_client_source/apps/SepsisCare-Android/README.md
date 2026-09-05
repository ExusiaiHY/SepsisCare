# sepsiscare Android

Android WebView wrapper for the shared sepsiscare web client.

## Requirements

- Android Studio (recommended) or Android SDK Command Line Tools
- JDK 17 or higher

## Quick Start

### Using Android Studio

1. Open `apps/SepsisCare-Android` in Android Studio
2. Sync project with Gradle files
3. Click **Run** (▶) — a debug APK will be built and deployed

### Using Command Line

```bash
cd apps/SepsisCare-Android
./gradlew assembleDebug
```

APK output: `app/build/outputs/apk/debug/sepsiscare-0.9.0-debug.apk`

### Build Release APK

```bash
cd apps/SepsisCare-Android
./scripts/build-apk.sh
```

Release APK: `app/build/outputs/apk/release/sepsiscare-0.9.0-release.apk`

The script automatically uses a local JDK 17 under `$HOME/.jdk/*/Contents/Home` when `JAVA_HOME` is not set.

If Android SDK platform 35 is missing:

```bash
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"
```

To produce a signed release APK for distribution, configure `signingConfigs.release` in `app/build.gradle` with your keystore.

## Install to Device

```bash
adb install -r app/build/outputs/apk/debug/sepsiscare-0.9.0-debug.apk
```

## App Icon

Launcher icons are generated in `app/src/main/res/mipmap-*/` from the brand color palette. To regenerate:

```bash
cd apps
python3 scripts/generate-icons.py
```
