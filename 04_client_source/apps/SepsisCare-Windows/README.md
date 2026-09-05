# SepsisCare Windows

Windows desktop app for the shared SepsisCare web client. The packaged Windows
installer now includes the local backend, Windows embeddable Python runtime, and
the S7 demo model package so the classroom demo can run without a remote server.

## Quick Start (Development)

```powershell
cd apps\SepsisCare-Windows
npm install
npm run sync:web
npm run verify:package
npm start
```

## Build Setup Installer

### On Windows (Recommended)

```powershell
cd apps\SepsisCare-Windows
npm install
npm run dist
```

Output: `dist/sepsiscare-0.9.1-win-x64.exe`

### On macOS / Linux (Cross-build)

```bash
cd apps/SepsisCare-Windows
./scripts/build-setup.sh
```

Output: `dist/sepsiscare-0.9.1-win-x64.exe`

> Note: production code signing requires Windows / wine with a valid certificate. Unsigned builds are suitable only for internal testing.

## Installer Features

- **Welcome Page**: Overview of sepsiscare and first-run tips.
- **Custom Install Directory**: Users can choose where to install.
- **Desktop & Start Menu Shortcuts**: Created automatically.
- **Local API Default**: New installs connect to `http://127.0.0.1:8765`.
- **Bundled Python Runtime**: Windows x64 embeddable Python is packaged with the app.
- **Local Backend Autostart**: Electron starts `server.py` automatically.
- **Bundled Demo Model Package**: S7 model files, reports, and de-identified runtime database are packaged as resources.
- **Finish Page**: Option to launch immediately + open LICENSE.

## Silent Install

```powershell
.\dist\sepsiscare-0.9.1-win-x64.exe /S
```

## Uninstall

Run the uninstaller from:
- Start Menu → sepsiscare → Uninstall
- Control Panel → Apps → sepsiscare

The uninstaller also cleans up the legacy local-backend firewall rule if an older build created it.
