# SepsisCare Cloud Model Deploy Package

Version: 2026-05-18

This package contains the cloud production model body, a lightweight patient
database, and a Windows-ready model server that can serve both the training
terminal contract and the macOS app API smoke contract.

## Contents

- `models/cloud_production/s7_phenotype_contrastive_full_20260516/`
  final S7 model weights, phenotype readout, transition matrices, split
  manifests, and training summary.
- `config/s7_phenotype_contrastive_full_20260516.yaml`
  training/deployment configuration.
- `reports/`
  final training report, comparison tables, curves, and figures.
- `runtime_data/`
  packaged de-identified history database used by the remote model server.
- `deploy/model_service.py`
  remote Windows model server. It implements `POST /api/training/command`, artifact
  download, model status, and the macOS-compatible patient/history/admin/AI
  endpoints needed by the desktop app smoke suite.
- `deploy/remote_server_one_click_deploy.sh`
  one-command Linux/macOS deployment script with `doctor`, `start`,
  `status`, `smoke`, `stop`, and `logs`.
- `scripts/`, `s6/`, `s7/`
  minimal training code needed to relaunch S7 training when full data and GPU
  resources are available.

## One-Command Start

```bash
cd 02_model_deploy_package
export SEPSISCARE_SERVICE_TOKEN="$(openssl rand -hex 24)"
export SEPSISCARE_ARTIFACT_SIGNING_KEY="$(openssl rand -hex 32)"
SEPSISCARE_MODEL_HOST=0.0.0.0 SEPSISCARE_MODEL_PORT=8788 bash deploy/remote_server_one_click_deploy.sh restart
SEPSISCARE_SERVICE_TOKEN="$SEPSISCARE_SERVICE_TOKEN" bash deploy/remote_server_one_click_deploy.sh smoke
```

Keep `SEPSISCARE_SERVICE_TOKEN` out of Git and shell history where possible. Remote sensitive endpoints, training commands, model predictions, patient/history data, and artifact downloads require this Bearer token when the client is not loopback. Token values must be non-placeholder text with at least 16 characters; weak values such as demo passwords, `password`, `token`, or copied placeholder text make remote sensitive endpoints fail closed.

`SEPSISCARE_ARTIFACT_SIGNING_KEY` is optional but recommended for remote
deployments. When set, downloadable model artifact ZIPs include
`MANIFEST.sha256` plus `MANIFEST.sha256.hmac`; the HMAC signs the manifest so a
client with the same release key can detect modified artifact contents. Keep
this key out of Git, logs, shell history, and client bundles.

`/api/artifacts/latest` rebuilds the ZIP from the current model/report roots
before serving it, skips symlinked files, and excludes runtime logs/config so a
stale cached bundle or indirect link to a secret file is not treated as trusted
release evidence.

After downloading an artifact, verify it with:

```bash
python3 deploy/verify_artifact_bundle.py path/to/sepsiscare_model_artifacts_latest.zip --hmac-key-env SEPSISCARE_ARTIFACT_SIGNING_KEY
```

`script/deploy_model_to_remote_server.sh pull-artifacts` runs this verifier automatically
when `SEPSISCARE_ARTIFACT_SIGNING_KEY` is set locally.

## Windows / Tailscale Start

