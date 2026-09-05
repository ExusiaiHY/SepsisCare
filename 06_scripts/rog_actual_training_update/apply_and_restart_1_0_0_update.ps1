param(
    [string]$Stage = "D:\PredictionService\codex_deploy",
    [string]$ZipName = "rog_actual_training_update_20260605.zip",
    [string]$ExpectedSha256 = "",
    [string]$DeployRoot = "D:\PredictionService\models\production\02_model_deploy_package",
    [int]$Port = 8788
)

$ErrorActionPreference = "Continue"
$Zip = Join-Path $Stage $ZipName
$Extract = Join-Path $Stage "rog_actual_training_update_1_0_0"

if ($ExpectedSha256 -ne "") {
    $hash = (Get-FileHash -Algorithm SHA256 -Path $Zip).Hash.ToLowerInvariant()
    Write-Output "REMOTE_ZIP_SHA256=$hash"
    if ($hash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "remote ZIP SHA mismatch"
    }
}

Remove-Item -Recurse -Force -Path $Extract -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Extract | Out-Null
Expand-Archive -Path $Zip -DestinationPath $Extract -Force

$BundleRoot = Join-Path $Extract "rog_actual_training_update"
Select-String -Path (Join-Path $BundleRoot "deploy\model_service.py") -Pattern 'SERVICE_VERSION = ' |
    Select-Object -First 1 |
    ForEach-Object { Write-Output "BUNDLE_VERSION=$($_.Line.Trim())" }
Select-String -Path (Join-Path $BundleRoot "deploy\start_model_service_windows.ps1") -Pattern 'Resolve-ServiceToken|Get-PortListenerPids|Set-PidFileToPortListener' |
    ForEach-Object { Write-Output "BUNDLE_START_FEATURE=$($_.Line.Trim())" }

$UpdateScript = Join-Path $BundleRoot "scripts\update_rog_model_service.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $UpdateScript -DeployRoot $DeployRoot -HostAddress 0.0.0.0 -Port $Port -SkipRestart 2>&1 |
    ForEach-Object { $_ }
Write-Output "UPDATE_EXIT=$LASTEXITCODE"

$StartScript = Join-Path $DeployRoot "deploy\start_model_service_windows.ps1"
Select-String -Path $StartScript -Pattern 'Resolve-ServiceToken|Get-PortListenerPids|Set-PidFileToPortListener' |
    ForEach-Object { Write-Output "TARGET_START_FEATURE=$($_.Line.Trim())" }

$lines = @(cmd /c "netstat -ano | findstr LISTENING | findstr :$Port")
$listenProcessId = $null
foreach ($line in $lines) {
    if ($line -match ":$Port\s+.*LISTENING\s+(\d+)") {
        $listenProcessId = [int]$Matches[1]
        break
    }
}
Write-Output "LISTEN_PID_BEFORE_RESTART=$listenProcessId"
if ($listenProcessId) {
    Set-Content -Path (Join-Path $DeployRoot ".runtime\model_$Port.pid") -Value $listenProcessId -Encoding ASCII
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $StartScript restart -HostAddress 0.0.0.0 -Port $Port 2>&1 |
    ForEach-Object { $_ }
Write-Output "RESTART_EXIT=$LASTEXITCODE"

for ($i = 0; $i -lt 40; $i++) {
    try {
        $info = (Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/openapi.json" -TimeoutSec 5).info
        Write-Output "POLL=$i VERSION=$($info.version)"
        if ($info.version -eq "1.0.0") {
            break
        }
    } catch {
        Write-Output "POLL=$i ERR=$($_.Exception.Message)"
    }
    Start-Sleep -Seconds 3
}

Write-Output "FINAL_NETSTAT_BEGIN"
cmd /c "netstat -ano | findstr LISTENING | findstr :$Port"
Write-Output "FINAL_NETSTAT_END"
Write-Output "FINAL_PIDFILE_BEGIN"
Get-Content -Path (Join-Path $DeployRoot ".runtime\model_$Port.pid") -ErrorAction SilentlyContinue
Write-Output "FINAL_PIDFILE_END"
Write-Output "FINAL_OPENAPI_BEGIN"
try {
    (Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/openapi.json" -TimeoutSec 8).info | ConvertTo-Json -Depth 4
} catch {
    Write-Output "OPENAPI_ERR=$($_.Exception.Message)"
}
Write-Output "FINAL_OPENAPI_END"
Write-Output "FINAL_REMOTEOPS_LOOPBACK_BEGIN"
$token = (Get-Content -Path (Join-Path $DeployRoot ".runtime\sepsiscare_service_token.txt") -Raw -ErrorAction SilentlyContinue).Trim()
try {
    Invoke-RestMethod -UseBasicParsing -Uri "http://127.0.0.1:$Port/api/admin/remote-ops/status" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 |
        ConvertTo-Json -Depth 10
} catch {
    Write-Output "REMOTEOPS_ERR=$($_.Exception.Message)"
}
Write-Output "FINAL_REMOTEOPS_LOOPBACK_END"
