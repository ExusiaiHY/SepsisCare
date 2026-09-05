# SepsisCare Deployment Test Report

Date: 2026-05-30

## 2026-06-06 macOS 1.0.0 Cloud Forward Fix

- Fixed the remaining `cloud_forward_failed` root cause on the Mac side: the
  local transfer backend was forwarding production training-terminal actions to
  ROG without a bearer token after restart. The backend and installed macOS app
  now use the ROG production URL `http://100.65.136.96:8788` by default and load
  the service token from an owner-only token file.
- Persisted the ROG token at
  `~/Library/Application Support/SepsisCare/sepsiscare_service_token.txt` with
  mode `0600`; verification checked file mode and length without printing the
  token.
- Built `04_client_source/SepsisCare-macOS/dist/sepsiscare-1.0.0-macOS.dmg`
  and copied it to `02_installers/sepsiscare-1.0.0-macOS.dmg`. DMG SHA256:
  `cb36e426ca8d9cc64b07c88e2e85d769d3f82f6a51ee40793cf9fc409946ecee`.
  The final package re-verification on 2026-06-07 refreshed this hash after
  rebuilding the DMG with the token fail-closed backend fix.
- Installed `~/Applications/SepsisCare-macOS.app` from the 1.0.0 DMG. Strict
  code-sign verification passed, `hdiutil verify` reported the DMG checksum
  valid, `CFBundleShortVersionString=1.0.0`, `CFBundleVersion=2026.06.06`, and
  packaged backend `server.py` reports `version=1.0.0` and
  `SepsisCareLocal/1.0`.
- Verified the installed app self-started backend process uses
  `SEPSISCARE_PUBLIC_MODEL_BASE_URL=http://100.65.136.96:8788` and an App
  Support `SEPSISCARE_SERVICE_TOKEN_FILE`. Live `stream_metrics` returned
  `ok=true`, `error=null`, and output beginning with
  `已转发至云端模型服务：http://100.65.136.96:8788/api/training/command`.
- Training-terminal actions verified through the installed local backend and ROG
  production service: `stream_metrics`, `download_artifacts`, `pause_training`,
  `update_database`, and `continue_training`; none returned
  `cloud_forward_failed`.
- Result pull/download verified: `download_artifacts` returned `ok=true`, and
  `GET /api/artifacts/latest` downloaded a ZIP that verified with
  `files_verified=47`, bundle SHA256
  `5fd78ade9085af10e0808b7301865fb92bccbcd3c301322de2183f709408008e`.
- New ICU data upload and training verified: ROG accepted new ICU events,
  `continue_training` produced revision `incremental-20260606T144007Z-24`, and
  final ROG status reached `total_events=24`, `trained_event_count=24`,
  `training_ready=false`.
- Verification rerun:
  - `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_server.py` passed from
    `04_client_source/apps/sepsiscare-studio/backend`, 36 tests.
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
    passed from `04_client_source/SepsisCare-macOS`, 38 tests. Command Line
    Tools alone failed earlier because `XCTest` was unavailable; the full Xcode
    toolchain passed.

## 2026-06-06 ROG 1.0.0 Production-Port Verification

- SSH now reaches ROG through `sepsiscare` (`aadmin@100.65.136.96:22`) and
  identifies the host as `rog\aadmin`.
- The official ROG model-service port `8788` now reports OpenAPI version
  `1.0.0` and remote-ops `service_version=1.0.0`.
- Rebuilt `02_installers/rog_actual_training_update_20260605.zip` with the
  1.0.0 service version, Windows artifact manifest fixes, remote-ops support
  files, port-listener PID restart handling, and token-file restore on restart.
  SHA256: `485a2c932f1983f2b7ca74a99da7d186415458e173a92a98b6b5e272291a65c0`.
