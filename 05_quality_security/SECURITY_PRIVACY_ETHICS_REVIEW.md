# SepsisCare Security, Privacy, and Medical Ethics Review

Status: single-agent hardening pass, 2026-06-03. This is not a HIPAA, IRB, FDA, or medical-device compliance certification.

## Scope

- Local transfer backend: `apps/sepsiscare-studio/backend/server.py`
- Remote model service: `02_model_deploy_package/deploy/model_service.py`
- remote server deployment and smoke scripts under `script/` and `02_model_deploy_package/deploy/`
- macOS, Web, Windows, iOS, and Android client token propagation paths
- realtime ICU monitoring ingest, local JSONL recording, cloud upload, and
  incremental model-training command paths

## Reference Baseline

- HHS HIPAA de-identification guidance recognizes Expert Determination and Safe Harbor methods. This pass implements engineering minimization and identifier suppression, but does not replace formal expert determination: https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html
- NIST AI RMF frames trustworthy AI around properties such as secure, resilient, privacy-enhanced, accountable, transparent, explainable, and fair. This pass maps those concerns to concrete service controls: https://www.nist.gov/itl/ai-risk-management-framework

## Implemented Controls

### Network Security

- Sensitive remote API paths now require a configured bearer token from `SEPSISCARE_SERVICE_TOKEN` or `SEPSISCARE_TRAINING_TOKEN`.
- Remote clients fail closed with `403 remote_auth_not_configured` when no token is configured.
- Remote clients also fail closed with `403 weak_auth_token_configured` when the configured token is a known placeholder or shorter than 16 characters, preventing demo passwords or copied placeholder text from acting as production API credentials.
- Loopback clients remain usable for local development and tests.
- Sensitive endpoints return `401 authorization_required` for missing or invalid bearer tokens.
- Local and remote `/api/audit` endpoints are treated as sensitive audit surfaces, so remote clients must pass the same configured bearer-token gate before receiving audit metadata.
- Local service defaults were tightened to `127.0.0.1`; remote examples document token use.
- FastAPI docs and Redoc are disabled on the remote model service.
- Training terminal `cloud_base_url` values are constrained before persistence or forwarding. Valid remote server/Tailscale/LAN HTTP(S) model-service URLs remain supported, while metadata, link-local, multicast, reserved, unspecified, non-HTTP(S), no-host, and credential-bearing URLs are rejected with `cloud_base_url_rejected`; rejected raw URLs are not written to training state, responses, or logs.
- Sensitive responses set `Cache-Control: no-store`; responses set `X-Content-Type-Options: nosniff`.
- Local backend CORS no longer uses wildcard origins; it only reflects configured local origins.
- Web, Windows, iOS, and Android shared clients no longer persist remote API bearer tokens in `localStorage`; tokens are kept session-scoped, legacy persisted tokens are removed on load, and launch `token/apiToken` URL parameters are stripped with `history.replaceState`.
- The shared Web clients and macOS login flow now label `123123` as a client-side demonstration gate, not production authentication. The UI and copied README files state that remote sensitive APIs are controlled by Bearer tokens, and `script/test_demo_auth_boundary.sh` makes this wording a pre-release invariant.
- Web, Windows, iOS, and Android shared clients escape server-returned patient, history, chat, audit, account-binding, status, and terminal text before rendering into `innerHTML`, reducing XSS and content-injection risk from compromised or malformed backend/model responses.
- Remote model service writes privacy-preserving security audit events for authentication failures without logging bearer tokens or request bodies.

### Data De-identification and Minimization

