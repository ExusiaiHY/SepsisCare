@echo off
REM Build Windows NSIS Setup.exe on Windows
REM Requires: Node.js, npm

cd /d "%~dp0\.."

echo == Installing dependencies...
call npm install

echo == Syncing web client assets...
call npm run sync:web

echo == Building Windows NSIS installer...
call npx electron-builder --win nsis --x64

echo.
echo == Installer should be in: %CD%\dist\
dir "%CD%\dist\*.exe" 2>nul
pause