- Full Mac-side remote-ops against `http://100.65.136.96:8788` succeeded:
  `apply_update_zip`, `restart_service`, ready status, and
  `verify_actual_training`. Evidence:
  `05_quality_security/rog_remote_ops_full_evidence_20260606_1_0_0.json`.
- The remote-ops actual-training verifier accepted 2 new ICU events and reached
  `total_events=17`, `trained_event_count=17`,
  `actual_training_examples=2`, and `optimizer_steps=136`.
- Mac-side training-terminal E2E against the same production port succeeded:
  upload accepted 2 new ICU events, terminal action returned
  `task_status=trained`, `actual_training_examples=2`,
  `total_events=21`, and `trained_event_count=21`. Evidence:
  `05_quality_security/rog_training_terminal_e2e_20260606_1_0_0.json`.
- `GET /api/artifacts/latest` downloaded
  `05_quality_security/rog_artifacts_latest_20260606_1_0_0.zip`; local artifact
  verification returned `ok=true`, `files_verified=46`, bundle SHA256
  `399527a61627eb1ed5f69cb53c2c888a59f6aab2311745591fb1de43a80cb5a4`, and
  ZIP integrity passed.

## 2026-06-04 Realtime ICU Incremental Training Update

- Added a realtime ICU time-series ingestion path to the local backend:
  - `GET /api/icu/realtime/status`
  - `GET /api/icu/realtime/demo`
  - `POST /api/icu/realtime/ingest`
  - `POST /api/icu/realtime/upload`
- Local ingest writes de-identified monitoring events to
  `managed-runtime/icu_timeseries.jsonl`, validates clinical numeric ranges,
  and records privacy-preserving audit events.
- Added remote model-service ICU time-series endpoints:
  - `GET /api/icu/timeseries/status`
  - `POST /api/icu/timeseries/ingest`
- Remote `POST /api/training/command` with `{"action":"continue_training"}`
  now consumes newly uploaded ICU events, marks the task `trained`, reports
  `incremental_new_events` and `incremental_train_events`, updates
  `total_train_patients`, and writes an `incremental_training_report` artifact.
- Remote `update_database` can accept ICU time-series event batches before a
  subsequent training command.
- Added a Web frontend page `实时 ICU 接入` with controls to write a demo
  monitoring event, upload recorded events to the configured model service,
  refresh local/cloud status, and trigger incremental training.
- Synced the shared Web resources into the Windows, Android, and iOS resource
  copies.
- Extended `06_scripts/script/smoke_test.py --require-model` to prove the full
  loop: local API health, model forwarding, realtime ICU ingest, upload to
  `/api/icu/timeseries/ingest`, remote `continue_training`, and remote
  `/api/icu/timeseries/status`.
- Fixed AI chat forwarding so local `/api/family/chat` and
  `/api/ai/assistant-chat` send patient, prediction, training-status, and
  model-metric context to the configured remote model service instead of
  returning the old `已收到问题` placeholder. Remote fallbacks now include
  patient vitals and training metrics when DeepSeek is not configured.
- Strengthened `06_scripts/script/smoke_test.py --require-model` so family chat
  must include clinical context such as lactate and MAP, and AI assistant chat
  must include training context such as `macro_f1`.