- Packaged history patients are emitted through an allowlist schema. Direct identifiers such as `subject_id`, `hadm_id`, `patient_name`, `mrn`, `dob`, `address`, and `_detail_profile` are removed from public patient rows.
- Packaged history detail rows are reduced to clinical time-series values only.
- Runtime paths exposed to clients are represented as `managed-runtime/...` instead of absolute filesystem paths.
- Training terminal `sync_config` persists only sanitized public keys, allowlisted safe parameters, and a security-validated `cloud_base_url`. Local-to-remote-server training-command forwarding also re-sanitizes stored `params` and recursively redacts sensitive `payload` keys/text such as raw patient references, subject/admission ids, API keys, bearer tokens, phone numbers, and bed identifiers before the request body leaves the local backend.
- Artifact bundles exclude runtime logs, model deployment config files, and symlinked files so API keys and bearer tokens are not copied into downloadable ZIPs through direct files or indirect filesystem links.
- Artifact bundles include `MANIFEST.sha256` with per-file hashes and return the bundle-level SHA256 in artifact metadata. When `SEPSISCARE_ARTIFACT_SIGNING_KEY` is configured, bundles also include `MANIFEST.sha256.hmac` with an HMAC-SHA256 signature over the manifest.
- `/api/artifacts/latest` rebuilds the downloadable artifact from known model/report roots before serving it, so stale or polluted cached ZIPs are not treated as trusted release evidence.
- Artifact downloads write privacy-preserving audit events with artifact name, size, and bundle SHA256.
- `deploy/verify_artifact_bundle.py` verifies artifact ZIP contents against `MANIFEST.sha256` and validates `MANIFEST.sha256.hmac` when a local release key is supplied. `script/deploy_model_to_remote_server.sh pull-artifacts` runs this verifier automatically when `SEPSISCARE_ARTIFACT_SIGNING_KEY` is set.
- DeepSeek/OpenAI-compatible configuration updates write privacy-preserving audit events that record changed field names and key-change intent without logging API keys or full config payloads.
- DeepSeek/OpenAI-compatible `base_url` values are constrained to public HTTPS endpoints or loopback local-compatible servers. Plain HTTP is accepted only for loopback, while private, link-local, metadata-service, and credential-bearing URLs are rejected, normalized back to the default DeepSeek endpoint, and audited only with a boolean rejection flag so the raw rejected URL is not copied into logs.
- Admin family-binding updates write privacy-preserving audit events with account name and a short hash of the patient reference, not the patient reference itself.
- Family-binding patient references are constrained to known masked patient ids or bed numbers. Unknown values such as raw MRN/admission identifiers are rejected with `422 invalid_patient_ref`, audited by hash only, and legacy unknown binding records are redacted in API responses.
- Local family-chat and AI-explain fallback responses redact common MRN, email, phone, DOB/SSN, patient-reference, and bed-number text patterns before returning user-supplied text.
- Local and remote detail-path patient references are constrained to known masked patient ids, bed numbers, or history ids as appropriate for the endpoint. Unknown patient detail, bedside snapshot, history detail, and monitor-report path references are rejected with `422 invalid_patient_ref` and audited by hash only, preventing raw MRN/admission-like path values from falling back to the first demo patient record or being echoed in responses.
- Local and remote history CSV exports keep an explicit allowlist of export columns, validate any supplied `history_id` before filtering, reject unknown raw identifiers with `422 invalid_patient_ref`, and write privacy-preserving `history_export` audit events with scope, row count, and optional history-reference hash.
- Local and remote runtime JSON/log writes actively set owner-only file permissions (`0600`) so DeepSeek keys, family bindings, audit events, and training state/log files are not left readable by group/other users if the host umask is permissive.
- Realtime ICU monitoring events are accepted through a dedicated local API,
  minimized before local persistence, and stored under
  `managed-runtime/icu_timeseries.jsonl` rather than exposing raw filesystem
  paths to clients.
- Realtime ICU upload forwards only the validated event batch to the configured
  model service endpoint `/api/icu/timeseries/ingest`; identifiers such as
  patient, bed, and device references are represented with privacy-preserving
  hashes in the recorded payload.
