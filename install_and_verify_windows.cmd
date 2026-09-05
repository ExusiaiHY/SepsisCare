@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_and_verify_windows.ps1" %*
set EXITCODE=%ERRORLEVEL%
if not "%SEPSISCARE_NO_PAUSE%"=="1" pause
exit /b %EXITCODE%
