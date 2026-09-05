# ROG Actual ICU Training and Remote-Ops Update

This bundle updates the ROG Windows model service so new ICU time-series events are persisted and consumed by incremental training. It also installs a token-protected remote-ops API so the Mac can later send controlled update/restart/verification instructions to ROG over HTTP.

Remote-ops is intentionally allowlisted. It does not expose arbitrary shell execution. The accepted remote actions are `status`, `apply_update_zip`, `restart_service`, and `verify_actual_training`.

A successful verification must show more than HTTP 200 responses:

- `/api/icu/timeseries/status` exists and reports `total_events`, `trained_event_count`, and `training_ready`.
- `/api/icu/timeseries/ingest` returns `accepted > 0` and increases `total_events`.
- `POST /api/training/command {"action":"continue_training"}` trains an incremental ICU adapter from the new numeric event values.
- `models\cloud_production\s7_phenotype_contrastive_full_20260516\incremental_icu_adapter.json` exists and contains nonzero learned weights.
- after training, `trained_event_count == total_events` and `training_ready == false`.

## Bootstrap once on the ROG

If `http://100.65.136.96:8788/api/admin/remote-ops/status` returns `404`, the ROG is still running the old service and cannot self-update through HTTP yet. Copy and unzip this bundle on the ROG desktop, then run:

```cmd
install_and_verify_rog_actual_training.cmd
```

Optional custom deploy root:

```cmd
install_and_verify_rog_actual_training.cmd "D:\PredictionService\models\production\02_model_deploy_package"
```

Optional explicit bearer token:

```cmd
install_and_verify_rog_actual_training.cmd "D:\PredictionService\models\production\02_model_deploy_package" "paste-a-strong-token-here"
```

If no token is supplied and `SEPSISCARE_SERVICE_TOKEN` is not already set, the installer generates one and stores it at:

```text
D:\PredictionService\models\production\02_model_deploy_package\.runtime\sepsiscare_service_token.txt
```

Use that token on the Mac through `SEPSISCARE_SERVICE_TOKEN` when sending remote-ops commands. Run the command prompt as Administrator if you want the Windows firewall rule refreshed automatically. The one-click command copies the new model-service files, restarts port `8788`, runs the verifier, and writes the evidence JSON under `.runtime`.

Manual PowerShell path:

```powershell
cd <unzipped-bundle>
powershell -ExecutionPolicy Bypass -File .\scripts\update_rog_model_service.ps1 -DeployRoot "D:\PredictionService\models\production\02_model_deploy_package" -HostAddress 0.0.0.0 -Port 8788 -AddFirewallRule
```

To verify without replacing files:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify_rog_actual_training.ps1 -BaseUrl "http://127.0.0.1:8788" -DeployRoot "D:\PredictionService\models\production\02_model_deploy_package" -ServiceToken $env:SEPSISCARE_SERVICE_TOKEN
```

The verification script writes an evidence JSON file under `.runtime\rog_actual_training_evidence_*.json`.

## Remote commands from the Mac after bootstrap

After the ROG exposes `/api/admin/remote-ops/status`, run controlled commands from this Mac:

```bash
export SEPSISCARE_SERVICE_TOKEN="<token from ROG .runtime\\sepsiscare_service_token.txt>"
python3 send_rog_remote_ops_command.py status
python3 send_rog_remote_ops_command.py full --evidence-out ../../05_quality_security/rog_remote_ops_full_evidence.json
```

`full` performs:

1. `status`
2. `apply_update_zip` with only allowlisted files
3. `restart_service`
4. `verify_actual_training`

If the sender reports `Bootstrap the ROG once`, the ROG is still on the old service and cannot receive remote-ops commands yet.