- External LLM prompts are now recursively sanitized before being sent to DeepSeek-compatible endpoints. Sensitive keys are redacted, common MRN/email/phone/DOB/SSN text patterns are redacted, internal patient/bed identifiers such as `patient_ref`, `masked_id`, `history_id`, `bed_no`, `SC-*`, `HX-*`, and `ICU-*` are redacted, prompt depth/list size/text length are bounded, destination URLs are constrained by the SSRF-resistant `base_url` policy, and clinical values needed for explanation remain available.
- `script/audit_runtime_data.py` audits packaged runtime history data before release for required provenance fields, duplicate identifiers, orphan detail series, sensitive key/text leakage, and fatal clinical value pollution without echoing raw sensitive values in the report.
- `script/deploy_model_to_remote_server.sh sync` and `all` now run the runtime data audit before `rsync`; audit failure stops release package transfer.
- `script/audit_sensitive_data.py` audits one or more release surfaces for high-confidence committed secrets and PHI-like text, with test/docs/report/model exclusions to avoid echoing fixtures. Markdown release documents such as `README.md` and `README_DEPLOY.md` are still scanned for hardcoded secrets, while `.md` files are not treated as PHI surfaces to avoid blocking ordinary prose. Findings include root, file, line, and a short evidence hash only, never the raw secret or PHI value.
- `script/deploy_model_to_remote_server.sh sync` and `all` now run the release-file sensitive data audit across the model package, local backend, web client, Windows web assets, iOS web assets, and Android web assets before `rsync`; audit failure stops release package transfer.
- `script/audit_training_data_integrity.py` audits training metadata in the release package for source provenance, all-train/full-overlap monitoring split consistency, declared training-patient totals, target run presence, and metric range pollution. It blocks misleading held-out validation claims for the all-source package.
- Deployment docs now avoid literal bearer-token placeholders in copyable commands, require generated environment-token examples, document the non-placeholder/at-least-16-character token rule, warn against docs/chat/log/shell-history leakage, and show cleanup with `unset SEPSISCARE_SERVICE_TOKEN`; `script/test_deployment_doc_secret_hygiene.sh` keeps this as a release invariant.
- `script/pre_release_security_check.sh` is a single pre-release gate for the implemented controls. It runs the runtime-data audit tests, sensitive-data audit tests, training-data integrity audit tests, real runtime-data audits for both packaged and local-backend copies, the 6-root release-file sensitive-data audit, training metadata integrity audit, model-service security tests, artifact verifier tests, local-backend tests, web token/demo-auth-boundary/content escaping/syntax tests, deployment-doc secret-hygiene tests, deploy orchestration tests, service orchestration tests, one-click model-service smoke, and Swift package builds. Full JSON audit reports are written under `.sepsiscare-runtime/security-checks/` while the terminal output stays summarized.
- `script/deploy_model_to_remote_server.sh` dry-run command logging redacts `Authorization: Bearer ...` arguments as `Authorization: Bearer [redacted]`, so operators can paste dry-run output into deployment notes without exposing the service token.
- `script/deploy_model_to_remote_server.sh all` now runs `script/pre_release_security_check.sh` before SSH preflight, package transfer, remote restart, smoke testing, or artifact pull. The `SEPSISCARE_PRE_RELEASE_CHECKED=1` recursion guard prevents the pre-release gate from re-entering itself when it runs deploy orchestration tests. `SEPSISCARE_SKIP_PRE_RELEASE_CHECK=1` is available only as an explicit emergency/manual override, requires a non-empty `SEPSISCARE_SKIP_PRE_RELEASE_REASON`, and writes an owner-only JSONL audit event to `.sepsiscare-runtime/security-checks/pre_release_override_audit.jsonl` before SSH preflight. The audit event records UTC timestamp, command, user, host, and the stated reason, without logging bearer tokens or environment contents.
- `02_model_deploy_package/deploy/remote_server_one_click_deploy.sh doctor/start/restart` runs the packaged runtime data audit before serving the remote Linux/macOS model service.
- `02_model_deploy_package/deploy/start_model_service_windows.ps1 doctor/start/restart` runs the packaged runtime data audit before serving the Windows model service and writes `.runtime/runtime_data_audit.json`.

### Data Pollution and Abuse Resistance

