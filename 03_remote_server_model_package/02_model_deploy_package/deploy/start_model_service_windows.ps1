param(
    [ValidateSet("start", "stop", "restart", "status", "smoke", "doctor", "logs")]
    [string]$Command = "start",
    [string]$HostAddress = "0.0.0.0",
    [int]$Port = 8788,
    [string]$Python = "",
    [string]$ServiceToken = "",
    [switch]$AddFirewallRule
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RuntimeDir = Join-Path $RootDir ".runtime"
$LogFile = Join-Path $RuntimeDir "model_$Port.log"
$ErrLogFile = Join-Path $RuntimeDir "model_$Port.err.log"
$PidFile = Join-Path $RuntimeDir "model_$Port.pid"
$TokenFile = Join-Path $RuntimeDir "sepsiscare_service_token.txt"
$VenvDir = Join-Path $RootDir ".venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$DatabaseRoot = Join-Path $RootDir "runtime_data"
$ModelService = Join-Path $RootDir "deploy\model_service.py"
$Requirements = Join-Path $RootDir "deploy\requirements_model_deploy.txt"
$RuntimeDataAuditScript = Join-Path $RootDir "deploy\audit_runtime_data.py"
$RuntimeDataAuditReport = Join-Path $RuntimeDir "runtime_data_audit.json"

function Resolve-Python {
    if ($Python -ne "") {
        return $Python
    }
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return $pythonCmd.Source
    }
    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) {
        return $pyCmd.Source
    }
    throw "Python was not found. Install Python 3.10+ and enable 'Add python.exe to PATH'."
}

function Get-BaseUrl {
    $clientHost = $HostAddress
    if ($clientHost -eq "0.0.0.0") {
        $clientHost = "127.0.0.1"
    }
    return "http://${clientHost}:$Port"
}