- Verification rerun:
  - `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_server.py`
    passed from `04_client_source/apps/sepsiscare-studio/backend`, 32 tests.
  - `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_model_service.py`
    passed from
    `03_remote_server_model_package/02_model_deploy_package/deploy`, 49 tests.
  - `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_send_rog_remote_ops_command.py`
    passed from `06_scripts/rog_actual_training_update`, 2 tests.
  - `bash ./06_scripts/script/test_web_syntax.sh` passed.
  - `bash ./06_scripts/script/test_web_content_escape.sh` passed.
  - `bash ./06_scripts/script/test_web_auth_token.sh` passed.
  - `./06_scripts/script/test_sepsiscare_services.sh` passed.
  - Full closed-loop smoke passed against local foreground services at
    `http://127.0.0.1:20065` and `http://127.0.0.1:20088` with
    `--require-model`.
  - Remote training status after the smoke reported `task_status=trained`,
    `incremental_new_events=1`, `incremental_train_events=1`,
    `total_train_patients=347635`, and artifact kind
    `incremental_training_report`.
  - `shasum -c SHA256SUMS.txt` passed after updating the nested package
    checksums.
  - Final packaged verification passed with
    `SEPSISCARE_SKIP_APP_OPEN=1 PYTHONDONTWRITEBYTECODE=1 ./install_and_verify_macos.command`.
    This rebuilt the installed macOS app from the refreshed DMG, reran the
    checksum gate, runtime-data audit, macOS DMG app-bundle verification, local
    API/model service startup, full `--require-model` smoke including realtime
    ICU ingest/upload/remote training, and generated artifact verification.
  - Live chat verification from `http://127.0.0.1:8765` returned remote model
    context for `SC-12000`: family chat included lactate, MAP, heart rate, SpO2,
    and `task_status=trained`; AI assistant chat included `macro_f1`,
    `encoder_macro_f1`, and `total_train_patients`.
  - Rebuilt `02_installers/sepsiscare-0.9.0-macOS.dmg`, reinstalled
    `~/Applications/SepsisCare-macOS.app`, verified its code signature, and
    confirmed the installed bundle contains `forward_chat_request`.
  - Regenerated `MANIFEST.sha256`, `SHA256SUMS.txt`, and the outer
    `SepsisCare_Final_Delivery_20260603.zip` while excluding mutable runtime
    and build directories (`.runtime`, `.sepsiscare-demo`,
    `.sepsiscare-runtime`, `.build`, `dist`, `.swift_home`,
    `.swift_module_cache`).
- Production boundary: this proves the packaged software loop and demo
  connector shape. A real hospital ICU feed still needs hospital interface
  credentials, TLS/VPN or equivalent network controls, token management,
  operational monitoring, and clinical data-governance approval.

## 2026-05-31 Update

- Local installed frontend is present at `/Applications/SepsisCare-macOS.app` and was relaunched after reinstall.
- Current local LAN IP: `192.168.0.102`.
- `care.sepsis.api.8765` and `care.sepsis.model.8788` are loaded as current-user LaunchAgents and both bind to `0.0.0.0`.
- Fixed the transfer backend training terminal so production-mode actions now POST to the configured `cloud_base_url/api/training/command` instead of returning only a local simulated cloud response.
- Updated `script/smoke_test.py --require-model` so it verifies the API-to-model forwarding proof: the training terminal action must include `已转发至云端模型服务` and an ok `cloud_response`.
- Rebuilt `SepsisCare-macOS/dist/sepsiscare-0.9.0-macOS.dmg`, replaced `/Applications/SepsisCare-macOS.app`, cleared quarantine metadata, and re-signed the installed app.
- Live forwarding proof from this machine:
  - API: `http://127.0.0.1:8765`
  - Model: `http://127.0.0.1:8788`
  - Returned output began with `已转发至云端模型服务：http://127.0.0.1:8788/api/training/command`.
- Verification rerun:
  - `./script/test_macos_app_bundle.sh` passed.
  - `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passed, 27 tests.
  - `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_server.py` passed, 2 tests.
  - `./script/smoke_test.sh` passed in demo/API mode.
  - `./script/smoke_test.sh --require-model` passed with real API-to-model forwarding.
  - `./script/remote_deployment_check.sh http://192.168.0.102:8765 http://192.168.0.102:8788` passed from this machine.
  - `./script/test_remote_deployment_check.sh` passed.
- Remaining external check: a second physical computer still needs to run the model service and then be tested from this Mac with `./script/smoke_test.sh http://127.0.0.1:8765 http://MODEL电脑IP:8788 --require-model`.

## 2026-05-31 Remote Server Model-Service Delivery Update

