#!/bin/bash
# Build sepsiscare Android APK.
# Requires: JDK 17+ and Android SDK platform 35.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

if [[ -z "${JAVA_HOME:-}" ]]; then
    for candidate in "$HOME/.jdk"/*/Contents/Home; do
        if [[ -x "$candidate/bin/java" ]]; then
            candidate_version=$("$candidate/bin/java" -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
            if [[ "$candidate_version" -ge 17 ]]; then
                export JAVA_HOME="$candidate"
                export PATH="$JAVA_HOME/bin:$PATH"
                break
            fi
        fi
    done
fi

if [[ -d "$HOME/android-sdk" && -z "${ANDROID_HOME:-}" ]]; then
    export ANDROID_HOME="$HOME/android-sdk"
fi
if [[ -n "${ANDROID_HOME:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/35.0.1:$PATH"
fi

JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
echo "Detected Java: $JAVA_VER"
JAVA_MAJOR="${JAVA_VER%%.*}"

if [[ -z "$JAVA_VER" || "$JAVA_MAJOR" -lt 17 ]]; then
    echo "ERROR: Android Gradle Plugin requires Java 17+. Set JAVA_HOME to JDK 17 or higher." >&2
    echo "  Example: export JAVA_HOME=$HOME/.jdk/jdk-17.0.14+7/Contents/Home" >&2
    exit 1
fi

if [[ -z "${ANDROID_HOME:-}" || ! -d "${ANDROID_HOME:-}/platforms/android-35" ]]; then
    echo "ERROR: Android SDK platform 35 was not found." >&2
    echo "  Install it with: sdkmanager \"platforms;android-35\" \"build-tools;35.0.0\" \"platform-tools\"" >&2
    exit 1
fi

echo "==> Building debug APK…"
./gradlew assembleDebug

echo ""
echo "==> Building release APK (unsigned)…"
./gradlew assembleRelease

echo ""
echo "==> APK outputs:"
find "$PROJECT_DIR/app/build/outputs/apk" -name "*.apk" -exec ls -lh {} \;

echo ""
echo "==> Install debug APK to connected device:"
echo "  adb install -r app/build/outputs/apk/debug/sepsiscare-0.9.1-debug.apk"