- Remote model service requests are limited by `SEPSISCARE_MAX_JSON_BODY_BYTES` with a default 1 MiB cap.
- Arbitrary training terminal config payloads are not persisted; only the explicit allowlist survives.
- Local and remote prediction/diagnosis endpoints reject non-numeric or out-of-range clinical numeric values with `422 invalid_clinical_payload` and emit privacy-preserving validation-failure audit events.
- Training command requests emit privacy-preserving action-level audit events without logging command text, bearer tokens, request bodies, or raw parameters.
- The model service keeps artifact generation to known model/report roots, rebuilds the ZIP before download, skips symlinked files, excludes mutable logs/config secrets, and emits SHA256 plus optional HMAC integrity evidence for downloadable artifact contents.
- Batch diagnosis is capped to the first 20 patient objects.
- Runtime data auditing now separates fatal release blockers from `_detail_profile` display-summary warnings. Fatal blockers include missing provenance, duplicate ids, raw identifier fields/text, orphan detail records, and out-of-range clinical values in detail time-series rows.
- Realtime ICU ingest and remote time-series ingest reject malformed or
  out-of-range clinical numeric values before they can be recorded or used by
  incremental training.
- Remote `continue_training` reports whether new ICU events were consumed via
  `incremental_new_events` and `incremental_train_events`, so a button click
  without new data is distinguishable from a real incremental training run.

### Medical Ethics Guardrails

- Family-facing and research-facing AI prompts tell the assistant to avoid diagnostic conclusions, avoid replacing clinician instructions, and avoid inventing unavailable results.
- The implementation now minimizes patient-identifying context before external LLM calls.
- Outputs remain decision-support/demo outputs. They must not be treated as autonomous clinical orders or final diagnoses.

## Residual Risks and Required Follow-up

- A repository-scoped Codex Security threat model has been persisted to `/tmp/codex-security-scans/SepsisCare_macOS_app_model_transfer_20260528/threat_model.md` and copied into the current scan context under `/tmp/codex-security-scans/SepsisCare_macOS_app_model_transfer_20260528/5adb78e_20260603T100407Z/artifacts/01_context/threat_model.md`.
- A full Codex Security repository-wide scan has not been completed because the Codex Security workflow requires explicit authorization to use subagents for exhaustive coverage.
- This pass does not perform formal HIPAA Expert Determination, IRB review, FDA/medical-device review, or clinical safety validation.
- Remote deployment should still run behind Tailscale/VPN or TLS, with token rotation and least-privilege environment management.
- Local `runtime_data` can contain rich de-identified clinical profiles used internally. Public APIs sanitize these rows, but production PHI or re-identifiable data should not be stored in the repository.
- HMAC manifest signing and local verification are available when `SEPSISCARE_ARTIFACT_SIGNING_KEY` is configured. Clinical or regulated deployment still needs managed release-key rotation, separation between build and serving credentials, and a trusted release manifest outside the downloadable artifact.
- Audit logging now covers remote model auth failures, artifact downloads, local/remote history exports, local/remote clinical validation failures, invalid family-binding and detail-path references, training command actions, DeepSeek config changes, and admin binding updates. Runtime audit/log/config files are owner-only on POSIX hosts. Extend auditing to any future model-service administrative actions before regulated deployment.
- Data poisoning controls now include request-size limits, clinical numeric range validation, allowlisted persisted config, and release-package training metadata integrity checks. Raw-source duplicate/outlier review and malicious clinical sample detection still need a dedicated data-governance pass.
- Training package pollution controls now include release-metadata provenance checks, split-policy checks, training-patient total consistency checks, target-run presence checks, and metric range checks. This does not replace raw-source data-governance review for malicious clinical samples.
- Current runtime data audit has 0 fatal violations in both deployed and local-backend copies, but still reports 261 `_detail_profile` clinical range warnings. These are derived display summaries and should be reviewed in a future cleanup pass before regulated deployment.
- Realtime ICU integration has a tested API and demo loop, but production
  hospital connection still needs formal hospital feed mapping, token/TLS or
  VPN configuration, monitoring, retention policy, and clinical governance
  approval.