- Added repository ignore rules so runtime logs, LaunchAgent state, virtualenvs, Swift build caches, Xcode user state, generated app bundles, Android local config, and local secrets are excluded from source control and manifest generation.
- Regenerated `MANIFEST.sha256` from the git-visible delivery set; it includes scripts, macOS/frontend source, backend forwarding code, the remote server deployment scripts, tests, model files, reports, packaged runtime database, and the ROG actual-training remote-ops update bundle.
- The pre-release gate now also verifies the ROG remote-ops sender and builds a check copy of `rog_actual_training_update_20260605.zip` under `05_quality_security/security-checks/`.
- Packaged model-side database files are present in `02_model_deploy_package/runtime_data/`:
  - `history_patients.json`: 12015 rows, 10948135 bytes.
  - `history_details.json`: 15 rows, 110213 bytes.
- The running local model service health check reports:
  - URL: `http://127.0.0.1:8788/health`
  - service: `sepsiscare-model-service`
  - database root: `02_model_deploy_package/runtime_data`
  - `history_patients`: 12135 including generated fallback/demo rows.
- remote-server-ready model service now supports the macOS smoke/API surface directly from port `8788`, including patient queue, history database, admin bindings, dashboard/filter/config endpoints, clinical/AI endpoints, bedside/report endpoints, training terminal commands, and `/api/artifacts/latest`.
- remote server one-click entrypoint is `02_model_deploy_package/deploy/remote_server_one_click_deploy.sh`; supported commands are `doctor`, `start`, `stop`, `restart`, `status`, `smoke`, and `logs`.
- The legacy `02_model_deploy_package/deploy/start_model_service.sh` now delegates to the one-click deploy script.
- Mac-side remote server orchestration entrypoint is `script/deploy_model_to_remote_server.sh`; supported commands are `all`, `preflight`, `sync`, `deploy`, `smoke`, and `pull-artifacts`. The `all` command checks SSH, rsyncs `02_model_deploy_package/` to remote server, runs the remote server one-click restart and smoke test, verifies local API forwarding to the remote server model URL, and downloads `/api/artifacts/latest` back to `.sepsiscare-runtime/remote-server-artifacts/sepsiscare_model_artifacts_latest.zip`.
- Verification rerun after packaging cleanup:
  - `./script/test_deploy_model_to_remote_server.sh` passed for help output, rsync excludes, remote restart/smoke command construction, Mac-to-remote-server smoke invocation, and artifact pull behavior using fake command shims.
  - `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest 02_model_deploy_package/deploy/test_model_service.py` passed, 4 tests.
  - `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_server.py` passed from `apps/sepsiscare-studio/backend`, 2 tests.
  - `02_model_deploy_package/deploy/test_remote_server_one_click_deploy.sh` passed, including restart/status/smoke on temporary port `19888`.
  - `./script/smoke_test.sh --require-model` passed for local API `127.0.0.1:8765` forwarding to local model `127.0.0.1:8788`.
  - `./script/smoke_test.sh http://127.0.0.1:8788 http://127.0.0.1:8788 --require-model` passed, proving the model server can also satisfy the macOS smoke API surface directly.
  - `./script/remote_deployment_check.sh http://192.168.0.102:8765 http://192.168.0.102:8788` passed from this Mac, proving both services are bound on the LAN address from the local client perspective.
  - Downloaded `http://127.0.0.1:8788/api/artifacts/latest` successfully to `.sepsiscare-runtime/artifacts-check/sepsiscare_model_artifacts_latest.zip`; the archive is about 4.0 MB and contains 37 files including model weights, reports, config, split metadata, and `.runtime/training_service.log`.
  - `./script/test_macos_app_bundle.sh` passed for the development app bundle, distribution app bundle, installed `/Applications/SepsisCare-macOS.app`, and mounted DMG app.