function Resolve-ServiceToken {
    if ($ServiceToken -ne "") {
        return $ServiceToken
    }
    if ($env:SEPSISCARE_SERVICE_TOKEN) {
        return $env:SEPSISCARE_SERVICE_TOKEN
    }
    if (Test-Path $TokenFile) {
        $existingToken = (Get-Content -Path $TokenFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($existingToken -ne "") {
            return $existingToken
        }
    }
    return ""
}

function Get-AuthHeaders {
    $token = Resolve-ServiceToken
    if ($token -eq "") {
        return @{}
    }
    return @{ Authorization = "Bearer $token" }
}

function Test-Health {
    try {
        Invoke-RestMethod -Uri "$(Get-BaseUrl)/health" -TimeoutSec 5 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-PortListenerPids {
    $listenerPids = @()
    $netstatOutput = & netstat -ano -p tcp 2>$null
    foreach ($line in $netstatOutput) {
        if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$') {
            if ([int]$Matches[1] -eq $Port) {
                $listenerPids += [int]$Matches[2]
            }
        }
    }
    return $listenerPids | Select-Object -Unique
}

function Set-PidFileToPortListener {
    $listenerPids = @(Get-PortListenerPids)
    if ($listenerPids.Count -gt 0) {
        Set-Content -Path $PidFile -Value $listenerPids[0] -Encoding ASCII
        return $listenerPids[0]
    }
    return $null
}

function Invoke-RuntimeDataAudit {
    if (-not (Test-Path $RuntimeDataAuditScript)) {
        throw "Missing runtime data audit script: $RuntimeDataAuditScript"
    }
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    $pythonPath = Resolve-Python
    $auditOutput = & $pythonPath $RuntimeDataAuditScript $DatabaseRoot 2>&1
    $auditExit = $LASTEXITCODE
    $auditText = ($auditOutput | Out-String).Trim()
    Set-Content -Path $RuntimeDataAuditReport -Value $auditText -Encoding UTF8
    if ($auditExit -ne 0) {
        throw "runtime data audit failed: $RuntimeDataAuditReport"
    }
    try {
        $audit = $auditText | ConvertFrom-Json
    } catch {
        throw "runtime data audit returned invalid JSON: $RuntimeDataAuditReport"
    }
    if ($audit.ok -ne $true) {
        throw "runtime data audit failed: $RuntimeDataAuditReport"
    }
    Write-Host "runtime data audit: ok ($($audit.summary.violations) fatal violations, $($audit.summary.warnings) warnings)"
}

function Stop-ServiceProcess {
    $pidsToStop = @()
    if (Test-Path $PidFile) {
        $existingPid = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($existingPid) {
            $pidsToStop += [int]$existingPid
        }
    }
    $pidsToStop += @(Get-PortListenerPids)
    foreach ($processId in ($pidsToStop | Where-Object { $_ -and $_ -ne $PID } | Select-Object -Unique)) {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $processId -Force
        }
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (@(Get-PortListenerPids).Count -eq 0) {
            break
        }
        Start-Sleep -Seconds 1
    }
    $remainingPids = @(Get-PortListenerPids)
    if ($remainingPids.Count -gt 0) {
        throw "Port $Port is still held by PID(s): $($remainingPids -join ', ')"
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

function Add-TailscaleFirewallRule {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Warning "Skipping firewall rule because this PowerShell session is not running as Administrator."
        Write-Warning "Run an elevated PowerShell or add TCP port $Port for remote address 100.64.0.0/10 manually."
        return
    }

    $ruleName = "SepsisCare Model Service $Port Tailscale"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "firewall rule already exists: $ruleName"
        return
    }

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -RemoteAddress "100.64.0.0/10" `
        -Profile Any | Out-Null
    Write-Host "firewall rule added: $ruleName"
}

function Invoke-Doctor {
    $requiredFiles = @(
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\trajectory_encoder.pt",
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\phenotype_readout.pkl",
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\transition_probs.npy",
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\transition_init_probs.npy",
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\trajectory_encoder_report.json",
        "models\cloud_production\s7_phenotype_contrastive_full_20260516\s7_all_source_training_summary.json",
        "runtime_data\history_patients.json",
        "runtime_data\history_details.json",
        "deploy\model_service.py",
        "deploy\audit_runtime_data.py"
    )
    foreach ($relativePath in $requiredFiles) {
        $path = Join-Path $RootDir $relativePath
        if (-not (Test-Path $path)) {
            throw "Missing required file: $path"
        }
    }
    $pythonPath = Resolve-Python
    Write-Host "model files: ok"
    Invoke-RuntimeDataAudit
    Write-Host "python: $pythonPath"
    Write-Host "bind: ${HostAddress}:$Port"
    Write-Host "health: $(Get-BaseUrl)/health"
    Write-Host "predict: $(Get-BaseUrl)/predict/predict"
}

function Ensure-Venv {
    $pythonPath = Resolve-Python
    if (-not (Test-Path $VenvPython)) {
        Write-Host "creating virtualenv: $VenvDir"
        if ((Split-Path -Leaf $pythonPath) -ieq "py.exe") {
            & $pythonPath -3 -m venv $VenvDir
        } else {
            & $pythonPath -m venv $VenvDir
        }
    }
    & $VenvPython -m pip install --upgrade pip | Out-Null
    & $VenvPython -m pip install -r $Requirements | Out-Null
}

function Start-ServiceProcess {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    $effectiveServiceToken = Resolve-ServiceToken
    if ($effectiveServiceToken -ne "") {
        $env:SEPSISCARE_SERVICE_TOKEN = $effectiveServiceToken
    }
    Invoke-Doctor | Out-Null
    if ($AddFirewallRule) {
        Add-TailscaleFirewallRule
    }
    if (Test-Health) {
        $listenerPid = Set-PidFileToPortListener
        Write-Host "already online: $(Get-BaseUrl)/health"
        if ($listenerPid) {
            Write-Host "pid: $listenerPid"
        }
        return
    }
    Ensure-Venv
    $env:SEPSISCARE_DEPLOY_ROOT = $RootDir
    $env:SEPSISCARE_MODEL_HOST = $HostAddress
    $env:SEPSISCARE_MODEL_PORT = [string]$Port
    $env:SEPSISCARE_RUNTIME_ROOT = $RuntimeDir
    $env:SEPSISCARE_DATABASE_ROOT = $DatabaseRoot
    $env:SEPSISCARE_ALLOW_REAL_TRAINING = "1"
    if (-not $env:SEPSISCARE_DEVICE) {
        $env:SEPSISCARE_DEVICE = "cuda"
    }
    if (-not $env:SEPSISCARE_TRAINING_DEVICE) {
        $env:SEPSISCARE_TRAINING_DEVICE = $env:SEPSISCARE_DEVICE
    }
    $args = @($ModelService, "--host", $HostAddress, "--port", [string]$Port)
    $proc = Start-Process -FilePath $VenvPython -ArgumentList $args -WorkingDirectory $RootDir -RedirectStandardOutput $LogFile -RedirectStandardError $ErrLogFile -PassThru -WindowStyle Hidden
    Set-Content -Path $PidFile -Value $proc.Id
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Health) {
            $listenerPid = Set-PidFileToPortListener
            Write-Host "online: $(Get-BaseUrl)/health"
            Write-Host "predict: $(Get-BaseUrl)/predict/predict"
            if ($listenerPid) {
                Write-Host "pid: $listenerPid"
            }
            Write-Host "log: $LogFile"
            Write-Host "err: $ErrLogFile"
            return
        }
        Start-Sleep -Seconds 1
    }
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail 80
    }
    if (Test-Path $ErrLogFile) {
        Get-Content $ErrLogFile -Tail 80
    }
    throw "model service did not become healthy: $(Get-BaseUrl)/health"
}

function Invoke-Smoke {
    $base = Get-BaseUrl
    $headers = Get-AuthHeaders
    Invoke-RestMethod -Uri "$base/health" -TimeoutSec 8 | Out-Null
    $probe = Invoke-RestMethod -Uri "$base/predict/predict" -Headers $headers -TimeoutSec 8
    if ($probe.ok -ne $true) {
        throw "GET /predict/predict did not return ok=true"
    }
    $body = @{ vitals = @{ map = 68 }; labs = @{ lactate = 3.2 } } | ConvertTo-Json -Depth 5
    $prediction = Invoke-RestMethod -Uri "$base/predict/predict" -Method Post -Headers $headers -Body $body -ContentType "application/json" -TimeoutSec 8
    if (-not $prediction.latest) {
        throw "POST /predict/predict did not return latest"
    }
    Write-Host "ok GET /health"
    Write-Host "ok GET /predict/predict"
    Write-Host "ok POST /predict/predict"
}

switch ($Command) {
    "doctor" { Invoke-Doctor }
    "start" { Start-ServiceProcess }
    "stop" { Stop-ServiceProcess; Write-Host "stopped: $PidFile" }
    "restart" { Stop-ServiceProcess; Start-ServiceProcess }
    "status" {
        if (Test-Health) {
            Set-PidFileToPortListener | Out-Null
            Write-Host "online: $(Get-BaseUrl)/health"
        } else {
            Write-Host "offline: $(Get-BaseUrl)/health"
        }
        if (Test-Path $PidFile) {
            Write-Host "pid: $(Get-Content $PidFile)"
        }
        Write-Host "log: $LogFile"
        Write-Host "err: $ErrLogFile"
    }
    "smoke" { Invoke-Smoke }
    "logs" {
        if (Test-Path $LogFile) {
            Get-Content $LogFile -Tail 120 -Wait
        } else {
            Write-Host "log file not found: $LogFile"
        }
        if (Test-Path $ErrLogFile) {
            Get-Content $ErrLogFile -Tail 120
        }
    }
}
