param(
    [string]$ZipPath = "",
    [string]$TargetRoot = "D:\PredictionService\models\production",
    [int]$Port = 8788,
    [switch]$AddFirewallRule
)

$ErrorActionPreference = "Stop"

function Find-UpdateZip {
    if ($ZipPath -ne "") {
        if (-not (Test-Path $ZipPath)) {
            throw "ZipPath not found: $ZipPath"
        }
        return (Resolve-Path $ZipPath).Path
    }

    $roots = @(
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        $env:USERPROFILE
    ) | Where-Object { Test-Path $_ }

    $matches = foreach ($root in $roots) {
        Get-ChildItem $root -Filter "SepsisCare_model_deploy_package_deepseek_v4_flash_*.zip" -File -Recurse -ErrorAction SilentlyContinue
    }

    $latest = $matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        throw "No SepsisCare DeepSeek update zip found under Downloads/Desktop/user profile."
    }
    return $latest.FullName
}

function Stop-ModelService {
    $startScript = Join-Path $TargetRoot "02_model_deploy_package\deploy\start_model_service_windows.ps1"
    if (Test-Path $startScript) {
        powershell -ExecutionPolicy Bypass -File $startScript stop -Port $Port
    }

    $escapedRoot = [regex]::Escape((Join-Path $TargetRoot "02_model_deploy_package"))
    Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -match "model_service.py" -and $_.CommandLine -match $escapedRoot } |
        ForEach-Object {
            Write-Host "stopping leftover model_service.py pid=$($_.ProcessId)"
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Backup-CurrentService {
    $packageDir = Join-Path $TargetRoot "02_model_deploy_package"
    $currentService = Join-Path $packageDir "deploy\model_service.py"
    if (-not (Test-Path $currentService)) {
        return
    }
    $backupDir = Join-Path $packageDir ".runtime\backups"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    Copy-Item $currentService (Join-Path $backupDir "model_service.py.$stamp.bak") -Force
}

function Restart-ModelService {
    $startScript = Join-Path $TargetRoot "02_model_deploy_package\deploy\start_model_service_windows.ps1"
    if (-not (Test-Path $startScript)) {
        throw "Missing Windows start script after update: $startScript"
    }

    $args = @("restart", "-HostAddress", "0.0.0.0", "-Port", [string]$Port)
    if ($AddFirewallRule) {
        $args += "-AddFirewallRule"
    }
    powershell -ExecutionPolicy Bypass -File $startScript @args
}

function Invoke-Json {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $uri = "http://127.0.0.1:$Port$Path"
    if ($null -eq $Body) {
        return Invoke-RestMethod -Uri $uri -Method $Method -TimeoutSec 45
    }
    $json = $Body | ConvertTo-Json -Depth 10
    return Invoke-RestMethod -Uri $uri -Method $Method -Body $json -ContentType "application/json" -TimeoutSec 45
}

function Verify-DeepSeek {
    $configBody = @{
        model = "deepseek-v4-flash"
        base_url = "https://api.deepseek.com"
        timeout_seconds = "30"
    }
    $saved = Invoke-Json -Method Post -Path "/api/config/deepseek" -Body $configBody
    if ($saved.model -ne "deepseek-v4-flash") {
        throw "DeepSeek config POST did not save expected model."
    }

    $config = Invoke-Json -Method Get -Path "/api/config/deepseek"
    if ($config.configured -ne $true) {
        throw "DeepSeek config is not marked configured."
    }

    $assistant = Invoke-Json -Method Post -Path "/api/ai/assistant-chat" -Body @{
        question = "DeepSeek Windows update verification: reply with 连接测试收到"
        context = @{}
    }
    if (-not $assistant.answer) {
        throw "assistant-chat did not return an answer."
    }

    Invoke-Json -Method Get -Path "/api/ai/analysis" | Out-Null
    Invoke-Json -Method Post -Path "/api/family/chat" -Body @{
        patient_ref = "SC-12000"
        question = "DeepSeek Windows update verification"
    } | Out-Null
    Invoke-Json -Method Post -Path "/api/ai/llm-diagnose" -Body @{
        vitals = @{ map = 70; heart_rate = 98 }
        labs = @{ lactate = 2.4 }
    } | Out-Null
    Invoke-Json -Method Post -Path "/api/ai/explain" -Body @{
        term = "MAP"
        context = "DeepSeek Windows update verification"
    } | Out-Null

    Write-Host "DeepSeek verification passed: model=$($config.model), configured=$($config.configured), answer=$($assistant.answer)"
}

$zip = Find-UpdateZip
$targetPackage = Join-Path $TargetRoot "02_model_deploy_package"
Write-Host "update zip: $zip"
Write-Host "target package: $targetPackage"

New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
Stop-ModelService
Backup-CurrentService
Expand-Archive -Path $zip -DestinationPath $TargetRoot -Force
Restart-ModelService
Verify-DeepSeek

Write-Host "SepsisCare DeepSeek update completed."