- remote server is not configured/deployed yet because it is currently unreachable:
  - `tailscale status` shows `100.74.239.47 exusss-system-product-name linux offline, last seen 12d ago`.
  - `ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new remote-server true` returns `Connection closed by 198.18.0.212 port 22`.
  - `ping -c 3 remote-server` had 3 transmitted, 0 received, 100.0% packet loss.
  - `./script/deploy_model_to_remote_server.sh preflight` also fails at the same SSH preflight with `Connection closed by 198.18.0.212 port 22`.
- GitHub publication:
  - Private repository: `https://github.com/ExusiaiHY/SepsisCare_macOS_app_model_transfer_20260528`
  - Branch: `codex/remote-server-model-deployment`
  - First delivery commit: `a0c5765 Prepare SepsisCare remote server model deployment`
- Once remote server is online and SSH is usable, the exact remote model deployment commands are:

```bash
cd SepsisCare_macOS_app_model_transfer_20260528/02_model_deploy_package
SEPSISCARE_MODEL_HOST=0.0.0.0 SEPSISCARE_MODEL_PORT=8788 bash deploy/remote_server_one_click_deploy.sh restart
bash deploy/remote_server_one_click_deploy.sh smoke
```

- After remote server deployment, the Mac-side proof command is:

```bash
./script/smoke_test.sh http://127.0.0.1:8765 http://REMOTE_SERVER_IP:8788 --require-model
```

## Verified Locally

- macOS app launches as a generated app bundle:
  - Command: `./script/build_and_run.sh --verify`
  - Bundle: `dist/SepsisCare-macOS.app`
  - Result: process stayed running and the app window opened.
- Generated development app bundle signing:
  - Root cause checked: `dist/SepsisCare-macOS.app` was previously launchable but failed strict code-sign verification because the generated bundle was not re-signed after copying `Info.plist`, icon, and backend resources.
  - Fix: `script/build_and_run.sh` now clears quarantine metadata from the generated bundle and signs the staged `.app` with local ad-hoc signing before launch.
  - Verification: `./script/build_and_run.sh --verify` launched the app, and `codesign --verify --deep --strict --verbose=2 dist/SepsisCare-macOS.app` reported the bundle valid on disk and satisfying its designated requirement.
- Development/installed app launch isolation:
  - Root cause checked: multiple running SepsisCare bundles with the same `care.sepsis.desktop` bundle identifier caused macOS LaunchServices/window activation ambiguity between the development bundle and `/Applications/SepsisCare-macOS.app`.
  - Fix: `script/build_and_run.sh` now stages the development bundle as `care.sepsis.desktop.dev`, gives it the display name `SepsisCare Dev`, opens it without `open -n`, and waits for old `SepsisCare-macOS` processes to exit before relaunching.
  - Fix: release `Info.plist` files now include `LSMultipleInstancesProhibited=true`; the bundle regression test checks this for development, distribution, installed, and DMG bundles.
  - Verification: `plutil -p dist/SepsisCare-macOS.app/Contents/Info.plist` reported `CFBundleIdentifier => care.sepsis.desktop.dev`; `/Applications/SepsisCare-macOS.app` reported `CFBundleIdentifier => care.sepsis.desktop` and `LSMultipleInstancesProhibited => true`.
  - Verification: after launching `/Applications/SepsisCare-macOS.app`, `ps -axo pid,comm,args | rg SepsisCare-macOS` showed only one installed app process, and the visible login window reported `外部 API 在线`.
- DMG and installed app launch path:
  - Command: `cd SepsisCare-macOS && ./scripts/build-dmg.sh`
  - Fix: both DMG builder scripts clear `com.apple.quarantine` from the staged `.app` before signing, so build-time extended attributes from source resources are not packaged.
  - Verification: `codesign --verify --deep --strict --verbose=2` passed for `SepsisCare-macOS/dist/SepsisCare-macOS.app`, `/Volumes/sepsiscare Installer/SepsisCare-macOS.app`, and `/Applications/SepsisCare-macOS.app`.
  - Verification: `xattr -lr` on the rebuilt app bundle, mounted DMG app, and `/Applications` app showed provenance metadata but no `com.apple.quarantine` entries.
  - Verification: `/Applications/SepsisCare-macOS.app` launched and displayed the login window connected to `http://127.0.0.1:8765`.
