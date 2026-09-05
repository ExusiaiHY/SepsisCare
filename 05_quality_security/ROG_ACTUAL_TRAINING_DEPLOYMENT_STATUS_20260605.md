# ROG Actual Training Deployment Status - 2026-06-05

Updated live verification: 2026-06-06 22:40 Asia/Shanghai

## 2026-06-06 ROG 1.0.0 production-port release

- SSH reaches ROG through host alias `sepsiscare`, user `aadmin`, port `22`,
  Tailscale address `100.65.136.96`. Login identity is `rog\aadmin`.
- The official production model service now runs on
  `http://100.65.136.96:8788` and reports OpenAPI version `1.0.0`.
- Mac-side remote-ops status against the production port succeeds with bearer
  auth and reports `service_version=1.0.0`,
  `remote_ops_version=2026.06.05`, and allowed actions
  `apply_update_zip`, `restart_service`, `status`, and
  `verify_actual_training`.
- The current rebuilt update bundle is
  `02_installers/rog_actual_training_update_20260605.zip` with SHA256
  `485a2c932f1983f2b7ca74a99da7d186415458e173a92a98b6b5e272291a65c0`.
  The in-band remote-ops update payload SHA256 was
  `abf951bb88a16a0e6c29175ece87c414d3610109bb03d5bdaaaff21e75198e7f`.
- The Windows start script now refreshes service token state from
  `.runtime\sepsiscare_service_token.txt` and stops by actual port listener PID,
  not only by `.runtime\model_8788.pid`. This fixed the earlier stale-PID
  restart problem.
- `05_quality_security/rog_remote_ops_full_evidence_20260606_1_0_0.json`
  records a full remote-ops cycle on `100.65.136.96:8788`: update applied,
  restart requested, ready status returned `service_version=1.0.0`, and
  actual-training verification accepted 2 ICU events. The verifier reached
  `total_events=17`, `trained_event_count=17`,
  `actual_training_examples=2`, and `optimizer_steps=136`.
- `05_quality_security/rog_training_terminal_e2e_20260606_1_0_0.json`
  records the Mac-side training-terminal path against the same production port:
  upload accepted 2 new ICU events, training returned `task_status=trained`,
  `actual_training_examples=2`, and the final status reached
  `total_events=21` with `trained_event_count=21`.
- `05_quality_security/rog_artifacts_latest_20260606_1_0_0.zip` was downloaded
  from `GET /api/artifacts/latest` on the production port and verified locally:
  bundle SHA256 `399527a61627eb1ed5f69cb53c2c888a59f6aab2311745591fb1de43a80cb5a4`,
  `files_verified=46`, ZIP integrity OK.
- The macOS 1.0.0 installer was built and installed from
  `02_installers/sepsiscare-1.0.0-macOS.dmg`. The installed app self-started the
  packaged backend from `~/Applications/SepsisCare-macOS.app`, reported bundle
  version `1.0.0` / build `2026.06.06`, and loaded the ROG service token from
  `~/Library/Application Support/SepsisCare/sepsiscare_service_token.txt` with
  owner-only file permissions. Token contents were not printed.
- The previous `cloud_forward_failed` condition is fixed in the installed-app
  path: live `stream_metrics`, `download_artifacts`, `pause_training`,
  `update_database`, and `continue_training` all forwarded from local
  `http://127.0.0.1:8765` to
  `http://100.65.136.96:8788/api/training/command` with `ok=true` and
  `error=null`.
- A fresh artifact download after the cloud-forward fix verified with
  `files_verified=47` and bundle SHA256
  `5fd78ade9085af10e0808b7301865fb92bccbcd3c301322de2183f709408008e`.
- Fresh ICU upload and training after the installed-app restart reached final
  ROG status `total_events=24`, `trained_event_count=24`,
  `training_ready=false`; latest revision:
  `incremental-20260606T144007Z-24`.

## Current release gate

ROG has passed the 1.0.0 production-port release gate for remote-ops update,
service restart, actual ICU training, installed macOS app startup,
training-terminal upload/train/download/pause/update-database, result pull, and
artifact verification on `100.65.136.96:8788`.

