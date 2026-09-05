# sepsiscare 安装向导构建指南

本文档说明如何为 sepsiscare 各平台客户端生成安装包/安装向导。

---

## macOS — DMG 安装包

**技术方案**：SwiftUI 原生应用 → `.app` bundle → DMG 镜像

**构建命令**：

```bash
cd SepsisCare-macOS
./scripts/build-dmg.sh
```

**输出**：`dist/sepsiscare-1.0.1-macOS.dmg`

**安装体验**：
- 用户双击 DMG，打开挂载的卷
- 卷内包含 `SepsisCare-macOS.app` 和 `Applications` 快捷方式
- 拖拽 App 到 Applications 即完成安装
- 支持 ad-hoc 签名，可进一步公证 (Notarization)

**文件清单**：
- `SepsisCare-macOS/scripts/build-dmg.sh` — 构建脚本
- `SepsisCare-macOS/scripts/Info.plist` — 应用清单
- `SepsisCare-macOS/scripts/AppIcon.icns` — 应用图标

---

## Windows — Setup.exe 安装向导

**技术方案**：Electron + electron-builder + NSIS

**构建命令** (Windows)：

```powershell
cd SepsisCare-Windows
npm install
npm run dist
```

**交叉构建** (macOS/Linux)：

```bash
cd SepsisCare-Windows
./scripts/build-setup.sh
```

**输出**：`dist/sepsiscare-0.9.0-win-x64.exe`

**安装向导特性**：
- 欢迎页面（功能介绍 + 首次使用提示）
- 自定义安装目录（非一键安装，用户可选路径）
- 自动创建桌面快捷方式和开始菜单快捷方式
- 自动添加 Windows 防火墙规则（端口 8765）
- 安装完成页（可立即启动 + 查看许可协议）
- 静默安装支持：`sepsiscare-0.9.0-win-x64.exe /S`

**文件清单**：
- `SepsisCare-Windows/installer/installer.nsh` — NSIS 安装向导脚本
- `SepsisCare-Windows/build/icon.ico` — 安装程序图标
- `SepsisCare-Windows/scripts/build-setup.bat` — Windows 构建脚本
- `SepsisCare-Windows/scripts/build-setup.sh` — macOS/Linux 交叉构建脚本

---

## Android — APK 安装包

**技术方案**：Android WebView + Gradle

**构建命令**：

```bash
cd SepsisCare-Android
./gradlew assembleDebug      # 调试版
./gradlew assembleRelease    # 发布版（未签名）
```

或使用脚本：

```bash
cd SepsisCare-Android
./scripts/build-apk.sh
```

**输出**：
- `app/build/outputs/apk/debug/sepsiscare-0.9.0-debug.apk`
- `app/build/outputs/apk/release/sepsiscare-0.9.0-release.apk`

**注意**：发布到应用商店前，需在 `app/build.gradle` 中配置 `signingConfigs.release` 并使用自己的 keystore 签名。

**文件清单**：
- `SepsisCare-Android/app/build.gradle` — 构建配置（含 APK 命名规则）
- `SepsisCare-Android/app/src/main/res/mipmap-*/ic_launcher.png` — 应用图标
- `SepsisCare-Android/scripts/build-apk.sh` — 构建脚本

---

## iOS

暂不处理（需上架 App Store，后续可补充 Xcode Archive + TestFlight / App Store Connect 流程）。

---

## 统一图标生成

所有平台的图标均从品牌色板自动生成：

```bash
cd apps
python3 scripts/generate-icons.py
```

这会同时生成：
- macOS `.icns`
- Windows `.ico`
- Android `mipmap-*` PNG

**依赖**：Python 3 + Pillow (`pip install pillow`)