- macOS app bundle regression test:
  - Command: `./script/test_macos_app_bundle.sh`
  - Scope: development bundle, release bundle, installed `/Applications` bundle, and mounted DMG bundle.
  - Checks: strict code signature, no `com.apple.quarantine`, required `Info.plist` keys, development-vs-production bundle identifier separation, `LSMultipleInstancesProhibited`, executable bit, app icon, packaged backend `server.py`, and DMG `Applications` symlink.
  - Result: all app bundle checks passed. This command needs normal macOS mount permissions because it uses `hdiutil` to inspect the DMG.
- Research workspace login smoke:
  - Role: research
  - Password: `123123`
  - Result: entered the research overview workspace.
- Swift build and XCTest:
  - Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  - Scope: both `SepsisCare-macOS` and `apps/SepsisCare-macOS`
  - Result: 25 tests passed in each package.
  - Coverage: includes a macOS lifecycle regression that verifies the app terminates after the last window closes, preventing a running process with no visible window from looking like a failed launch.
- Python backend unit test:
  - Command: `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_server.py`
  - Result: 1 test passed.
- Local API smoke:
  - Command: `./script/smoke_test.sh --require-model`
  - Scope: app API endpoints on 8765 and model-service endpoints on 8788.
  - Result: health, patient queue, model metadata/status, admin, history, AI, clinical, family chat, training terminal, export, and model training command checks passed.
- Remote deployment preflight script:
  - Command: `./script/remote_deployment_check.sh 127.0.0.1`
  - Scope: client-side API/model health checks plus the existing app API/model smoke suite. The script accepts either a target host/IP or explicit API/model URLs.
  - Result: local equivalent target passed API health, model health, app API smoke, and model training command smoke. The script warns when the target is loopback because that does not prove cross-machine routing.
  - Additional verification: `./script/remote_deployment_check.sh http://127.0.0.1:8765 http://127.0.0.1:8788 --no-smoke` passed URL parsing and health-only mode.
  - Regression test: `./script/test_remote_deployment_check.sh` covers help output, too many target arguments, malformed API/model URLs, domain hosts with non-default ports, raw IPv6 hosts, bracketed IPv6 API URLs, required API health failure, and optional model-service failure with `--skip-model --no-smoke`. It verifies that user-facing diagnostics are emitted without leaking raw `curl:` errors.
- Remote API address setting:
  - Root cause checked: settings accepted raw API base URLs, so a value such as `http://TARGET_IP:8765/` could be persisted with a trailing slash and later combine with app paths as `//health` or `//api/...`.
  - Fix: `SepsisCareAPI.normalizedBaseURL(_:)` now centralizes API base URL normalization; `AppSettings`, `APIClient`, `BackendController`, and settings-page DeepSeek config calls use the normalized base URL. Bare IPv6 API hosts such as `http://fd00::20:8765/` are normalized to `http://[fd00::20]:8765`.
  - Fix: settings now includes a `测试 API` action that synchronizes the normalized API address into `BackendController` and `APIClient`, validates URL shape before network access, then awaits a direct `/health` check so success and failure states are both explicit.
  - Verification: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passed in both `SepsisCare-macOS` and `apps/SepsisCare-macOS`, with tests covering persisted remote URL normalization, bare IPv6 host normalization, blank reset to default local API, remote-vs-local detection, `APIClient.setBaseURL`, `BackendController.setAPIBaseURL`, strict `/health` URL construction, compatible backend health payload checks, and invalid API address failure state.
  - Verification: rebuilt development app, rebuilt DMG, installed the rebuilt `/Applications/SepsisCare-macOS.app`, and confirmed the installed app launched with `外部 API 在线`.
