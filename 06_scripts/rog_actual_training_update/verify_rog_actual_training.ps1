param(
    [string]$BaseUrl = "http://127.0.0.1:8788",
    [string]$DeployRoot = "D:\PredictionService\models\production\02_model_deploy_package",
    [string]$EvidencePath = "",
    [string]$ServiceToken = ""
)

$ErrorActionPreference = "Stop"
$ModelId = "s7_phenotype_contrastive_full_20260516"
$AdapterPath = Join-Path $DeployRoot "models\cloud_production\$ModelId\incremental_icu_adapter.json"
$RuntimeDir = Join-Path $DeployRoot ".runtime"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-JsonPost([string]$Uri, [object]$Payload) {
    $Body = $Payload | ConvertTo-Json -Depth 12
    return Invoke-RestMethod -Uri $Uri -Method Post -Headers (Get-AuthHeaders) -Body $Body -ContentType "application/json" -TimeoutSec 20
}

function Get-AuthHeaders {
    $token = $ServiceToken
    if ($token -eq "" -and $env:SEPSISCARE_SERVICE_TOKEN) {
        $token = $env:SEPSISCARE_SERVICE_TOKEN
    }
    if ($token -eq "") {
        return @{}
    }
    return @{ Authorization = "Bearer $token" }
}

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
if ($EvidencePath -eq "") {
    $EvidencePath = Join-Path $RuntimeDir ("rog_actual_training_evidence_{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$OpenApi = Invoke-RestMethod -Uri "$BaseUrl/openapi.json" -Headers (Get-AuthHeaders) -TimeoutSec 10
$PathNames = @($OpenApi.paths.PSObject.Properties.Name)
Assert-True ($PathNames -contains "/api/icu/timeseries/status") "ROG service does not expose /api/icu/timeseries/status"
Assert-True ($PathNames -contains "/api/icu/timeseries/ingest") "ROG service does not expose /api/icu/timeseries/ingest"

$Before = Invoke-RestMethod -Uri "$BaseUrl/api/icu/timeseries/status?limit=2" -Headers (Get-AuthHeaders) -TimeoutSec 10
Assert-True ($Before.ok -eq $true) "before status did not return ok=true"
$BeforeTotal = [int]$Before.total_events

$Stamp = Get-Date -Format "yyyyMMddTHHmmss"
$Payload = @{
    source = "codex-rog-actual-training-check"
    events = @(
        @{
            patient_ref = "ROG-ACTUAL-$Stamp-A"
            bed_no = "ROG-ICU-VERIFY-01"
            timestamp = [DateTimeOffset]::Now.ToString("o")
            ward = "ROG ICU"
            vitals = @{
                heart_rate = 124
                map = 57
                resp_rate = 30
                spo2 = 89
                temperature = 39.1
                gcs = 10
            }
            labs = @{
                lactate = 5.2
                wbc = 20.1
                creatinine = 2.0
                platelet = 108
            }
            device = @{
                vendor = "demo-monitor"
                model = "ICU-Link"
                serial = "ROG-CODEX-VERIFY-A"
            }
        },
        @{
            patient_ref = "ROG-ACTUAL-$Stamp-B"
            bed_no = "ROG-ICU-VERIFY-01"
            timestamp = [DateTimeOffset]::Now.AddSeconds(30).ToString("o")
            ward = "ROG ICU"
            vitals = @{
                heart_rate = 118
                map = 60
                resp_rate = 28
                spo2 = 91
                temperature = 38.7
                gcs = 11
            }
            labs = @{
                lactate = 4.6
                wbc = 18.8
                creatinine = 1.8
                platelet = 116
            }
            device = @{
                vendor = "demo-monitor"
                model = "ICU-Link"
                serial = "ROG-CODEX-VERIFY-B"
            }
        }
    )
}

$Ingest = Invoke-JsonPost "$BaseUrl/api/icu/timeseries/ingest" $Payload
Assert-True ($Ingest.ok -eq $true) "ingest did not return ok=true"
Assert-True ([int]$Ingest.accepted -ge 2) "ingest did not accept the new ICU events"
Assert-True ([int]$Ingest.total_events -ge ($BeforeTotal + 2)) "total_events did not increase after ingest"
Assert-True ($Ingest.training_ready -eq $true) "training_ready was not true after ingest"

$Training = Invoke-JsonPost "$BaseUrl/api/training/command" @{ action = "continue_training"; payload = @{ source = "rog-verification" } }
Assert-True ($Training.ok -eq $true) "continue_training did not return ok=true"
Assert-True ($Training.task_status -eq "trained") "continue_training did not set task_status=trained"
Assert-True ([int]$Training.metrics.actual_training_examples -ge 2) "training metrics did not report actual_training_examples >= 2"
Assert-True ([string]$Training.metrics.incremental_adapter_path -eq "managed-runtime/models/incremental_icu_adapter.json") "training metrics did not report the adapter path"
$OutputText = (($Training.output | ForEach-Object { [string]$_ }) -join "`n")
Assert-True ($OutputText.Contains("实际 adapter 增量训练")) "training output did not confirm actual adapter incremental training"

$After = Invoke-RestMethod -Uri "$BaseUrl/api/icu/timeseries/status?limit=2" -Headers (Get-AuthHeaders) -TimeoutSec 10
Assert-True ($After.ok -eq $true) "after status did not return ok=true"
Assert-True ([int]$After.trained_event_count -eq [int]$After.total_events) "trained_event_count does not match total_events after training"
Assert-True ($After.training_ready -eq $false) "training_ready is still true after training"

Assert-True (Test-Path $AdapterPath) "adapter file was not written: $AdapterPath"
$Adapter = Get-Content -Path $AdapterPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ([int]$Adapter.training_examples -ge 2) "adapter training_examples is less than 2"
Assert-True ([int]$Adapter.optimizer_steps -gt 0) "adapter optimizer_steps was not incremented"
$HeartRateWeight = $Adapter.weights.'vitals.heart_rate'
$LactateWeight = $Adapter.weights.'labs.lactate'
Assert-True ($null -ne $HeartRateWeight) "adapter is missing vitals.heart_rate weight"
Assert-True ($null -ne $LactateWeight) "adapter is missing labs.lactate weight"
Assert-True ([double]$HeartRateWeight -ne 0.0) "vitals.heart_rate weight was not updated"
Assert-True ([double]$LactateWeight -ne 0.0) "labs.lactate weight was not updated"

$Evidence = @{
    ok = $true
    base_url = $BaseUrl
    deploy_root = $DeployRoot
    verified_at = [DateTimeOffset]::Now.ToString("o")
    before = $Before
    ingest = $Ingest
    training = @{
        task_status = $Training.task_status
        output = $Training.output
        metrics = $Training.metrics
        artifacts = $Training.artifacts
    }
    after = $After
    adapter = @{
        path = $AdapterPath
        model_revision = $Adapter.model_revision
        training_examples = $Adapter.training_examples
        optimizer_steps = $Adapter.optimizer_steps
        loss = $Adapter.loss
        data_sha256 = $Adapter.data_sha256
        weights = $Adapter.weights
    }
}

$Evidence | ConvertTo-Json -Depth 20 | Set-Content -Path $EvidencePath -Encoding UTF8
Write-Host "ROG actual ICU training verified"
Write-Host "before_total=$BeforeTotal accepted=$($Ingest.accepted) after_total=$($After.total_events) trained_event_count=$($After.trained_event_count)"
Write-Host "adapter=$AdapterPath"
Write-Host "evidence=$EvidencePath"
