import importlib.util
import base64
import io
import hashlib
import hmac
import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient


MODULE_PATH = Path(__file__).resolve().parent / "model_service.py"
SPEC = importlib.util.spec_from_file_location("sepsiscare_model_service_under_test", MODULE_PATH)
model_service = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(model_service)

STRONG_TEST_TOKEN = "secure-token-1234567890"


class ModelServiceCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(model_service.app)

    def assert_owner_only_file(self, path):
        mode = stat.S_IMODE(path.stat().st_mode)
        self.assertEqual(mode & 0o077, 0, f"{path} mode {mode:o} grants group/other access")

    def test_remote_sensitive_endpoints_require_configured_bearer_token(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False):
            blocked = remote_client.post("/api/training/command", json={"action": "stream_metrics"})
            self.assertEqual(blocked.status_code, 401)
            self.assertEqual(blocked.json()["error"], "authorization_required")

            allowed = remote_client.post(
                "/api/training/command",
                json={"action": "stream_metrics"},
                headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
            )
            self.assertEqual(allowed.status_code, 200)
            self.assertTrue(allowed.json()["ok"])

            blocked_audit = remote_client.get("/api/audit")
            self.assertEqual(blocked_audit.status_code, 401)
            self.assertEqual(blocked_audit.json()["error"], "authorization_required")

            allowed_audit = remote_client.get("/api/audit", headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"})
            self.assertEqual(allowed_audit.status_code, 200)
            self.assertTrue(allowed_audit.json()["ok"])

    def test_remote_sensitive_endpoints_reject_weak_configured_token(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        weak_tokens = ("123123", "password", "同一个token", "short-token")
        for weak_token in weak_tokens:
            with self.subTest(weak_token=weak_token), tempfile.TemporaryDirectory() as tmp_dir:
                runtime_root = Path(tmp_dir)
                with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.dict(
                    model_service.os.environ,
                    {"SEPSISCARE_SERVICE_TOKEN": weak_token, "SEPSISCARE_TRAINING_TOKEN": ""},
                    clear=False,
                ):
                    response = remote_client.get(
                        "/api/patients?page=1&per_page=1",
                    )
                    audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

            self.assertEqual(response.status_code, 403)
            self.assertEqual(response.json()["error"], "weak_auth_token_configured")
            self.assertEqual(len(audit_rows), 1)
            event = json.loads(audit_rows[0])
            self.assertEqual(event["reason"], "weak_auth_token_configured")
            self.assertNotIn(weak_token, audit_rows[0])

    def test_remote_sensitive_endpoints_fail_closed_without_configured_token(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": "", "SEPSISCARE_TRAINING_TOKEN": ""}, clear=False):
            response = remote_client.get("/api/patients?page=1&per_page=1")
            audit_response = remote_client.get("/api/audit")

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["error"], "remote_auth_not_configured")
        self.assertEqual(audit_response.status_code, 403)
        self.assertEqual(audit_response.json()["error"], "remote_auth_not_configured")

    def test_remote_ops_requires_auth_and_rejects_arbitrary_commands(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False):
            blocked = remote_client.post("/api/admin/remote-ops/command", json={"action": "status"})
            self.assertEqual(blocked.status_code, 401)
            self.assertEqual(blocked.json()["error"], "authorization_required")

            rejected = remote_client.post(
                "/api/admin/remote-ops/command",
                json={"action": "shell", "command": "whoami"},
                headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
            )

        self.assertEqual(rejected.status_code, 400)
        self.assertEqual(rejected.json()["error"], "unsupported_remote_op")
        self.assertNotIn("whoami", json.dumps(rejected.json(), ensure_ascii=False))

    def test_remote_ops_verify_actual_training_runs_adapter_training(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            runtime_root = root / ".runtime"
            state_path = runtime_root / "training_state.json"
            timeseries_path = runtime_root / "icu_timeseries.jsonl"
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            model_root.mkdir(parents=True)
            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
                patch.object(model_service, "STATE_PATH", state_path),
                patch.object(model_service, "ICU_TIMESERIES_PATH", timeseries_path, create=True),
                patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False),
            ):
                response = remote_client.post(
                    "/api/admin/remote-ops/command",
                    json={"action": "verify_actual_training"},
                    headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
                )

                adapter_path = model_root / "incremental_icu_adapter.json"
                adapter_payload = json.loads(adapter_path.read_text(encoding="utf-8"))

        payload = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["action"], "verify_actual_training")
        self.assertEqual(payload["training"]["task_status"], "trained")
        self.assertGreaterEqual(payload["training"]["metrics"]["actual_training_examples"], 2)
        self.assertGreater(payload["adapter"]["optimizer_steps"], 0)
        self.assertIn("managed-runtime/remote_ops/", payload["evidence_path"])
        self.assertNotEqual(adapter_payload["weights"]["vitals.heart_rate"], 0)
        self.assertNotEqual(adapter_payload["weights"]["labs.lactate"], 0)

    def test_remote_ops_update_zip_rejects_path_traversal_and_applies_allowlisted_files(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            runtime_root = root / ".runtime"
            target = root / "deploy" / "model_service.py"
            target.parent.mkdir(parents=True)
            target.write_text("old service\n", encoding="utf-8")

            unsafe_buffer = io.BytesIO()
            with zipfile.ZipFile(unsafe_buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("../escape.txt", "bad")
            unsafe_blob = unsafe_buffer.getvalue()

            safe_buffer = io.BytesIO()
            with zipfile.ZipFile(safe_buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("deploy/model_service.py", "new service\n")
            safe_blob = safe_buffer.getvalue()

            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
                patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False),
            ):
                unsafe = remote_client.post(
                    "/api/admin/remote-ops/command",
                    json={
                        "action": "apply_update_zip",
                        "zip_base64": base64.b64encode(unsafe_blob).decode("ascii"),
                        "sha256": hashlib.sha256(unsafe_blob).hexdigest(),
                    },
                    headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
                )
                applied = remote_client.post(
                    "/api/admin/remote-ops/command",
                    json={
                        "action": "apply_update_zip",
                        "zip_base64": base64.b64encode(safe_blob).decode("ascii"),
                        "sha256": hashlib.sha256(safe_blob).hexdigest(),
                    },
                    headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
                )
            target_text = target.read_text(encoding="utf-8")

        self.assertEqual(unsafe.status_code, 400)
        self.assertEqual(unsafe.json()["error"], "unsafe_update_entry")
        self.assertEqual(applied.status_code, 200)
        self.assertTrue(applied.json()["ok"])
        self.assertEqual(applied.json()["applied_files"], ["deploy/model_service.py"])
        self.assertEqual(target_text, "new service\n")

    def test_remote_ops_update_zip_accepts_rooted_bundle_directory_entries(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            runtime_root = root / ".runtime"
            target = root / "deploy" / "model_service.py"
            target.parent.mkdir(parents=True)
            target.write_text("old service\n", encoding="utf-8")

            update_buffer = io.BytesIO()
            with zipfile.ZipFile(update_buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("rog_actual_training_update/", "")
                archive.writestr("rog_actual_training_update/deploy/", "")
                archive.writestr("rog_actual_training_update/deploy/model_service.py", "new service\n")
            update_blob = update_buffer.getvalue()

            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
                patch.dict(model_service.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False),
            ):
                applied = remote_client.post(
                    "/api/admin/remote-ops/command",
                    json={
                        "action": "apply_update_zip",
                        "zip_base64": base64.b64encode(update_blob).decode("ascii"),
                        "sha256": hashlib.sha256(update_blob).hexdigest(),
                    },
                    headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
                )
            target_text = target.read_text(encoding="utf-8")

        self.assertEqual(applied.status_code, 200)
        self.assertTrue(applied.json()["ok"])
        self.assertEqual(applied.json()["applied_files"], ["deploy/model_service.py"])
        self.assertEqual(target_text, "new service\n")

    def test_auth_failures_write_privacy_preserving_audit_event(self):
        remote_client = TestClient(model_service.app, client=("203.0.113.10", 50000))
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.dict(
                model_service.os.environ,
                {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN},
                clear=False,
            ):
                response = remote_client.get(
                    "/api/patients?page=1&per_page=1",
                    headers={"Authorization": "Bearer wrong-token"},
                )
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.status_code, 401)
        self.assertEqual(len(audit_rows), 1)
        event = json.loads(audit_rows[0])
        self.assertEqual(event["event"], "auth_failure")
        self.assertEqual(event["path"], "/api/patients")
        self.assertEqual(event["client"], "203.0.113.10")
        self.assertNotIn("wrong-token", audit_rows[0])
        self.assertNotIn(STRONG_TEST_TOKEN, audit_rows[0])

    def test_public_health_and_config_do_not_expose_runtime_paths(self):
        health = self.client.get("/health").json()
        self.assertNotIn("package_root", health)
        self.assertNotIn("model_root", health)
        self.assertNotIn("config_path", health)
        self.assertNotIn("database_root", health)

        deployment = self.client.get("/api/deployment/config").json()
        self.assertNotIn("database_root", deployment)
        self.assertNotIn("artifacts_dir", deployment)

        deepseek = self.client.get("/api/config/deepseek").json()
        self.assertEqual(deepseek["config_path"], "managed-runtime/deepseek_config.json")

    def test_packaged_history_database_is_deidentified_by_schema(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            database_root = Path(tmp_dir)
            (database_root / "history_patients.json").write_text(
                json.dumps(
                    [
                        {
                            "history_id": "HICU-1",
                            "masked_id": "HX-1",
                            "data_source": "MIMIC-IV",
                            "center": "BIDMC",
                            "icu_type": "ICU",
                            "quality_tag": "真实脱敏",
                            "icu_admit_time": "2174-01-01 00:00",
                            "icu_discharge_time": "2174-01-02 00:00",
                            "los_hours": 24,
                            "outcome": "存活",
                            "primary_phenotype": "P0",
                            "phenotype_consistency": {"code": "exact"},
                            "parameter_consistency": {"code": "mostly"},
                            "missing_rate": 0.0,
                            "available_prediction_windows": 4,
                            "model_version": "S7",
                            "favorite": True,
                            "annotation_status": "真实脱敏",
                            "_detail_profile": {"heart_rate": 90},
                            "subject_id": 123,
                            "hadm_id": 456,
                            "patient_name": "Alice",
                            "mrn": "MRN-1",
                            "dob": "1970-01-01",
                            "address": "raw address",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            (database_root / "history_details.json").write_text(
                json.dumps(
                    {
                        "HICU-1": [
                            {
                                "minute": 0,
                                "heart_rate": 90,
                                "map": 70,
                                "spo2": 96,
                                "temperature": 37.1,
                                "creatinine": 1.0,
                                "wbc": 8.0,
                                "platelet": 200,
                                "subject_id": 123,
                                "note": "raw bedside note",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with patch.object(model_service, "DATABASE_ROOT", database_root):
                patients, details = model_service.load_database_rows()

        patient = patients[0]
        self.assertEqual(patient["masked_id"], "HX-1")
        self.assertNotIn("_detail_profile", patient)
        for key in ("subject_id", "hadm_id", "patient_name", "mrn", "dob", "address"):
            self.assertNotIn(key, patient)
        self.assertEqual(details["HICU-1"][0]["heart_rate"], 90)
        self.assertNotIn("subject_id", details["HICU-1"][0])
        self.assertNotIn("note", details["HICU-1"][0])

    def test_training_sync_config_persists_sanitized_payload_only(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            state_path = runtime_root / "training_state.json"
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.object(model_service, "STATE_PATH", state_path):
                response = self.client.post(
                    "/api/training/command",
                    json={
                        "action": "sync_config",
                        "cloud_base_url": "http://100.65.136.96:8788",
                        "api_key": "sk-secret",
                        "token": "service-token",
                        "params": {
                            "source": "macos",
                            "subject_id": "raw-subject",
                            "safe_mode": True,
                        },
                    },
                )

                self.assertEqual(response.status_code, 200)
                persisted = json.loads((runtime_root / "last_terminal_config.json").read_text(encoding="utf-8"))

        serialized = json.dumps(persisted, ensure_ascii=False)
        self.assertNotIn("sk-secret", serialized)
        self.assertNotIn("service-token", serialized)
        self.assertNotIn("raw-subject", serialized)
        self.assertEqual(persisted["params"], {"source": "macos", "safe_mode": True})

    def test_artifact_bundle_excludes_runtime_logs_and_secret_config(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            runtime_root = root / ".runtime"
            config_path = root / "config" / "deploy.yaml"
            log_path = runtime_root / "training_service.log"
            model_root.mkdir(parents=True)
            report_root.mkdir()
            config_path.parent.mkdir()
            runtime_root.mkdir()
            (model_root / "trajectory_encoder_report.json").write_text("{}", encoding="utf-8")
            (report_root / "summary.txt").write_text("ok", encoding="utf-8")
            config_path.write_text("api_key: sk-secret\nmodel: s7\n", encoding="utf-8")
            log_path.write_text("Authorization: Bearer service-token\n", encoding="utf-8")
            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "CONFIG_PATH", config_path),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
                patch.object(model_service, "LOG_PATH", log_path),
            ):
                artifact = model_service.build_artifact_bundle()

            with zipfile.ZipFile(artifact_dir / artifact["name"]) as archive:
                names = set(archive.namelist())
                combined = b"".join(archive.read(name) for name in names)

        self.assertIn("models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder_report.json", names)
        self.assertIn("reports/summary.txt", names)
        self.assertNotIn(".runtime/training_service.log", names)
        self.assertNotIn("config/deploy.yaml", names)
        self.assertNotIn(b"sk-secret", combined)
        self.assertNotIn(b"service-token", combined)

    def test_artifact_bundle_contains_sha256_manifest(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            model_file = model_root / "trajectory_encoder_report.json"
            report_file = report_root / "summary.txt"
            model_file.parent.mkdir(parents=True)
            report_root.mkdir()
            model_file.write_text('{"model":"s7"}', encoding="utf-8")
            report_file.write_text("ok", encoding="utf-8")
            model_sha256 = hashlib.sha256(model_file.read_bytes()).hexdigest()
            report_sha256 = hashlib.sha256(report_file.read_bytes()).hexdigest()
            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
            ):
                artifact = model_service.build_artifact_bundle()

            bundle_path = artifact_dir / artifact["name"]
            with zipfile.ZipFile(bundle_path) as archive:
                manifest = archive.read("MANIFEST.sha256").decode("utf-8").splitlines()
                names = set(archive.namelist())
            bundle_sha256 = hashlib.sha256(bundle_path.read_bytes()).hexdigest()

        model_entry = "models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder_report.json"
        report_entry = "reports/summary.txt"
        self.assertIn("MANIFEST.sha256", names)
        self.assertIn(f"{model_sha256}  {model_entry}", manifest)
        self.assertIn(f"{report_sha256}  {report_entry}", manifest)
        self.assertNotIn("MANIFEST.sha256", "\n".join(manifest))
        self.assertEqual(artifact["sha256"], bundle_sha256)

    def test_artifact_bundle_signs_manifest_when_hmac_key_is_configured(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            model_file = model_root / "trajectory_encoder_report.json"
            model_file.parent.mkdir(parents=True)
            report_root.mkdir()
            model_file.write_text('{"model":"s7"}', encoding="utf-8")
            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
                patch.dict(model_service.os.environ, {"SEPSISCARE_ARTIFACT_SIGNING_KEY": "hmac-secret"}, clear=False),
            ):
                artifact = model_service.build_artifact_bundle()

            with zipfile.ZipFile(artifact_dir / artifact["name"]) as archive:
                manifest_bytes = archive.read("MANIFEST.sha256")
                signature = json.loads(archive.read("MANIFEST.sha256.hmac").decode("utf-8"))
                archive_names = set(archive.namelist())
            expected = hmac.new(b"hmac-secret", manifest_bytes, hashlib.sha256).hexdigest()

        self.assertIn("MANIFEST.sha256.hmac", archive_names)
        self.assertEqual(signature["algorithm"], "HMAC-SHA256")
        self.assertEqual(signature["signed"], "MANIFEST.sha256")
        self.assertEqual(signature["signature"], expected)
        self.assertEqual(artifact["manifest_signature"], "MANIFEST.sha256.hmac")
        self.assertNotIn("hmac-secret", json.dumps(artifact))

    def test_artifact_bundle_skips_symlinked_files(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            secret_path = root / ".runtime" / "service.env"
            model_file = model_root / "trajectory_encoder_report.json"
            symlink_path = model_root / "leaked_service_env.txt"
            model_file.parent.mkdir(parents=True)
            report_root.mkdir()
            secret_path.parent.mkdir()
            model_file.write_text('{"model":"s7"}', encoding="utf-8")
            secret_path.write_text("SEPSISCARE_SERVICE_TOKEN=service-token\n", encoding="utf-8")
            try:
                symlink_path.symlink_to(secret_path)
            except OSError as exc:
                self.skipTest(f"symlink creation unavailable: {exc}")

            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
            ):
                artifact = model_service.build_artifact_bundle()

            with zipfile.ZipFile(artifact_dir / artifact["name"]) as archive:
                names = set(archive.namelist())
                combined = b"".join(archive.read(name) for name in names)

        self.assertIn("models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder_report.json", names)
        self.assertNotIn("models/cloud_production/s7_phenotype_contrastive_full_20260516/leaked_service_env.txt", names)
        self.assertNotIn(b"service-token", combined)

    def test_prompt_payload_redacts_identifiers_and_secrets(self):
        prompt = model_service.json_for_prompt(
            {
                "current": {"heart_rate": 90, "map": 70},
                "patient_name": "Alice Example",
                "mrn": "MRN-12345",
                "dob": "1970-01-01",
                "address": "123 Main Street",
                "token": "service-token",
                "params": {"subject_id": "raw-subject", "safe_mode": True},
                "patient_ref": "SC-12001",
                "masked_id": "HX-700001",
                "bed_no": "ICU-09",
                "history_id": "EICU-181383",
            }
        )

        for needle in (
            "Alice Example",
            "MRN-12345",
            "1970-01-01",
            "123 Main Street",
            "service-token",
            "raw-subject",
            "SC-12001",
            "HX-700001",
            "ICU-09",
            "EICU-181383",
        ):
            self.assertNotIn(needle, prompt)
        self.assertIn("[redacted]", prompt)
        self.assertIn('"heart_rate": 90', prompt)
        self.assertIn('"safe_mode": true', prompt)

    def test_family_chat_redacts_common_identifiers_before_prompting_llm(self):
        with patch.object(
            model_service,
            "deepseek_chat_completion",
            return_value={"content": "ok", "model": "deepseek-v4-flash"},
        ) as deepseek:
            response = self.client.post(
                "/api/family/chat",
                json={
                    "question": "请解释 MRN: MRN-12345, email alice@example.com, phone 555-123-4567, patient SC-12001, bed ICU-09 的风险",
                    "patient_ref": "SC-12001",
                    "current": {"heart_rate": 90, "mrn": "MRN-12345", "masked_id": "HX-700001", "bed_no": "ICU-09"},
                },
            ).json()

        self.assertEqual(response["source"], "deepseek")
        deepseek.assert_called_once()
        messages = deepseek.call_args.args[0]
        serialized = json.dumps(messages, ensure_ascii=False)
        for needle in ("MRN-12345", "alice@example.com", "555-123-4567", "SC-12001", "HX-700001", "ICU-09"):
            self.assertNotIn(needle, serialized)
        self.assertIn("[redacted-mrn]", serialized)
        self.assertIn("[redacted-email]", serialized)
        self.assertIn("[redacted-phone]", serialized)
        self.assertIn("[redacted-patient-ref]", serialized)
        self.assertIn("[redacted-bed]", serialized)

    def test_ai_analysis_returns_model_training_and_llm_status(self):
        response = self.client.get("/api/ai/analysis")
        payload = response.json()

        self.assertEqual(response.status_code, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["source"], "remote-windows-model-server")
        self.assertEqual(payload["model_id"], model_service.MODEL_ID)
        self.assertIn("metrics", payload)
        self.assertEqual(payload["metrics"]["macro_f1"], model_service.metric_snapshot()["macro_f1"])
        self.assertIn("training_status", payload)
        self.assertIn("llm", payload)
        self.assertIn("患者", payload["summary"])
        self.assertIn("macro_f1", payload["summary"])

    def test_ai_analysis_uses_deepseek_when_available(self):
        with patch.object(
            model_service,
            "deepseek_chat_completion",
            return_value={"content": "DeepSeek 已分析当前 ICU 队列和模型训练指标。", "model": "deepseek-chat"},
        ) as deepseek:
            response = self.client.get("/api/ai/analysis")
            payload = response.json()

        self.assertEqual(response.status_code, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["source"], "deepseek")
        self.assertEqual(payload["model"], "deepseek-chat")
        self.assertEqual(payload["summary"], "DeepSeek 已分析当前 ICU 队列和模型训练指标。")
        deepseek.assert_called_once()
        serialized = json.dumps(deepseek.call_args.args[0], ensure_ascii=False)
        self.assertIn("macro_f1", serialized)
        self.assertIn("高风险", serialized)

    def test_llm_diagnose_fallback_uses_patient_payload_and_prediction(self):
        response = self.client.post(
            "/api/ai/llm-diagnose",
            json={
                "vitals": {"heart_rate": 112, "map": 61.0, "spo2": 93.0},
                "labs": {"lactate": 4.2, "wbc": 15.1, "creatinine": 1.6},
                "context": {
                    "patient": {"masked_id": "SC-12000"},
                    "training_status": {"task_status": "idle"},
                },
            },
        )
        payload = response.json()

        self.assertEqual(response.status_code, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["source"], "remote-windows-model-server")
        self.assertNotIn("演示分析", payload["summary"])
        self.assertIn("乳酸=4.2", payload["summary"])
        self.assertIn("MAP=61.0", payload["summary"])
        self.assertIn("mortality_probability", payload["diagnosis"]["latest"])

    def test_ai_explain_fallback_includes_context_and_provider_boundary(self):
        response = self.client.post(
            "/api/ai/explain",
            json={"term": "SOFA评分", "context": {"training_status": {"task_status": "idle"}, "model": {"model_id": model_service.MODEL_ID}}},
        )
        payload = response.json()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(payload["source"], "remote-windows-model-server")
        self.assertIn("SOFA评分", payload["explanation"])
        self.assertIn("DeepSeek 未配置", payload["explanation"])
        self.assertIn(model_service.MODEL_ID, payload["explanation"])

    def test_sensitive_endpoint_rejects_oversized_json_body(self):
        with patch.object(model_service, "BODY_LIMIT_BYTES", 64, create=True):
            response = self.client.post("/api/model/predict", json={"notes": "x" * 256})

        self.assertEqual(response.status_code, 413)
        self.assertEqual(response.json()["error"], "payload_too_large")

    def test_prediction_rejects_out_of_range_clinical_values_and_audits(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.post(
                    "/api/model/predict",
                    json={"vitals": {"map": -10, "spo2": 140}, "labs": {"lactate": "not-a-number"}},
                )
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.status_code, 422)
        payload = response.json()
        self.assertEqual(payload["error"], "invalid_clinical_payload")
        self.assertIn("vitals.map", payload["fields"])
        self.assertIn("vitals.spo2", payload["fields"])
        self.assertIn("labs.lactate", payload["fields"])
        event = json.loads(audit_rows[0])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/model/predict")
        self.assertIn("vitals.map", event["fields"])
        self.assertNotIn("not-a-number", audit_rows[0])

    def test_model_service_exposes_macos_patient_database_endpoints(self):
        health = self.client.get("/health").json()
        self.assertTrue(health["ok"])
        self.assertEqual(health["status"], "ok")
        self.assertEqual(health["service"], "sepsiscare-model-service")

        patients = self.client.get("/api/patients?page=1&per_page=3").json()
        self.assertIn("patients", patients)
        self.assertGreaterEqual(patients["total"], 3)
        first_id = patients["patients"][0]["masked_id"]

        detail = self.client.get(f"/api/patients/{first_id}").json()
        self.assertEqual(detail["patient"]["masked_id"], first_id)
        self.assertIn("history", detail)

        history = self.client.get("/api/history/patients?page=1&per_page=3").json()
        self.assertIn("patients", history)
        self.assertGreaterEqual(history["total"], 3)

        stats = self.client.get("/api/dashboard/stats").json()
        self.assertIn("active_patients", stats)
        self.assertIn("high_risk", stats)

    def test_model_service_training_command_builds_downloadable_artifact(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            artifact_dir = Path(tmp_dir) / "artifacts"
            external_log_path = Path(tmp_dir) / "runtime" / "training_service.log"
            with patch.object(model_service, "ARTIFACT_DIR", artifact_dir), patch.object(model_service, "LOG_PATH", external_log_path):
                command = self.client.post("/api/training/command", json={"action": "download_artifacts"}).json()
                self.assertTrue(command["ok"])
                self.assertEqual(command["task_status"], "idle")
                self.assertEqual(command["artifacts"][0]["download_url"], "/api/artifacts/latest")

                download = self.client.get("/api/artifacts/latest")
                self.assertEqual(download.status_code, 200)
                self.assertEqual(download.headers["content-type"], "application/zip")
                self.assertGreater(len(download.content), 100)

    def test_artifact_download_writes_audit_event_with_bundle_hash(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            runtime_root = root / ".runtime"
            model_root.mkdir(parents=True)
            report_root.mkdir()
            (model_root / "trajectory_encoder_report.json").write_text("{}", encoding="utf-8")
            (report_root / "summary.txt").write_text("ok", encoding="utf-8")
            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
            ):
                response = self.client.get("/api/artifacts/latest")
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()
                bundle_hash = hashlib.sha256((artifact_dir / "sepsiscare_model_artifacts_latest.zip").read_bytes()).hexdigest()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(audit_rows), 1)
        event = json.loads(audit_rows[0])
        self.assertEqual(event["event"], "artifact_download")
        self.assertEqual(event["sha256"], bundle_hash)
        self.assertEqual(event["artifact"], "sepsiscare_model_artifacts_latest.zip")

    def test_artifact_download_rebuilds_poisoned_cached_bundle(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            runtime_root = root / ".runtime"
            cached_bundle = artifact_dir / "sepsiscare_model_artifacts_latest.zip"
            model_file = model_root / "trajectory_encoder_report.json"
            model_file.parent.mkdir(parents=True)
            report_root.mkdir()
            artifact_dir.mkdir()
            model_file.write_text('{"model":"s7"}', encoding="utf-8")
            with zipfile.ZipFile(cached_bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("malicious.txt", "poisoned artifact")

            with (
                patch.object(model_service, "PACKAGE_ROOT", root),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
                patch.dict(model_service.os.environ, {"SEPSISCARE_ARTIFACT_SIGNING_KEY": "release-key"}, clear=False),
            ):
                response = self.client.get("/api/artifacts/latest")
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

            with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
                names = set(archive.namelist())

        self.assertEqual(response.status_code, 200)
        self.assertIn("models/cloud_production/s7_phenotype_contrastive_full_20260516/trajectory_encoder_report.json", names)
        self.assertIn("MANIFEST.sha256", names)
        self.assertIn("MANIFEST.sha256.hmac", names)
        self.assertNotIn("malicious.txt", names)
        self.assertEqual(json.loads(audit_rows[0])["event"], "artifact_download")

    def test_model_service_supports_full_smoke_training_terminal_contract(self):
        config = self.client.post(
            "/api/training/command",
            json={"action": "stream_metrics", "params": {"source": "macos-smoke"}},
        ).json()
        self.assertTrue(config["ok"])
        self.assertIn("metrics", config)
        self.assertIn("macro_f1", config["metrics"])
        self.assertIn("output", config)

    def test_icu_timeseries_ingest_feeds_incremental_training_state(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            runtime_root = root / ".runtime"
            model_root = root / "models" / "cloud_production" / model_service.MODEL_ID
            report_root = root / "reports"
            artifact_dir = root / "artifacts"
            state_path = runtime_root / "training_state.json"
            timeseries_path = runtime_root / "icu_timeseries.jsonl"
            model_root.mkdir(parents=True)
            report_root.mkdir()
            before_total = model_service.metric_snapshot()["total_train_patients"]

            with (
                patch.object(model_service, "RUNTIME_ROOT", runtime_root),
                patch.object(model_service, "STATE_PATH", state_path),
                patch.object(model_service, "MODEL_ROOT", model_root),
                patch.object(model_service, "REPORT_ROOT", report_root),
                patch.object(model_service, "ARTIFACT_DIR", artifact_dir),
                patch.object(model_service, "ICU_TIMESERIES_PATH", timeseries_path, create=True),
            ):
                ingest = self.client.post(
                    "/api/icu/timeseries/ingest",
                    json={
                        "source": "hospital-icu-interface",
                        "events": [
                            {
                                "patient_ref": "MRN-raw-12345",
                                "bed_no": "ICU-09",
                                "timestamp": "2026-06-04T14:00:00+08:00",
                                "vitals": {"heart_rate": 112, "map": 64, "resp_rate": 26, "spo2": 92, "temperature": 38.4},
                                "labs": {"lactate": 3.4, "wbc": 16.2},
                            },
                            {
                                "patient_ref": "MRN-raw-12345",
                                "bed_no": "ICU-09",
                                "timestamp": "2026-06-04T14:01:00+08:00",
                                "vitals": {"heart_rate": 114, "map": 62, "resp_rate": 27, "spo2": 91, "temperature": 38.5},
                                "labs": {"lactate": 3.5, "wbc": 16.3},
                            },
                        ],
                    },
                )
                training = self.client.post(
                    "/api/training/command",
                    json={"action": "continue_training", "params": {"source": "icu-realtime", "safe_mode": True}},
                )
                status = self.client.get("/api/training-terminal/status").json()
                self.assertEqual(ingest.status_code, 200)
                self.assertTrue(ingest.json()["ok"])
                rows = timeseries_path.read_text(encoding="utf-8").splitlines()
                report_files = list((report_root / "incremental_training").glob("*.json"))
                adapter_path = model_root / "incremental_icu_adapter.json"
                adapter_payload = json.loads(adapter_path.read_text(encoding="utf-8"))

        self.assertEqual(ingest.json()["accepted"], 2)
        serialized_rows = "\n".join(rows)
        for raw in ("MRN-raw-12345", "ICU-09"):
            self.assertNotIn(raw, serialized_rows)
        self.assertEqual(training.status_code, 200)
        trained = training.json()
        self.assertTrue(trained["ok"])
        self.assertEqual(trained["task_status"], "trained")
        self.assertEqual(trained["metrics"]["incremental_train_events"], 2)
        self.assertGreaterEqual(trained["metrics"]["total_train_patients"], before_total + 2)
        self.assertEqual(status["task_status"], "trained")
        self.assertEqual(status["metrics"]["incremental_train_events"], 2)
        self.assertTrue(report_files)
        self.assertEqual(trained["artifacts"][0]["kind"], "incremental_training_report")
        self.assertEqual(trained["metrics"]["actual_training_examples"], 2)
        self.assertEqual(trained["metrics"]["incremental_adapter_path"], "managed-runtime/models/incremental_icu_adapter.json")
        self.assertEqual(adapter_payload["training_examples"], 2)
        self.assertGreater(adapter_payload["optimizer_steps"], 0)
        self.assertIn("vitals.heart_rate", adapter_payload["weights"])
        self.assertIn("labs.lactate", adapter_payload["weights"])
        self.assertNotEqual(adapter_payload["weights"]["vitals.heart_rate"], 0)
        self.assertNotEqual(adapter_payload["weights"]["labs.lactate"], 0)

    def test_training_command_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            state_path = runtime_root / "training_state.json"
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.object(model_service, "STATE_PATH", state_path):
                response = self.client.post(
                    "/api/training/command",
                    json={"action": "stream_metrics", "params": {"source": "macos-smoke", "token": "secret-token"}},
                )
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.status_code, 200)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "training_command")
        self.assertEqual(event["action"], "stream_metrics")
        self.assertEqual(event["path"], "/api/training/command")
        self.assertNotIn("secret-token", "\n".join(audit_rows))

    def test_model_service_supports_predict_predict_compatibility_route(self):
        probe = self.client.get("/predict/predict").json()
        self.assertTrue(probe["ok"])
        self.assertEqual(probe["method"], "POST")

        response = self.client.post(
            "/predict/predict",
            json={"vitals": {"map": 68}, "labs": {"lactate": 3.2}},
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertIn("latest", payload)
        self.assertIn("risk_level", payload)
        self.assertIn("trajectory", payload)

    def test_training_terminal_action_wraps_direct_model_execution_for_macos_client(self):
        response = self.client.post("/api/training-terminal/action", json={"action": "stream_metrics"}).json()
        self.assertTrue(response["ok"])
        self.assertIn("status", response)
        self.assertIn("cloud_response", response)
        self.assertTrue(response["cloud_response"]["ok"])
        self.assertIn("远程 Windows 模型服务直接执行", response["output"][0])

    def test_training_terminal_config_persists_remote_cloud_base_url(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = Path(tmp_dir) / "training_state.json"
            with patch.object(model_service, "STATE_PATH", state_path):
                response = self.client.post(
                    "/api/training-terminal/config",
                    json={
                        "mode": "production",
                        "cloud_base_url": "http://100.65.136.96:8788/",
                        "params": {
                            "source": "macos",
                            "safe_mode": True,
                            "subject_id": "raw-subject",
                            "token": "service-token",
                        },
                    },
                ).json()

                self.assertTrue(response["ok"])
                self.assertEqual(response["status"]["cloud_base_url"], "http://100.65.136.96:8788")
                self.assertEqual(response["status"]["params"], {"source": "macos", "safe_mode": True})
                saved = json.loads(state_path.read_text(encoding="utf-8"))

                status = self.client.get("/api/training-terminal/status").json()
                self.assertEqual(status["cloud_base_url"], "http://100.65.136.96:8788")
                self.assertEqual(status["params"], {"source": "macos", "safe_mode": True})
                for raw in ("raw-subject", "service-token"):
                    self.assertNotIn(raw, json.dumps(response, ensure_ascii=False))
                    self.assertNotIn(raw, json.dumps(status, ensure_ascii=False))
                    self.assertNotIn(raw, json.dumps(saved, ensure_ascii=False))

    def test_training_terminal_config_rejects_ssrf_prone_cloud_base_url(self):
        unsafe_urls = (
            "http://169.254.169.254/latest/meta-data",
            "http://[fe80::1]/v1",
            "https://user:pass@example.com/v1",
            "file:///etc/passwd",
        )
        for unsafe_url in unsafe_urls:
            with self.subTest(unsafe_url=unsafe_url), tempfile.TemporaryDirectory() as tmp_dir:
                state_path = Path(tmp_dir) / "training_state.json"
                with patch.object(model_service, "STATE_PATH", state_path):
                    response = self.client.post(
                        "/api/training-terminal/config",
                        json={"mode": "production", "cloud_base_url": unsafe_url},
                    ).json()
                    status = self.client.get("/api/training-terminal/status").json()
                    saved = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}

            self.assertFalse(response["ok"])
            self.assertEqual(response["error"], "cloud_base_url_rejected")
            self.assertNotIn(unsafe_url, json.dumps(response, ensure_ascii=False))
            self.assertNotIn(unsafe_url, json.dumps(status, ensure_ascii=False))
            self.assertNotIn(unsafe_url, json.dumps(saved, ensure_ascii=False))

    def test_deepseek_config_defaults_to_v4_flash_unconfigured(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "deepseek_config.json"
            with patch.object(model_service, "DEEPSEEK_CONFIG_PATH", config_path), patch.dict(model_service.os.environ, {}, clear=True):
                response = self.client.get("/api/config/deepseek").json()

                self.assertEqual(response["provider"], "deepseek")
                self.assertFalse(response["configured"])
                self.assertEqual(response["model"], "deepseek-v4-flash")
                self.assertEqual(response["base_url"], "https://api.deepseek.com")
                self.assertEqual(response["api_key_hint"], "")

    def test_deepseek_config_post_persists_key_and_clear_key(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            config_path = runtime_root / "deepseek_config.json"
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.object(model_service, "DEEPSEEK_CONFIG_PATH", config_path), patch.dict(model_service.os.environ, {}, clear=True):
                saved = self.client.post(
                    "/api/config/deepseek",
                    json={
                        "api_key": "sk-test-123456",
                        "model": "deepseek-v4-flash",
                        "base_url": "https://api.deepseek.com/chat/completions",
                        "timeout_seconds": "21",
                    },
                ).json()

                self.assertTrue(saved["configured"])
                self.assertEqual(saved["model"], "deepseek-v4-flash")
                self.assertEqual(saved["base_url"], "https://api.deepseek.com/chat/completions")
                self.assertEqual(saved["timeout_seconds"], "21")
                self.assertEqual(saved["api_key_hint"], "...3456")

                cleared = self.client.post("/api/config/deepseek", json={"clear_key": True}).json()
                self.assertFalse(cleared["configured"])
                self.assertEqual(cleared["api_key_hint"], "")
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertGreaterEqual(len(audit_rows), 2)
        self.assertIn('"event": "config_change"', audit_rows[0])
        self.assertIn('"path": "/api/config/deepseek"', audit_rows[0])
        self.assertIn('"key_changed": true', audit_rows[0])
        self.assertNotIn("sk-test-123456", "\n".join(audit_rows))

    def test_deepseek_config_rejects_ssrf_prone_base_urls_without_logging_them(self):
        unsafe_urls = (
            "http://169.254.169.254/latest/meta-data",
            "https://10.0.0.5/v1",
            "http://example.com/v1",
            "https://user:pass@example.com/v1",
        )
        for unsafe_url in unsafe_urls:
            with self.subTest(unsafe_url=unsafe_url), tempfile.TemporaryDirectory() as tmp_dir:
                runtime_root = Path(tmp_dir)
                config_path = runtime_root / "deepseek_config.json"
                with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.object(model_service, "DEEPSEEK_CONFIG_PATH", config_path), patch.dict(model_service.os.environ, {}, clear=True):
                    response = self.client.post(
                        "/api/config/deepseek",
                        json={
                            "api_key": "sk-test-123456",
                            "model": "deepseek-v4-flash",
                            "base_url": unsafe_url,
                        },
                    ).json()
                    saved = json.loads(config_path.read_text(encoding="utf-8"))
                    audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

            self.assertEqual(response["base_url"], "https://api.deepseek.com")
            self.assertEqual(saved["base_url"], "https://api.deepseek.com")
            self.assertNotIn(unsafe_url, json.dumps(saved, ensure_ascii=False))
            self.assertIn('"base_url_rejected": true', audit_rows[-1])
            self.assertNotIn(unsafe_url, audit_rows[-1])

    def test_sensitive_runtime_files_are_owner_only_after_writes(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            config_path = runtime_root / "deepseek_config.json"
            audit_path = runtime_root / "security_audit.log"
            for path in (config_path, audit_path):
                path.write_text("{}\n", encoding="utf-8")
                path.chmod(0o666)

            with patch.object(model_service, "RUNTIME_ROOT", runtime_root), patch.object(model_service, "DEEPSEEK_CONFIG_PATH", config_path), patch.dict(model_service.os.environ, {}, clear=True):
                self.client.post(
                    "/api/config/deepseek",
                    json={
                        "api_key": "sk-test-123456",
                        "model": "deepseek-v4-flash",
                        "base_url": "https://api.deepseek.com/chat/completions",
                    },
                )

            self.assert_owner_only_file(config_path)
            self.assert_owner_only_file(audit_path)

    def test_admin_binding_update_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            patient_ref = model_service.PATIENTS[0]["masked_id"]
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.post(
                    "/api/admin/bindings",
                    json={"account": "family", "patient_ref": patient_ref},
                )
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.status_code, 200)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "admin_binding_update")
        self.assertEqual(event["path"], "/api/admin/bindings")
        self.assertEqual(event["account"], "family")
        self.assertIn("patient_ref_hash", event)
        self.assertNotIn(patient_ref, audit_rows[-1])

    def test_admin_binding_rejects_unknown_patient_ref_and_audits_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.post(
                    "/api/admin/bindings",
                    json={"account": "family", "patient_ref": "MRN-raw-12345"},
                )
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.status_code, 422)
        payload = response.json()
        self.assertEqual(payload["error"], "invalid_patient_ref")
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/admin/bindings")
        self.assertIn("patient_ref", event["fields"])
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_monitor_report_rejects_unknown_patient_ref_and_audits_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.get("/api/monitor/report/MRN-raw-12345")
                self.assertEqual(response.status_code, 422)
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        payload = response.json()
        self.assertEqual(payload["error"], "invalid_patient_ref")
        self.assertNotIn("MRN-raw-12345", response.text)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/monitor/report")
        self.assertIn("patient_ref", event["fields"])
        self.assertIn("patient_ref_hash", event)
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_detail_path_refs_reject_unknown_identifiers_and_audit_without_raw_identifier(self):
        cases = [
            ("/api/patients/MRN-raw-12345", "/api/patients", "MRN-raw-12345"),
            ("/api/bedside/snapshot/ICU-raw-99", "/api/bedside/snapshot", "ICU-raw-99"),
            ("/api/history/patients/MRN-raw-12345", "/api/history/patients", "MRN-raw-12345"),
        ]
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                responses = [(path, audit_path, raw_ref, self.client.get(path)) for path, audit_path, raw_ref in cases]
                for path, _audit_path, _raw_ref, response in responses:
                    self.assertEqual(response.status_code, 422, path)
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(audit_rows), len(cases))
        for index, (path, audit_path, raw_ref, response) in enumerate(responses):
            self.assertEqual(response.json()["error"], "invalid_patient_ref", path)
            self.assertNotIn(raw_ref, response.text, path)
            event = json.loads(audit_rows[index])
            self.assertEqual(event["event"], "data_validation_failure", path)
            self.assertEqual(event["path"], audit_path, path)
            self.assertIn("patient_ref_hash", event, path)
            self.assertNotIn(raw_ref, audit_rows[index], path)

    def test_history_export_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.get("/api/history/export?scope=list")
                audit_path = runtime_root / "security_audit.log"
                audit_exists = audit_path.exists()
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_exists else []

        self.assertEqual(response.status_code, 200)
        self.assertIn("history_id,masked_id,data_source", response.text)
        self.assertTrue(audit_exists)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "history_export")
        self.assertEqual(event["path"], "/api/history/export")
        self.assertEqual(event["scope"], "list")
        self.assertGreater(event["row_count"], 0)

    def test_history_list_filters_by_query_and_source_alias(self):
        by_query = self.client.get("/api/history/patients?query=HX-700019&per_page=100").json()
        by_search = self.client.get("/api/history/patients?search=HX-700019&per_page=100").json()
        by_source_alias = self.client.get("/api/history/patients?source=PhysioNet2012&per_page=100").json()

        self.assertEqual(by_query["total"], 1)
        self.assertEqual(by_query["patients"][0]["masked_id"], "HX-700019")
        self.assertEqual(by_search["total"], 1)
        self.assertEqual(by_search["patients"][0]["history_id"], "HICU-700019")
        self.assertGreater(by_source_alias["total"], 0)
        self.assertTrue(all(row["data_source"].replace(" ", "") == "PhysioNet2012" for row in by_source_alias["patients"]))

    def test_history_export_respects_search_filter(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.get("/api/history/export?scope=list&search=HX-700019&per_page=100")

        rows = [line for line in response.text.splitlines() if line.strip()]
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(rows), 2)
        self.assertIn("HX-700019", rows[1])
        self.assertNotIn("HX-700039", response.text)

    def test_history_export_rejects_unknown_history_id_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = Path(tmp_dir)
            with patch.object(model_service, "RUNTIME_ROOT", runtime_root):
                response = self.client.get("/api/history/export?scope=detail&history_id=MRN-raw-12345")
                self.assertEqual(response.status_code, 422)
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(response.json()["error"], "invalid_patient_ref")
        self.assertNotIn("MRN-raw-12345", response.text)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/history/export")
        self.assertIn("patient_ref_hash", event)
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_deepseek_config_allows_local_compatible_server_without_key(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            config_path = Path(tmp_dir) / "deepseek_config.json"
            with patch.object(model_service, "DEEPSEEK_CONFIG_PATH", config_path), patch.dict(model_service.os.environ, {}, clear=True):
                response = self.client.post(
                    "/api/config/deepseek",
                    json={
                        "model": "deepseek-v4-flash",
                        "base_url": "http://127.0.0.1:8000/v1",
                        "timeout_seconds": "5",
                    },
                ).json()

                self.assertTrue(response["configured"])
                self.assertEqual(response["base_url"], "http://127.0.0.1:8000/v1")

    def test_assistant_chat_uses_deepseek_when_available(self):
        with patch.object(
            model_service,
            "deepseek_chat_completion",
            return_value={"content": "来自 DeepSeek V4 Flash 的回答", "model": "deepseek-v4-flash"},
        ) as deepseek:
            response = self.client.post("/api/ai/assistant-chat", json={"question": "如何查看乳酸趋势？", "context": {}}).json()

        self.assertEqual(response["source"], "deepseek")
        self.assertEqual(response["model"], "deepseek-v4-flash")
        self.assertEqual(response["answer"], "来自 DeepSeek V4 Flash 的回答")
        deepseek.assert_called_once()

    def test_assistant_chat_fallback_uses_patient_and_training_context(self):
        with patch.object(model_service, "deepseek_chat_completion", side_effect=model_service.DeepSeekNotConfiguredError()):
            response = self.client.post(
                "/api/ai/assistant-chat",
                json={
                    "question": "SC-12000 当前风险依据是什么？",
                    "patient_ref": "SC-12000",
                    "context": {"training_status": {"task_status": "trained"}},
                },
            ).json()

        answer = response["answer"]
        self.assertEqual(response["source"], "remote-windows-model-server")
        self.assertIn("SC-12000", answer)
        self.assertIn("乳酸", answer)
        self.assertIn("MAP", answer)
        self.assertIn("macro_f1", answer)
        self.assertNotIn("已收到问题", answer)

    def test_family_chat_fallback_uses_patient_context_instead_of_received_only(self):
        with patch.object(model_service, "deepseek_chat_completion", side_effect=model_service.DeepSeekNotConfiguredError()):
            response = self.client.post(
                "/api/family/chat",
                json={"question": "乳酸升高是什么意思？", "patient_ref": "SC-12000"},
            ).json()

        answer = response["answer"]
        self.assertEqual(response["source"], "remote-windows-model-server")
        self.assertIn("SC-12000", answer)
        self.assertIn("乳酸", answer)
        self.assertIn("MAP", answer)
        self.assertIn("主管医生", answer)
        self.assertNotIn("已收到问题", answer)


if __name__ == "__main__":
    unittest.main()