- Service manager lifecycle:
  - Command sequence:
    - `SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh stop`
    - `SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh start`
    - `SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh status`
    - `SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh smoke`
    - `SEPSISCARE_PORT=18765 SEPSISCARE_MODEL_PORT=18788 ./script/sepsiscare_services.sh stop`
  - Result: services started, status reported managed pids, full smoke passed, and services stopped.
- macOS LaunchAgent lifecycle:
  - Command sequence:
    - `./script/test_sepsiscare_services.sh`
    - `SEPSISCARE_PORT=19765 SEPSISCARE_MODEL_PORT=19788 ./script/sepsiscare_services.sh install-agent`
    - `SEPSISCARE_PORT=19765 SEPSISCARE_MODEL_PORT=19788 ./script/sepsiscare_services.sh smoke`
    - `SEPSISCARE_PORT=19765 SEPSISCARE_MODEL_PORT=19788 ./script/sepsiscare_services.sh uninstall-agent`
    - `SEPSISCARE_PORT=19765 SEPSISCARE_MODEL_PORT=19788 ./script/sepsiscare_services.sh status`
  - Result: LaunchAgent plists were generated, launchctl loaded both API and model services, full smoke passed on temporary ports, uninstall removed the agents, and the temporary ports reported offline.
- Service status remote-access diagnostics:
  - Root cause checked: a target computer can report local services online while still being unreachable from another Mac if the service binds only to loopback, the firewall blocks ports, or VPN/LAN routing hides the host.
  - Fix: `./script/sepsiscare_services.sh status` now prints a `Remote access preflight` block with actual API/model listener bind addresses when `lsof` can observe them, loopback-vs-remote-capable interpretation, firewall/routing/port hints, and the client-side `./script/remote_deployment_check.sh TARGET_IP` command.
  - Fix: service startup now checks for a listener on the target port before spawning Python. If the port is occupied but `/health` is not healthy, it prints the listener line and remediation hints instead of letting Python fail later with `Address already in use`.
  - Regression test: `./script/test_sepsiscare_services.sh` verifies the status block, including loopback-only, `0.0.0.0` remote-capable messages, a fake-`lsof` case where the configured host is `0.0.0.0` but the actual listener is `127.0.0.1`, and the occupied-port/unhealthy-health short-circuit that avoids launching another Python process.
- Local proxy handling:
  - `script/sepsiscare_services.sh` and `script/smoke_test.sh` explicitly set local `NO_PROXY` handling so health checks do not accidentally route `127.0.0.1` through `ALL_PROXY`.
- Research training terminal UI smoke:
  - Role: research
  - Action: opened the training terminal and clicked `日志指标`.
  - Result: terminal output displayed `encoder_macro_f1`, `mortality_auroc`, and `remaining_los_mae_hours`.
- Research installed-app UI smoke:
  - App: `/Applications/SepsisCare-macOS.app`
  - Role: research
  - Result: entered the research workspace from the installed app.
  - Overview: displayed external API online state, current patient queue count, high-risk count, and average ICU estimate.
  - Risk board: displayed risk stratification summary, high-risk queue, selected `SC-12051`, and real-time detail panel; refresh prediction remained responsive.
  - History ICU database: opened overview, patient table, and detail views; table rows loaded, detail view rendered parameter matrix, prediction window consistency, and chart content.
  - Model status: displayed backend online state, DeepSeek provider/model, CPU device, model version, and model metrics.
  - Training terminal: clicked `日志指标`; metrics were returned in the terminal panel.
  - Clinical lab: exercised diagnosis, S6 recommendation, clinical scores, and bedside/family report panels; each displayed backend JSON output.
  - AI analysis: clicked assistant Q&A; displayed a local-transfer-backend answer.