## Verification Evidence

Fresh verification run after this pass:

- `python3 -m unittest 02_model_deploy_package/deploy/test_model_service.py` -> 35 tests OK
- `python3 -m unittest 02_model_deploy_package/deploy/test_verify_artifact_bundle.py` -> 4 tests OK
- `python3 -m unittest script/test_runtime_data_audit.py` -> 2 tests OK
- `python3 -m unittest script/test_sensitive_data_audit.py` -> 7 tests OK
- `python3 -m unittest script/test_training_data_integrity_audit.py` -> 3 tests OK
- `bash script/test_pre_release_security_check.sh` -> passed
- `python3 script/audit_runtime_data.py 02_model_deploy_package/runtime_data` -> 0 fatal violations, 261 `_detail_profile` warnings
- `python3 script/audit_runtime_data.py apps/sepsiscare-studio/backend/runtime_data` -> 0 fatal violations, 261 `_detail_profile` warnings
- `python3 script/audit_sensitive_data.py 02_model_deploy_package apps/sepsiscare-studio/backend apps/sepsiscare-web-client apps/SepsisCare-Windows/renderer/web apps/SepsisCare-iOS/Resources/Web apps/SepsisCare-Android/app/src/main/assets/web` -> 6 roots, 0 findings
- `python3 script/audit_training_data_integrity.py 02_model_deploy_package` -> 4 sources, 347634 declared train patients, 1 target run row, 0 violations
- `python3 -m unittest test_server.py` in `apps/sepsiscare-studio/backend` -> 20 tests OK
- `bash script/test_deploy_model_to_remote_server.sh` -> passed; covers pre-release gate-before-`all`, recursion guard, rejection of reasonless break-glass overrides, audited break-glass pre-release override before SSH preflight, pre-transfer runtime data audit and release-file sensitive data audit for `sync/all`, audit-failure stop-before-`rsync`, dry-run Bearer-token redaction, signed artifact verification, and Windows start-script audit coverage
- `bash script/test_sepsiscare_services.sh` -> passed
- `bash 02_model_deploy_package/deploy/test_remote_server_one_click_deploy.sh` -> passed; covers one-click `doctor/start/smoke` including runtime data audit output
- `bash script/test_web_auth_token.sh` -> passed
- `bash script/test_demo_auth_boundary.sh` -> passed
- `bash script/test_web_content_escape.sh` -> passed
- `bash script/test_web_syntax.sh` -> passed
- `bash script/test_deployment_doc_secret_hygiene.sh` -> passed
- `swift build` in `SepsisCare-macOS` -> passed
- `swift build` in `apps/SepsisCare-macOS` -> passed
- `bash script/pre_release_security_check.sh` -> passed
- `git diff --check` -> passed

Additional realtime ICU closed-loop verification on 2026-06-04:

- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_server.py` in `04_client_source/apps/sepsiscare-studio/backend` -> 21 tests OK, including realtime ICU ingest/upload coverage
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_model_service.py` in `03_remote_server_model_package/02_model_deploy_package/deploy` -> 38 tests OK, including remote time-series ingest feeding incremental training state
- `bash ./06_scripts/script/test_web_syntax.sh` -> passed
- `bash ./06_scripts/script/test_web_content_escape.sh` -> passed
- `bash ./06_scripts/script/test_web_auth_token.sh` -> passed
- `./06_scripts/script/test_sepsiscare_services.sh` -> passed
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 ./06_scripts/script/smoke_test.py http://127.0.0.1:20065 http://127.0.0.1:20088 --require-model` -> passed, including realtime ICU ingest, upload, remote `continue_training`, and remote time-series status checks

Blocked verification:

- `swift test` in both macOS package roots still fails before running tests because this machine lacks the XCTest module: `error: no such module 'XCTest'`. `xcrun --find xctest` also fails with `unable to find utility "xctest"`.
