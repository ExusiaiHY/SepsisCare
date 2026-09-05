@echo off
setlocal

set "DEPLOY_ROOT=%~1"
if "%DEPLOY_ROOT%"=="" set "DEPLOY_ROOT=D:\PredictionService\models\production\02_model_deploy_package"
set "SERVICE_TOKEN=%~2"
set "HOST_ADDRESS=0.0.0.0"
set "PORT=8788"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT_DIR=%~dp0"
set "UPDATE_SCRIPT=%SCRIPT_DIR%scripts\update_rog_model_service.ps1"

if not exist "%UPDATE_SCRIPT%" set "UPDATE_SCRIPT=%SCRIPT_DIR%update_rog_model_service.ps1"
if not exist "%UPDATE_SCRIPT%" (
    echo Missing update script: "%SCRIPT_DIR%scripts\update_rog_model_service.ps1" or "%SCRIPT_DIR%update_rog_model_service.ps1"
    exit /b 2
)

net session >nul 2>&1
if "%ERRORLEVEL%"=="0" (
    set "FIREWALL_FLAG=-AddFirewallRule"
) else (
    set "FIREWALL_FLAG="
    echo Not running as Administrator; Windows firewall rule will not be changed.
    echo If remote Macs cannot reach port %PORT%, rerun this file as Administrator.
)

echo Updating ROG SepsisCare model service...
echo DeployRoot=%DEPLOY_ROOT%
echo HostAddress=%HOST_ADDRESS%
echo Port=%PORT%

if "%SERVICE_TOKEN%"=="" (
    "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_SCRIPT%" -DeployRoot "%DEPLOY_ROOT%" -HostAddress %HOST_ADDRESS% -Port %PORT% %FIREWALL_FLAG%
) else (
    "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_SCRIPT%" -DeployRoot "%DEPLOY_ROOT%" -HostAddress %HOST_ADDRESS% -Port %PORT% -ServiceToken "%SERVICE_TOKEN%" %FIREWALL_FLAG%
)
if errorlevel 1 (
    echo.
    echo ROG actual training update or verification failed.
    exit /b 1
)

echo.
echo ROG actual ICU training update and verification completed.
echo Evidence JSON is written under "%DEPLOY_ROOT%\.runtime".
exit /b 0