On Windows, unzip the package and run PowerShell from the extracted
`02_model_deploy_package` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\start_model_service_windows.ps1 restart -HostAddress 0.0.0.0 -Port 8788 -AddFirewallRule
powershell -ExecutionPolicy Bypass -File .\deploy\start_model_service_windows.ps1 smoke -HostAddress 127.0.0.1 -Port 8788
```

## DeepSeek V4 Flash

After the updated service is running, configure DeepSeek/OpenAI-compatible chat
from the macOS app Settings page or with PowerShell:

```powershell
$body = @{
  api_key = $env:DEEPSEEK_API_KEY
  model = "deepseek-v4-flash"
  base_url = "https://api.deepseek.com"
  timeout_seconds = "20"
} | ConvertTo-Json
Invoke-RestMethod -Uri "http://127.0.0.1:8788/api/config/deepseek" -Method Post -Body $body -ContentType "application/json"
```

For a local OpenAI-compatible server such as vLLM, LM Studio, or Ollama, set
`base_url` to that local service root or `/v1` URL. API keys are optional for
local compatible servers. For SSRF and data-exfiltration resistance, external
LLM URLs must use public HTTPS endpoints; plain HTTP is accepted only for
loopback local compatible servers such as `http://127.0.0.1:8000/v1`.
Private, link-local, metadata-service, or credential-bearing URLs are rejected
and normalized back to the default DeepSeek endpoint without logging the raw
rejected URL.

Default service address:

```text
http://SERVER_IP:8788
```

Configure the SepsisCare client training terminal with that address and switch
to production mode. The local client will forward actions to:

```text
http://SERVER_IP:8788/api/training/command
```

The same server can also be used as an API target for the existing macOS
endpoints:

```bash
curl -H "Authorization: Bearer $SEPSISCARE_SERVICE_TOKEN" http://SERVER_IP:8788/api/patients?page=1\\&per_page=3
curl -H "Authorization: Bearer $SEPSISCARE_SERVICE_TOKEN" http://SERVER_IP:8788/api/history/patients?page=1\\&per_page=3
```

## Health Check

```bash
curl http://127.0.0.1:8788/health
```

The response should include:

```json
{
  "ok": true,
  "model_id": "s7_phenotype_contrastive_full_20260516"
}
```

## Real Training Mode

The service now has two training paths:

1. ICU time-series incremental adapter training. New de-identified numeric ICU
   events are written to `.runtime/icu_timeseries.jsonl` by
   `POST /api/icu/timeseries/ingest`. `POST /api/training/command` with
   `{"action":"continue_training"}` reads only events that have not been
   trained yet, updates
   `models/cloud_production/s7_phenotype_contrastive_full_20260516/incremental_icu_adapter.json`,
   and returns `actual_training_examples`, `incremental_adapter_loss`,
   `incremental_adapter_path`, `total_events`, and `trained_event_count`.
2. Full S7 retraining. This is still protected because it can be expensive and
   requires the original training datasets and GPU environment.

A deployment is not considered verified by HTTP 200 alone. Verify that
`accepted > 0`, `total_events` increases, `training_ready` becomes true after
ingest, `continue_training` reports actual adapter training, the adapter JSON
contains nonzero weights, and after training `trained_event_count == total_events`
with `training_ready == false`.

The default service accepts continue/pause/download/log commands and returns
real packaged model metrics, but it does not launch expensive full S7 retraining
automatically.

To permit actual S7 retraining on a prepared GPU server:

```bash
export SEPSISCARE_ALLOW_REAL_TRAINING=1
export SEPSISCARE_MODEL_PORT=8788
bash deploy/remote_server_one_click_deploy.sh restart
```

Real retraining also requires the full source data directories referenced by
`config/s7_phenotype_contrastive_full_20260516.yaml`. The final course package
contains the trained model body and reports, not the full raw ICU datasets.

## Final Model Results

Primary production model:
`s7_phenotype_contrastive_full_20260516`

- Training data: 347,634 patients from PhysioNet 2012, PhysioNet 2019,
  MIMIC-IV, and eICU.
- GPUs used: 7.
- Method: source-balanced S7 trajectory encoder, missingness-aware GRU,
  phenotype cross-entropy head, supervised contrastive regularization, and
  transition-matrix post-processing.
- Macro F1: 0.956.
- Encoder-only macro F1: 0.971.
- Mortality AUROC: 0.848.
- Next mechanical ventilation AUROC: 0.968.
- Remaining LOS MAE: 2.955 hours.

Important caveat: S7 monitoring splits intentionally overlap training splits.
These metrics are suitable for course demonstration and model comparison, not
for claiming held-out external validation.