- Family installed-app UI smoke:
  - App: `/Applications/SepsisCare-macOS.app`
  - Role: family
  - Result: entered the family workspace bound to `ICU-01 / SC-12000`.
  - AI chat: clicked preset `今天病情怎么样？` and sent custom text `乳酸升高是什么意思？`; both displayed backend responses with source `local-transfer-backend`.
  - Current patient status: displayed phenotype, overall status, ventilation estimate, expected ICU time, MAP, lactate, SpO2, temperature, qSOFA/NEWS, shock hint, family-facing AI summary, and trend chart.
- Admin UI smoke:
  - Role: admin
  - Password: `123123`
  - Result: entered the admin workspace.
  - Account binding: displayed current `family -> SC-12000` binding, backend binding file path, refresh/sync controls, and patient binding list.
  - Service monitor: displayed external API online state, backend URL, CPU estimate, GPU unavailable state, DeepSeek fallback/model, runtime environment, and full status refresh.
  - API coverage: clicked all four groups: patients/dashboard/filters, config/AI, model/clinical, and bedside/report; each displayed structured JSON responses from the backend.
  - Audit log: displayed and refreshed `/api/audit` output with a recent `health_check` event.

## Current Runtime State

- `0.0.0.0:8765` is online from the installed `care.sepsis.api.8765` LaunchAgent.
- `0.0.0.0:8788` is online from the installed `care.sepsis.model.8788` LaunchAgent.
- `/Applications/SepsisCare-macOS.app` is the active installed app process; the development bundle uses `care.sepsis.desktop.dev` to avoid LaunchServices confusion with the installed app.
- Temporary validation ports `18765` and `18788` were stopped.
- Temporary LaunchAgent validation ports `19765` and `19788` were stopped and their agents were unloaded.
- The current LAN interface reported `192.168.0.102`; `./script/remote_deployment_check.sh http://192.168.0.102:8765 http://192.168.0.102:8788` passed from this machine, proving non-loopback bind locally. A second physical computer still needs to verify cross-machine routing.

## Deployment Commands

On a target computer:

```bash
cd SepsisCare_macOS_app_model_transfer_20260528
./script/sepsiscare_services.sh start
./script/sepsiscare_services.sh status
./script/sepsiscare_services.sh smoke
```

For persistent macOS service startup on a target computer:

```bash
./script/sepsiscare_services.sh install-agent
./script/sepsiscare_services.sh agent-status
./script/sepsiscare_services.sh smoke
```

From the client computer:

```bash
./script/remote_deployment_check.sh TARGET_IP
```

or, for explicit URLs:

```bash
./script/remote_deployment_check.sh http://TARGET_IP:8765 http://TARGET_IP:8788
```

Lower-level smoke entrypoint:

```bash
./script/smoke_test.sh http://TARGET_IP:8765 http://TARGET_IP:8788 --require-model
```

Then set the macOS app API address to:

```text
http://TARGET_IP:8765
```

The app normalizes pasted API addresses by trimming whitespace and a trailing `/`; use the Settings window instead of editing source for target computer changes.
Use the Settings window `测试 API` button after entering `http://TARGET_IP:8765` to confirm the app has switched to the target backend.

Before handing a local build to another Mac:

```bash
./script/test_macos_app_bundle.sh
```

## Not Complete Yet

- A real second computer has not yet been used as the remote deployment target.
- remote server has not been deployed because the configured host is currently unreachable/offline.
- Cross-machine connection from this macOS app to `http://TARGET_IP:8765` has not yet been verified.
- Firewall, LAN routing, fixed IP/domain, TLS, and authentication are not configured.
- LaunchAgent persistence has been implemented and locally validated on temporary ports, but it has not been installed on the real second target computer yet.
- Full destructive/edge-case UI coverage for every research, family, and admin action has not been completed; current coverage is API smoke plus major research, family, and admin read/diagnostic workflows from the installed app.
