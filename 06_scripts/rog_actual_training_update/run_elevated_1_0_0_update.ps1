param(
    [string]$BundleRoot = "D:\PredictionService\codex_deploy\rog_actual_training_update_1_0_0\rog_actual_training_update",
    [string]$DeployRoot = "D:\PredictionService\models\production\02_model_deploy_package",
    [string]$HostAddress = "0.0.0.0",
    [int]$Port = 8788,
    [string]$DeployStage = "D:\PredictionService\codex_deploy"
)

$ErrorActionPreference = "Stop"
$Log = Join-Path $DeployStage "run_elevated_1_0_0_update.log"
$Done = Join-Path $DeployStage "run_elevated_1_0_0_update.done.json"

New-Item -ItemType Directory -Force -Path $DeployStage | Out-Null
Start-Transcript -Path $Log -Force | Out-Null

try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Elevated deployment script is not running as Administrator."
    }

    $env:SEPSISCARE_ALLOW_REAL_TRAINING = "1"
    $UpdateScript = Join-Path $BundleRoot "scripts\update_rog_model_service.ps1"
    if (-not (Test-Path $UpdateScript)) {
        throw "Missing update script: $UpdateScript"
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $UpdateScript `
        -DeployRoot $DeployRoot `
        -HostAddress $HostAddress `
        -Port $Port `
        -AddFirewallRule

    $baseUrl = "http://127.0.0.1:$Port"
    $openApiInfo = (Invoke-RestMethod -UseBasicParsing -Uri "$baseUrl/openapi.json" -TimeoutSec 10).info
    $remoteOpsStatus = Invoke-RestMethod -UseBasicParsing -Uri "$baseUrl/api/admin/remote-ops/status" -TimeoutSec 10

    $result = [ordered]@{
        ok = $true
        finished_at = [DateTimeOffset]::Now.ToString("o")
        whoami = (whoami)
        is_admin = $isAdmin
        base_url = $baseUrl
        openapi_info = $openApiInfo
        remote_ops_status = $remoteOpsStatus
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $Done -Encoding UTF8
} catch {
    $result = [ordered]@{
        ok = $false
        finished_at = [DateTimeOffset]::Now.ToString("o")
        whoami = (whoami)
        error = $_.Exception.Message
        script_stack_trace = $_.ScriptStackTrace
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -Path $Done -Encoding UTF8
    throw
} finally {
    Stop-Transcript | Out-Null
}
