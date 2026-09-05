# sepsiscare iOS

iOS wrapper using `WKWebView` and the shared web client.

## Requirements

- Xcode
- XcodeGen
- Apple Developer signing team/profile for device `.ipa` export

Generate Xcode project:

```bash
brew install xcodegen
cd apps/SepsisCare-iOS
xcodegen generate
open SepsisCare-iOS.xcodeproj
```

Before building, sync shared web assets:

```bash
cd ../..
bash scripts/sync_sepsiscare_shared_web.sh
```

## Build IPA

```bash
cd apps/SepsisCare-iOS
SEPSISCARE_IOS_TEAM_ID=<YOUR_TEAM_ID> SEPSISCARE_IOS_ALLOW_UPDATES=1 ./scripts/build-ipa.sh
```

Outputs:

```text
build/sepsiscare.xcarchive
build/ipa/*.ipa
```

Install to a registered device:

```bash
xcrun devicectl device install app --device <DEVICE_UDID> build/ipa/*.ipa
```

iOS does not support an unsigned, double-click installer. Distribution must use Apple signing, TestFlight, App Store, Apple Business Manager, MDM, or Apple Configurator.
