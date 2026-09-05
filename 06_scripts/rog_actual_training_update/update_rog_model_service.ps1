param(
    [string]$DeployRoot = "D:\PredictionService\models\production\02_model_deploy_package",
    [string]$HostAddress = "0.0.0.0",
    [int]$Port = 8788,
    [string]$ServiceToken = "",
    [switch]$AddFirewallRule,
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ((Split-Path -Leaf $ScriptDir) -ieq "scripts") {
    $BundleRoot = Resolve-Path (Join-Path $ScriptDir "..")
} else {
    $BundleRoot = Resolve-Path $ScriptDir
}
$SourceDeployCandidates = @(
    (Join-Path $BundleRoot "deploy"),
    (Join-Path $BundleRoot "..\..\03_remote_server_model_package\02_model_deploy_package\deploy")
)
$SourceDeploy = ""
foreach ($Candidate in $SourceDeployCandidates) {
    if (Test-Path $Candidate) {
        $SourceDeploy = (Resolve-Path $Candidate).Path
        break
    }
}
if ($SourceDeploy -eq "") {
    throw "Missing source deploy folder. Expected a bundled deploy\ folder or the full SepsisCare delivery tree."
}
$TargetDeploy = Join-Path $DeployRoot "deploy"
$RuntimeDir = Join-Path $DeployRoot ".runtime"
$BackupRoot = Join-Path $RuntimeDir "codex_update_backups"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupDir = Join-Path $BackupRoot "actual-training-$Stamp"
$TokenFile = Join-Path $RuntimeDir "sepsiscare_service_token.txt"

function Require-File([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Missing required file: $Path"
    }
}

Require-File (Join-Path $SourceDeploy "audit_runtime_data.py")
Require-File (Join-Path $SourceDeploy "model_service.py")
Require-File (Join-Path $SourceDeploy "requirements_model_deploy.txt")
Require-File (Join-Path $SourceDeploy "start_model_service_windows.ps1")
Require-File (Join-Path $SourceDeploy "test_model_service.py")
Require-File (Join-Path $SourceDeploy "test_verify_artifact_bundle.py")
Require-File (Join-Path $SourceDeploy "verify_artifact_bundle.py")
Require-File (Join-Path $DeployRoot "models\cloud_production\s7_phenotype_contrastive_full_20260516\trajectory_encoder_report.json")

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
New-Item -ItemType Directory -Force -Path $TargetDeploy | Out-Null
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

function New-ServiceToken {
    return ("{0}{1}" -f ([guid]::NewGuid().ToString("N")), ([guid]::NewGuid().ToString("N")))
}

function Resolve-ServiceToken {
    if ($ServiceToken -ne "") {
        return $ServiceToken
    }
    if ($env:SEPSISCARE_SERVICE_TOKEN) {
        return $env:SEPSISCARE_SERVICE_TOKEN
    }
    if (Test-Path $TokenFile) {
        $existing = (Get-Content -Path $TokenFile -Raw -Encoding UTF8).Trim()
        if ($existing -ne "") {
            return $existing
        }
    }
    $generated = New-ServiceToken
    Set-Content -Path $TokenFile -Value $generated -Encoding ASCII
    return $generated
}

$EffectiveServiceToken = Resolve-ServiceToken
$env:SEPSISCARE_SERVICE_TOKEN = $EffectiveServiceToken

$Files = @(
    "audit_runtime_data.py",
    "model_service.py",
    "requirements_model_deploy.txt",
    "start_model_service_windows.ps1",
    "test_model_service.py",
    "test_verify_artifact_bundle.py",
    "verify_artifact_bundle.py"
)

foreach ($Name in $Files) {
    $Target = Join-Path $TargetDeploy $Name
    if (Test-Path $Target) {
        Copy-Item -Path $Target -Destination (Join-Path $BackupDir $Name) -Force
    }
    Copy-Item -Path (Join-Path $SourceDeploy $Name) -Destination $Target -Force
}

Write-Host "updated deploy files under $TargetDeploy"
Write-Host "backup: $BackupDir"

if (-not $SkipRestart) {
    $StartScript = Join-Path $TargetDeploy "start_model_service_windows.ps1"
    $RestartArgs = @("restart", "-HostAddress", $HostAddress, "-Port", [string]$Port, "-ServiceToken", $EffectiveServiceToken)
    if ($AddFirewallRule) {
        $RestartArgs += "-AddFirewallRule"
    }
    & powershell -ExecutionPolicy Bypass -File $StartScript @RestartArgs
}

$BaseUrl = "http://127.0.0.1:$Port"
$VerifierCandidates = @(
    (Join-Path $ScriptDir "verify_rog_actual_training.ps1"),
    (Join-Path $BundleRoot "scripts\verify_rog_actual_training.ps1"),
    (Join-Path $BundleRoot "verify_rog_actual_training.ps1")
)
$Verifier = ""
foreach ($Candidate in $VerifierCandidates) {
    if (Test-Path $Candidate) {
        $Verifier = (Resolve-Path $Candidate).Path
        break
    }
}
if ($Verifier -eq "") {
    throw "Missing verify_rog_actual_training.ps1"
}
Write-Host "remote ops bearer token file: $TokenFile"
Write-Host "Use this token through SEPSISCARE_SERVICE_TOKEN on the Mac; the token value is not printed."
& powershell -ExecutionPolicy Bypass -File $Verifier -BaseUrl $BaseUrl -DeployRoot $DeployRoot -ServiceToken $EffectiveServiceToken