## Verified locally

- macOS training-terminal UI saved the ROG model URL `http://100.65.136.96:8788` without a Swift decoding error.
- Local ICU demo payload was loaded from the frontend and recorded through `/api/icu/realtime/ingest`.
- Local event count increased from 7 to 8 and the latest stored event used `patient_key` and `bed_hash`, not raw `patient_ref` or `bed_no`.
- The remote model-service package tests verify real incremental training, including `actual_training_examples == 2`, `optimizer_steps > 0`, and nonzero adapter weights. Current focused suite: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_model_service.py test_verify_artifact_bundle.py test_send_rog_remote_ops_command.py` -> 57 tests passed.
- The remote-ops tests verify that `/api/admin/remote-ops/command` requires Bearer auth for remote clients, rejects arbitrary shell commands, accepts only allowlisted update ZIP entries, rejects path traversal, handles top-level ZIP directory entries, and runs actual adapter training.
- The Mac-side remote-ops sender tests verify that the generated update ZIP contains only allowlisted paths and can source files from the full delivery tree. Current suite: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_send_rog_remote_ops_command.py` -> 2 tests passed.
- The macOS transfer backend now detects the old ROG placeholder response from `GET /api/ai/analysis` and routes the request through the currently working ROG `POST /api/ai/assistant-chat` DeepSeek path. Current backend suite: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_server.py` -> 34 tests passed in both source backend and packaged app backend.
- A live Python backend verification against `http://100.65.136.96:8788` returned `source=deepseek`, `model=deepseek-chat`, and `analysis_via=/api/ai/assistant-chat` for `/api/ai/analysis`, so the current macOS backend no longer surfaces the old static "remote Windows model service online" text to the frontend.
- A local HTTP smoke run against the same model-service code trained `managed-runtime/models/incremental_icu_adapter.json` from two ICU time-series events with `optimizer_steps=16`.
- `./06_scripts/script/pre_release_security_check.sh` completed successfully. It re-ran runtime/sensitive-data/training-data audits, remote model-service tests, artifact verifier tests, ROG sender tests, local backend tests, web checks, deploy script checks, one-click model smoke, ROG update packaging, and both Swift package builds.

## ROG current state

- Tailscale reaches `rog` at `100.65.136.96`.
- SSH reaches ROG through `sepsiscare` as `rog\aadmin`.
- `http://100.65.136.96:8788/health` is online.
- `http://100.65.136.96:8788/openapi.json` reports model-service version
  `1.0.0`.
- `http://100.65.136.96:8788/api/admin/remote-ops/status` succeeds from the
  Mac with the bearer token stored on ROG and reports `service_version=1.0.0`.
- `/api/icu/timeseries/ingest`, `/api/training-terminal/action`,
  `/api/training-terminal/command`, `/api/training/command`, and
  `/api/artifacts/latest` were all exercised on the production port.
- The current artifact downloaded from `GET /api/artifacts/latest` verifies with
  `files_verified=47`.
- Latest verified ROG ICU status after the installed-app cloud-forward smoke:
  `total_events=24`, `trained_event_count=24`, `training_ready=false`.

The current ROG update artifact is:

```text
02_installers/rog_actual_training_update_20260605.zip
SHA256 485a2c932f1983f2b7ca74a99da7d186415458e173a92a98b6b5e272291a65c0
```

## Remote maintenance command

After reading the bearer token from
`D:\PredictionService\models\production\02_model_deploy_package\.runtime\sepsiscare_service_token.txt`,
the Mac can send the controlled full update/restart/training verifier:

```bash
export SEPSISCARE_SERVICE_TOKEN="<token from ROG .runtime\\sepsiscare_service_token.txt>"
python3 06_scripts/rog_actual_training_update/send_rog_remote_ops_command.py full \
  --base-url http://100.65.136.96:8788 \
  --evidence-out 05_quality_security/rog_remote_ops_full_evidence_20260606_1_0_0.json
```
