import io
import json
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

import server

STRONG_TEST_TOKEN = "secure-token-1234567890"


class BrokenStderr(io.StringIO):
    def write(self, text):
        raise BrokenPipeError()


class HandlerLoggingTests(unittest.TestCase):
    def test_log_message_ignores_broken_stderr(self):
        handler = object.__new__(server.Handler)
        with patch.object(sys, "stderr", BrokenStderr()):
            server.Handler.log_message(handler, "GET %s", "/health")


class MockCloudResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return json.dumps(self.payload).encode("utf-8")


class TrainingTerminalForwardingTests(unittest.TestCase):
    def assert_owner_only_file(self, path):
        mode = stat.S_IMODE(path.stat().st_mode)
        self.assertEqual(mode & 0o077, 0, f"{path} mode {mode:o} grants group/other access")

    def test_remote_sensitive_paths_require_bearer_token(self):
        with patch.dict(server.os.environ, {"SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN}, clear=False):
            blocked = server.security_failure_for_request(
                method="POST",
                path="/api/config/deepseek",
                headers={},
                client_host="203.0.113.10",
            )
            self.assertIsNotNone(blocked)
            self.assertEqual(blocked[0], 401)
            self.assertEqual(blocked[1]["error"], "authorization_required")

            allowed = server.security_failure_for_request(
                method="POST",
                path="/api/config/deepseek",
                headers={"Authorization": f"Bearer {STRONG_TEST_TOKEN}"},
                client_host="203.0.113.10",
            )
            self.assertIsNone(allowed)

            blocked_audit = server.security_failure_for_request(
                method="GET",
                path="/api/audit",
                headers={},
                client_host="203.0.113.10",
            )
            self.assertIsNotNone(blocked_audit)
            self.assertEqual(blocked_audit[0], 401)
            self.assertEqual(blocked_audit[1]["error"], "authorization_required")

    def test_remote_sensitive_paths_reject_weak_configured_token(self):
        for weak_token in ("123123", "password", "同一个token", "short-token"):
            with self.subTest(weak_token=weak_token), patch.dict(
                server.os.environ,
                {"SEPSISCARE_SERVICE_TOKEN": weak_token, "SEPSISCARE_TRAINING_TOKEN": ""},
                clear=False,
            ):
                blocked = server.security_failure_for_request(
                    method="GET",
                    path="/api/patients",
                    headers={"Authorization": f"Bearer {weak_token}"},
                    client_host="203.0.113.10",
                )

            self.assertIsNotNone(blocked)
            self.assertEqual(blocked[0], 403)
            self.assertEqual(blocked[1]["error"], "weak_auth_token_configured")

    def test_remote_sensitive_paths_fail_closed_without_configured_token(self):
        with patch.dict(server.os.environ, {"SEPSISCARE_SERVICE_TOKEN": "", "SEPSISCARE_TRAINING_TOKEN": ""}, clear=False):
            blocked = server.security_failure_for_request(
                method="GET",
                path="/api/patients",
                headers={},
                client_host="203.0.113.10",
            )

        self.assertIsNotNone(blocked)
        self.assertEqual(blocked[0], 403)
        self.assertEqual(blocked[1]["error"], "remote_auth_not_configured")

        with patch.dict(server.os.environ, {"SEPSISCARE_SERVICE_TOKEN": "", "SEPSISCARE_TRAINING_TOKEN": ""}, clear=False):
            blocked_audit = server.security_failure_for_request(
                method="GET",
                path="/api/audit",
                headers={},
                client_host="203.0.113.10",
            )

        self.assertIsNotNone(blocked_audit)
        self.assertEqual(blocked_audit[0], 403)
        self.assertEqual(blocked_audit[1]["error"], "remote_auth_not_configured")

    def test_public_responses_do_not_expose_runtime_paths(self):
        health = server.public_health_payload()
        self.assertEqual(health["data_dir"], "managed-runtime")
        self.assertNotIn(str(server.DEPLOY_ROOT), json.dumps(health, ensure_ascii=False))

        config = server.deepseek_config()
        self.assertEqual(config["config_path"], "managed-runtime/deepseek_config.json")

        bindings = server.binding_state()
        self.assertEqual(bindings["storage"], "managed-runtime/family_bindings.json")

    def test_local_transfer_defaults_point_to_local_api_rog_model_service_and_v4_flash(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            with patch.object(server, "TRAINING_STATE_PATH", state_path):
                status = server.training_status()

        config = server.deepseek_config()

        self.assertEqual(server.PUBLIC_API_BASE_URL, "http://127.0.0.1:8765")
        self.assertEqual(server.PUBLIC_MODEL_BASE_URL, "http://100.65.136.96:8788")
        self.assertEqual(status["cloud_base_url"], "http://100.65.136.96:8788")
        self.assertEqual(config["model"], "deepseek-v4-flash")
        self.assertEqual(config["base_url"], "https://api.deepseek.com")

    def test_training_status_migrates_legacy_loopback_model_service_to_rog(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            state_path.write_text(json.dumps({"cloud_base_url": "http://127.0.0.1:8788"}), encoding="utf-8")
            with patch.object(server, "TRAINING_STATE_PATH", state_path):
                status = server.training_status()

        self.assertEqual(status["cloud_base_url"], "http://100.65.136.96:8788")

    def test_diagnose_features_endpoint_returns_feature_schema(self):
        result = server.Handler.handle_get(object.__new__(server.Handler), "/api/diagnose/features", {})

        self.assertTrue(result["ok"])
        self.assertEqual(result["model_id"], server.MODEL_ID)
        self.assertIn("vitals", result["feature_groups"])
        self.assertIn("labs", result["feature_groups"])
        self.assertIn("heart_rate", result["feature_groups"]["vitals"])
        self.assertIn("lactate", result["feature_groups"]["labs"])
        self.assertIn("payload_schema", result)

    def test_deepseek_config_update_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            config_path = runtime_root / "deepseek_config.json"
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root), patch.object(server, "DEEPSEEK_CONFIG_PATH", config_path):
                result = server.Handler.handle_post(
                    handler,
                    "/api/config/deepseek",
                    {"api_key": "sk-test-123456", "model": "deepseek-chat"},
                )
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertTrue(result["configured"])
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "config_change")
        self.assertEqual(event["path"], "/api/config/deepseek")
        self.assertTrue(event["key_changed"])
        self.assertNotIn("sk-test-123456", audit_rows[-1])

    def test_deepseek_config_rejects_ssrf_prone_base_urls_without_logging_them(self):
        unsafe_urls = (
            "http://169.254.169.254/latest/meta-data",
            "https://10.0.0.5/v1",
            "http://example.com/v1",
            "https://user:pass@example.com/v1",
        )
        for unsafe_url in unsafe_urls:
            with self.subTest(unsafe_url=unsafe_url), tempfile.TemporaryDirectory() as tmp_dir:
                runtime_root = server.Path(tmp_dir)
                config_path = runtime_root / "deepseek_config.json"
                handler = object.__new__(server.Handler)
                with patch.object(server, "RUNTIME_ROOT", runtime_root), patch.object(server, "DEEPSEEK_CONFIG_PATH", config_path):
                    result = server.Handler.handle_post(
                        handler,
                        "/api/config/deepseek",
                        {
                            "api_key": "sk-test-123456",
                            "model": "deepseek-chat",
                            "base_url": unsafe_url,
                        },
                    )
                    saved = json.loads(config_path.read_text(encoding="utf-8"))
                    audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

            self.assertEqual(result["base_url"], "https://api.deepseek.com")
            self.assertEqual(saved["base_url"], "https://api.deepseek.com")
            self.assertNotIn(unsafe_url, json.dumps(saved, ensure_ascii=False))
            self.assertIn('"base_url_rejected": true', audit_rows[-1])
            self.assertNotIn(unsafe_url, audit_rows[-1])

    def test_admin_binding_update_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            bindings_path = runtime_root / "family_bindings.json"
            handler = object.__new__(server.Handler)
            patient_ref = server.PATIENTS[0]["masked_id"]
            with patch.object(server, "RUNTIME_ROOT", runtime_root), patch.object(server, "BINDINGS_PATH", bindings_path):
                result = server.Handler.handle_post(
                    handler,
                    "/api/admin/bindings",
                    {"account": "family", "patient_ref": patient_ref},
                )
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertTrue(result["ok"])
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "admin_binding_update")
        self.assertEqual(event["path"], "/api/admin/bindings")
        self.assertEqual(event["account"], "family")
        self.assertIn("patient_ref_hash", event)
        self.assertNotIn(patient_ref, audit_rows[-1])

    def test_admin_binding_rejects_unknown_patient_ref_and_audits_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            bindings_path = runtime_root / "family_bindings.json"
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root), patch.object(server, "BINDINGS_PATH", bindings_path):
                result = server.Handler.handle_post(
                    handler,
                    "/api/admin/bindings",
                    {"account": "family", "patient_ref": "MRN-raw-12345"},
                )
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertIsInstance(result, tuple)
        status, payload = result
        self.assertEqual(status, 422)
        self.assertEqual(payload["error"], "invalid_patient_ref")
        self.assertFalse(bindings_path.exists())
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/admin/bindings")
        self.assertIn("patient_ref", event["fields"])
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_binding_state_redacts_legacy_unknown_patient_refs(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            bindings_path = runtime_root / "family_bindings.json"
            server.write_json(
                bindings_path,
                [{"account": "family", "patient_ref": "MRN-raw-12345", "updated_at": "2026-06-03T00:00:00+08:00"}],
            )
            with patch.object(server, "BINDINGS_PATH", bindings_path):
                result = server.binding_state()

        encoded = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("MRN-raw-12345", encoded)
        self.assertEqual(result["bindings"][0]["patient_ref"], "")
        self.assertTrue(result["bindings"][0]["redacted_patient_ref"])
        self.assertIn("patient_ref_hash", result["bindings"][0])

    def test_sensitive_runtime_files_are_owner_only_after_writes(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            config_path = runtime_root / "deepseek_config.json"
            bindings_path = runtime_root / "family_bindings.json"
            audit_path = runtime_root / "security_audit.log"
            for path in (config_path, bindings_path, audit_path):
                path.write_text("{}\n", encoding="utf-8")
                path.chmod(0o666)

            handler = object.__new__(server.Handler)
            patient_ref = server.PATIENTS[0]["masked_id"]
            with patch.object(server, "RUNTIME_ROOT", runtime_root), patch.object(server, "DEEPSEEK_CONFIG_PATH", config_path), patch.object(server, "BINDINGS_PATH", bindings_path):
                server.Handler.handle_post(
                    handler,
                    "/api/config/deepseek",
                    {"api_key": "sk-test-123456", "model": "deepseek-chat"},
                )
                server.Handler.handle_post(
                    handler,
                    "/api/admin/bindings",
                    {"account": "family", "patient_ref": patient_ref},
                )

            self.assert_owner_only_file(config_path)
            self.assert_owner_only_file(bindings_path)
            self.assert_owner_only_file(audit_path)

    def test_model_predict_rejects_out_of_range_clinical_values_and_audits(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                try:
                    result = server.Handler.handle_post(
                        handler,
                        "/api/model/predict",
                        {"vitals": {"map": -10, "spo2": 140}, "labs": {"lactate": "not-a-number"}},
                    )
                except ValueError as exc:
                    self.fail(f"expected a 422 validation response instead of an exception: {exc}")
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertIsInstance(result, tuple)
        status, payload = result
        self.assertEqual(status, 422)
        self.assertEqual(payload["error"], "invalid_clinical_payload")
        self.assertIn("vitals.map", payload["fields"])
        self.assertIn("vitals.spo2", payload["fields"])
        self.assertIn("labs.lactate", payload["fields"])
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/model/predict")
        self.assertIn("vitals.map", event["fields"])
        self.assertNotIn("not-a-number", audit_rows[-1])

    def test_diagnose_batch_rejects_invalid_patient_values_and_audits(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                result = server.Handler.handle_post(
                    handler,
                    "/api/diagnose/batch",
                    {
                        "patients": [
                            {"vitals": {"map": 68}, "labs": {"lactate": 2.1}},
                            {"vitals": {"spo2": 140}},
                        ]
                    },
                )
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertIsInstance(result, tuple)
        status, payload = result
        self.assertEqual(status, 422)
        self.assertEqual(payload["error"], "invalid_clinical_payload")
        self.assertIn("patients[1].vitals.spo2", payload["fields"])
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/diagnose/batch")
        self.assertIn("patients[1].vitals.spo2", event["fields"])

    def test_family_and_ai_responses_redact_identifiers(self):
        handler = object.__new__(server.Handler)
        sensitive_text = "MRN: MRN-12345 email alice@example.com phone 555-123-4567 patient SC-12001 bed ICU-09"

        family = server.Handler.handle_post(handler, "/api/family/chat", {"question": sensitive_text})
        explain = server.Handler.handle_post(handler, "/api/ai/explain", {"term": sensitive_text})
        encoded = json.dumps({"family": family, "explain": explain}, ensure_ascii=False)

        for needle in ("MRN-12345", "alice@example.com", "555-123-4567", "SC-12001", "ICU-09"):
            self.assertNotIn(needle, encoded)
        self.assertIn("[redacted-mrn]", encoded)
        self.assertIn("[redacted-email]", encoded)
        self.assertIn("[redacted-phone]", encoded)
        self.assertIn("[redacted-patient-ref]", encoded)
        self.assertIn("[redacted-bed]", encoded)

    def test_monitor_report_rejects_unknown_patient_ref_and_audits_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                result = server.Handler.handle_get(handler, "/api/monitor/report/MRN-raw-12345", {})
                audit_path = runtime_root / "security_audit.log"
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_path.exists() else []

        self.assertIsInstance(result, tuple)
        status, payload = result
        self.assertEqual(status, 422)
        self.assertEqual(payload["error"], "invalid_patient_ref")
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/monitor/report")
        self.assertIn("patient_ref", event["fields"])
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_detail_path_refs_reject_unknown_identifiers_and_audit_without_raw_identifier(self):
        cases = [
            ("/api/patients/MRN-raw-12345", "/api/patients", "MRN-raw-12345"),
            ("/api/bedside/snapshot/ICU-raw-99", "/api/bedside/snapshot", "ICU-raw-99"),
            ("/api/history/patients/MRN-raw-12345", "/api/history/patients", "MRN-raw-12345"),
        ]
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                results = [
                    (path, audit_path, raw_ref, server.Handler.handle_get(handler, path, {}))
                    for path, audit_path, raw_ref in cases
                ]
                for path, _audit_path, _raw_ref, result in results:
                    self.assertIsInstance(result, tuple, path)
                    self.assertEqual(result[0], 422, path)
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        self.assertEqual(len(audit_rows), len(cases))
        for index, (path, audit_path, raw_ref, result) in enumerate(results):
            status, payload = result
            self.assertEqual(payload["error"], "invalid_patient_ref", path)
            self.assertNotIn(raw_ref, json.dumps(payload, ensure_ascii=False), path)
            event = json.loads(audit_rows[index])
            self.assertEqual(event["event"], "data_validation_failure", path)
            self.assertEqual(event["path"], audit_path, path)
            self.assertIn("patient_ref_hash", event, path)
            self.assertNotIn(raw_ref, audit_rows[index], path)

    def test_history_export_writes_privacy_preserving_audit_event(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                csv_text = server.Handler.handle_get(handler, "/api/history/export", {"scope": ["list"]})
                audit_path = runtime_root / "security_audit.log"
                audit_exists = audit_path.exists()
                audit_rows = audit_path.read_text(encoding="utf-8").splitlines() if audit_exists else []

        self.assertIsInstance(csv_text, str)
        self.assertIn("history_id,masked_id,data_source", csv_text)
        self.assertTrue(audit_exists)
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "history_export")
        self.assertEqual(event["path"], "/api/history/export")
        self.assertEqual(event["scope"], "list")
        self.assertGreater(event["row_count"], 0)

    def test_history_list_filters_by_search_and_source_alias(self):
        handler = object.__new__(server.Handler)

        by_search = server.Handler.handle_get(
            handler,
            "/api/history/patients",
            {"search": ["HX-700019"], "per_page": ["100"]},
        )
        by_alias = server.Handler.handle_get(
            handler,
            "/api/history/patients",
            {"query": ["HX-700019"], "per_page": ["100"]},
        )
        by_source_alias = server.Handler.handle_get(
            handler,
            "/api/history/patients",
            {"source": ["PhysioNet2012"], "per_page": ["100"]},
        )

        self.assertEqual(by_search["total"], 1)
        self.assertEqual(by_search["patients"][0]["masked_id"], "HX-700019")
        self.assertEqual(by_alias["total"], 1)
        self.assertEqual(by_alias["patients"][0]["history_id"], "HICU-700019")
        self.assertGreater(by_source_alias["total"], 0)
        self.assertTrue(all(row["data_source"] == "PhysioNet 2012" for row in by_source_alias["patients"]))

    def test_history_export_respects_current_filters(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                csv_text = server.Handler.handle_get(
                    handler,
                    "/api/history/export",
                    {"scope": ["list"], "search": ["HX-700019"], "per_page": ["100"]},
                )

        rows = [line for line in csv_text.splitlines() if line.strip()]
        self.assertEqual(len(rows), 2)
        self.assertIn("HX-700019", rows[1])
        self.assertNotIn("HX-700039", csv_text)

    def test_history_export_rejects_unknown_history_id_without_raw_identifier(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            handler = object.__new__(server.Handler)
            with patch.object(server, "RUNTIME_ROOT", runtime_root):
                result = server.Handler.handle_get(
                    handler,
                    "/api/history/export",
                    {"scope": ["detail"], "history_id": ["MRN-raw-12345"]},
                )
                self.assertIsInstance(result, tuple)
                self.assertEqual(result[0], 422)
                audit_rows = (runtime_root / "security_audit.log").read_text(encoding="utf-8").splitlines()

        status, payload = result
        self.assertEqual(payload["error"], "invalid_patient_ref")
        self.assertNotIn("MRN-raw-12345", json.dumps(payload, ensure_ascii=False))
        event = json.loads(audit_rows[-1])
        self.assertEqual(event["event"], "data_validation_failure")
        self.assertEqual(event["path"], "/api/history/export")
        self.assertIn("patient_ref_hash", event)
        self.assertNotIn("MRN-raw-12345", audit_rows[-1])

    def test_training_terminal_action_forwards_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                config = server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {
                        "mode": "production",
                        "cloud_base_url": "http://model.local:8788",
                        "params": {
                            "source": "macos",
                            "safe_mode": True,
                            "subject_id": "raw-subject",
                            "api_key": "sk-local-secret",
                        },
                    },
                )
                handler = object.__new__(server.Handler)
                cloud_payload = {
                    "ok": True,
                    "task_status": "idle",
                    "metrics": {"macro_f1": 0.956},
                    "output": ["cloud metrics returned"],
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        handler,
                        "/api/training-terminal/action",
                        {
                            "action": "stream_metrics",
                            "payload": {
                                "patient_ref": "MRN-raw-12345",
                                "token": "service-token",
                                "note": "call 555-123-4567 about ICU-99",
                                "vitals": {"map": 72},
                            },
                        },
                    )

                request = urlopen.call_args.args[0]
                forwarded = json.loads(request.data.decode("utf-8"))
                serialized_config = json.dumps(config, ensure_ascii=False)
                serialized_forwarded = json.dumps(forwarded, ensure_ascii=False)
                self.assertEqual(request.full_url, "http://model.local:8788/api/training/command")
                self.assertEqual(forwarded["action"], "stream_metrics")
                self.assertEqual(config["status"]["params"], {"source": "macos", "safe_mode": True})
                self.assertEqual(forwarded["params"], {"source": "macos", "safe_mode": True})
                for raw in ("raw-subject", "sk-local-secret", "MRN-raw-12345", "service-token", "555-123-4567", "ICU-99"):
                    self.assertNotIn(raw, serialized_config)
                    self.assertNotIn(raw, serialized_forwarded)
                self.assertTrue(result["ok"])
                self.assertEqual(result["cloud_response"], cloud_payload)
                self.assertIn("已转发至云端模型服务", result["output"][0])
                self.assertEqual(result["status"]["metrics"]["macro_f1"], 0.956)

    def test_training_terminal_forwarding_uses_service_token_fallback(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with (
                patch.object(server, "TRAINING_STATE_PATH", state_path),
                patch.object(server, "TRAINING_LOG_PATH", log_path),
                patch.dict(
                    server.os.environ,
                    {"SEPSISCARE_TRAINING_TOKEN": "", "SEPSISCARE_SERVICE_TOKEN": STRONG_TEST_TOKEN},
                    clear=False,
                ),
            ):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {"ok": True, "task_status": "idle", "output": ["cloud metrics returned"]}

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/training-terminal/action",
                        {"action": "stream_metrics"},
                    )

                request = urlopen.call_args.args[0]

        self.assertTrue(result["ok"])
        self.assertEqual(request.get_header("Authorization"), f"Bearer {STRONG_TEST_TOKEN}")

    def test_training_terminal_forwarding_uses_private_service_token_file(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            token_path = server.Path(tmp_dir) / "sepsiscare_service_token.txt"
            token_path.write_text(STRONG_TEST_TOKEN, encoding="utf-8")
            with (
                patch.object(server, "TRAINING_STATE_PATH", state_path),
                patch.object(server, "TRAINING_LOG_PATH", log_path),
                patch.dict(
                    server.os.environ,
                    {
                        "SEPSISCARE_TRAINING_TOKEN": "",
                        "SEPSISCARE_SERVICE_TOKEN": "",
                        "SEPSISCARE_SERVICE_TOKEN_FILE": str(token_path),
                    },
                    clear=False,
                ),
            ):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {"ok": True, "task_status": "idle", "output": ["cloud metrics returned"]}

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/training-terminal/action",
                        {"action": "stream_metrics"},
                    )

                request = urlopen.call_args.args[0]

        self.assertTrue(result["ok"])
        self.assertEqual(request.get_header("Authorization"), f"Bearer {STRONG_TEST_TOKEN}")

    def test_family_chat_forwards_patient_context_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {
                    "answer": "远程模型结合 SC-12000 当前乳酸与 MAP 给出解释。",
                    "source": "remote-windows-model-server",
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/family/chat",
                        {"patient_ref": "SC-12000", "question": "乳酸升高是什么意思？"},
                    )

                request = urlopen.call_args.args[0]
                forwarded = json.loads(request.data.decode("utf-8"))

        self.assertEqual(request.full_url, "http://model.local:8788/api/family/chat")
        self.assertEqual(forwarded["question"], "乳酸升高是什么意思？")
        self.assertEqual(forwarded["patient_ref"], "SC-12000")
        self.assertIn("patient", forwarded["context"])
        self.assertIn("prediction", forwarded["context"])
        self.assertIn("training_status", forwarded["context"])
        self.assertEqual(result["answer"], cloud_payload["answer"])
        self.assertEqual(result["source"], "remote-windows-model-server")

    def test_ai_assistant_chat_forwards_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {
                    "answer": "远程研究助手返回了训练状态和风险看板解释。",
                    "source": "remote-windows-model-server",
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/ai/assistant-chat",
                        {"question": "训练终端为什么没有拉到真实指标？"},
                    )

                request = urlopen.call_args.args[0]
                forwarded = json.loads(request.data.decode("utf-8"))

        self.assertEqual(request.full_url, "http://model.local:8788/api/ai/assistant-chat")
        self.assertEqual(forwarded["question"], "训练终端为什么没有拉到真实指标？")
        self.assertIn("training_status", forwarded["context"])
        self.assertIn("model", forwarded["context"])
        self.assertEqual(result["answer"], cloud_payload["answer"])
        self.assertEqual(result["source"], "remote-windows-model-server")

    def test_ai_analysis_forwards_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {
                    "ok": True,
                    "summary": "远端模型返回 macro_f1 和当前 ICU 队列分析。",
                    "source": "remote-windows-model-server",
                    "metrics": {"macro_f1": 0.986231},
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_get(object.__new__(server.Handler), "/api/ai/analysis", {})

                request = urlopen.call_args.args[0]

        self.assertEqual(request.full_url, "http://model.local:8788/api/ai/analysis")
        self.assertEqual(request.get_method(), "GET")
        self.assertEqual(result["summary"], cloud_payload["summary"])
        self.assertEqual(result["source"], "remote-windows-model-server")
        self.assertEqual(result["metrics"]["macro_f1"], 0.986231)

    def test_ai_analysis_uses_assistant_chat_when_remote_analysis_is_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                placeholder_payload = {
                    "ok": True,
                    "summary": "远程 Windows 模型服务在线，当前返回部署模型指标和内置患者数据库分析。",
                    "model_id": "s7_phenotype_contrastive_full_20260516",
                }
                deepseek_payload = {
                    "answer": "DeepSeek 已基于 ICU 队列、训练状态和模型指标完成真实分析。",
                    "source": "deepseek",
                    "model": "deepseek-chat",
                }

                with patch.object(
                    server.urllib_request,
                    "urlopen",
                    side_effect=[MockCloudResponse(placeholder_payload), MockCloudResponse(deepseek_payload)],
                ) as urlopen:
                    result = server.Handler.handle_get(object.__new__(server.Handler), "/api/ai/analysis", {})

                self.assertEqual(len(urlopen.call_args_list), 2)
                analysis_request = urlopen.call_args_list[0].args[0]
                chat_request = urlopen.call_args_list[1].args[0]
                forwarded = json.loads(chat_request.data.decode("utf-8"))

        self.assertEqual(analysis_request.full_url, "http://model.local:8788/api/ai/analysis")
        self.assertEqual(chat_request.full_url, "http://model.local:8788/api/ai/assistant-chat")
        self.assertIn("ICU", forwarded["question"])
        self.assertIn("training_status", forwarded["context"])
        self.assertIn("model", forwarded["context"])
        self.assertIn("metrics", forwarded["context"])
        self.assertEqual(result["summary"], deepseek_payload["answer"])
        self.assertEqual(result["source"], "deepseek")
        self.assertEqual(result["model"], "deepseek-chat")

    def test_default_rog_ai_analysis_uses_assistant_chat_when_remote_analysis_is_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                placeholder_payload = {
                    "ok": True,
                    "summary": "远程 Windows 模型服务在线，当前返回部署模型指标和内置患者数据库分析。",
                    "model_id": "s7_phenotype_contrastive_full_20260516",
                }
                deepseek_payload = {
                    "answer": "DeepSeek 已通过默认 ROG 地址返回真实分析。",
                    "source": "deepseek",
                    "model": "deepseek-chat",
                }

                with patch.object(
                    server.urllib_request,
                    "urlopen",
                    side_effect=[MockCloudResponse(placeholder_payload), MockCloudResponse(deepseek_payload)],
                ) as urlopen:
                    result = server.Handler.handle_get(object.__new__(server.Handler), "/api/ai/analysis", {})

                analysis_request = urlopen.call_args_list[0].args[0]
                chat_request = urlopen.call_args_list[1].args[0]

        self.assertEqual(analysis_request.full_url, "http://100.65.136.96:8788/api/ai/analysis")
        self.assertEqual(chat_request.full_url, "http://100.65.136.96:8788/api/ai/assistant-chat")
        self.assertEqual(result["summary"], deepseek_payload["answer"])
        self.assertEqual(result["source"], "deepseek")

    def test_ai_llm_diagnose_forwards_patient_payload_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {
                    "ok": True,
                    "summary": "远端 LLM 已基于乳酸、MAP 和风险轨迹生成诊断摘要。",
                    "source": "remote-windows-model-server",
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/ai/llm-diagnose",
                        {"masked_id": "SC-12000", "lactate": 1.2, "mean_arterial_pressure": 87.3},
                    )

                request = urlopen.call_args.args[0]
                forwarded = json.loads(request.data.decode("utf-8"))

        self.assertEqual(request.full_url, "http://model.local:8788/api/ai/llm-diagnose")
        self.assertEqual(forwarded["masked_id"], "SC-12000")
        self.assertIn("training_status", forwarded["context"])
        self.assertEqual(result["summary"], cloud_payload["summary"])
        self.assertEqual(result["source"], "remote-windows-model-server")

    def test_ai_explain_forwards_term_context_to_configured_model_service(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                server.Handler.handle_post(
                    object.__new__(server.Handler),
                    "/api/training-terminal/config",
                    {"mode": "production", "cloud_base_url": "http://model.local:8788"},
                )
                cloud_payload = {
                    "term": "SOFA评分",
                    "explanation": "远端 LLM 结合 ICU 风险解释返回 SOFA 术语说明。",
                    "source": "remote-windows-model-server",
                }

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse(cloud_payload)) as urlopen:
                    result = server.Handler.handle_post(
                        object.__new__(server.Handler),
                        "/api/ai/explain",
                        {"term": "SOFA评分", "context": "脓毒症器官功能评估"},
                    )

                request = urlopen.call_args.args[0]
                forwarded = json.loads(request.data.decode("utf-8"))

        self.assertEqual(request.full_url, "http://model.local:8788/api/ai/explain")
        self.assertEqual(forwarded["term"], "SOFA评分")
        self.assertIn("training_status", forwarded["context"])
        self.assertEqual(result["explanation"], cloud_payload["explanation"])
        self.assertEqual(result["source"], "remote-windows-model-server")

    def test_training_terminal_rejects_ssrf_prone_cloud_base_url_without_logging_it(self):
        unsafe_urls = (
            "http://169.254.169.254/latest/meta-data",
            "http://[fe80::1]/v1",
            "https://user:pass@example.com/v1",
            "file:///etc/passwd",
        )
        for unsafe_url in unsafe_urls:
            with self.subTest(unsafe_url=unsafe_url), tempfile.TemporaryDirectory() as tmp_dir:
                state_path = server.Path(tmp_dir) / "training_state.json"
                log_path = server.Path(tmp_dir) / "training_terminal.log"
                handler = object.__new__(server.Handler)
                with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                    config = server.Handler.handle_post(
                        handler,
                        "/api/training-terminal/config",
                        {"mode": "production", "cloud_base_url": unsafe_url},
                    )
                    result = server.Handler.handle_post(handler, "/api/training-terminal/action", {"action": "stream_metrics"})
                    log_text = log_path.read_text(encoding="utf-8") if log_path.exists() else ""

            self.assertFalse(config["ok"])
            self.assertEqual(config["error"], "cloud_base_url_rejected")
            self.assertEqual(result["error"], "cloud_base_url_not_configured")
            self.assertNotIn(unsafe_url, json.dumps(config, ensure_ascii=False))
            self.assertNotIn(unsafe_url, json.dumps(result, ensure_ascii=False))
            self.assertNotIn(unsafe_url, log_text)

    def test_training_terminal_config_returns_swift_decodable_status_shape(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            state_path = server.Path(tmp_dir) / "training_state.json"
            log_path = server.Path(tmp_dir) / "training_terminal.log"
            handler = object.__new__(server.Handler)
            with patch.object(server, "TRAINING_STATE_PATH", state_path), patch.object(server, "TRAINING_LOG_PATH", log_path):
                result = server.Handler.handle_post(
                    handler,
                    "/api/training-terminal/config",
                    {
                        "mode": "production",
                        "cloud_base_url": "http://model.local:8788",
                        "params": {"source": "macos", "safe_mode": True},
                    },
                )

        for key in (
            "ok",
            "version",
            "mode",
            "mode_label",
            "model_profile",
            "task_status",
            "cloud_base_url",
            "cloud_ready",
            "last_action",
            "updated_at",
            "params",
            "metrics",
            "artifacts",
            "actions",
            "notice",
        ):
            self.assertIn(key, result)
        self.assertTrue(result["ok"])
        self.assertEqual(result["cloud_base_url"], "http://model.local:8788")
        self.assertEqual(result["params"], {"source": "macos", "safe_mode": True})

    def test_icu_realtime_ingest_records_timeseries_and_uploads_to_cloud(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            runtime_root = server.Path(tmp_dir)
            timeseries_path = runtime_root / "icu_timeseries.jsonl"
            upload_state_path = runtime_root / "icu_upload_state.json"
            handler = object.__new__(server.Handler)
            payload = {
                "source": "hospital-icu-monitor",
                "events": [
                    {
                        "patient_ref": "MRN-raw-12345",
                        "bed_no": "ICU-09",
                        "timestamp": "2026-06-04T14:00:00+08:00",
                        "vitals": {"heart_rate": 112, "map": 64, "resp_rate": 26, "spo2": 92, "temperature": 38.4},
                        "labs": {"lactate": 3.4, "wbc": 16.2},
                        "device": {"vendor": "bedside-monitor", "serial": "RAW-SERIAL-001"},
                    },
                    {
                        "patient_ref": "MRN-raw-12345",
                        "bed_no": "ICU-09",
                        "timestamp": "2026-06-04T14:01:00+08:00",
                        "vitals": {"heart_rate": 114, "map": 62, "resp_rate": 27, "spo2": 91, "temperature": 38.5},
                        "labs": {"lactate": 3.5, "wbc": 16.3},
                    },
                ],
            }
            with (
                patch.object(server, "RUNTIME_ROOT", runtime_root),
                patch.object(server, "ICU_TIMESERIES_PATH", timeseries_path, create=True),
                patch.object(server, "ICU_UPLOAD_STATE_PATH", upload_state_path, create=True),
            ):
                ingest = server.Handler.handle_post(handler, "/api/icu/realtime/ingest", payload)

                with patch.object(server.urllib_request, "urlopen", return_value=MockCloudResponse({"ok": True, "accepted": 2, "training_ready": True})) as urlopen:
                    upload = server.Handler.handle_post(
                        handler,
                        "/api/icu/realtime/upload",
                        {"cloud_base_url": "http://model.local:8788", "limit": 10},
                    )
                    request = urlopen.call_args.args[0]
                    forwarded = json.loads(request.data.decode("utf-8"))
                rows = [json.loads(line) for line in timeseries_path.read_text(encoding="utf-8").splitlines()]
                upload_state_exists = upload_state_path.exists()

        self.assertIsInstance(ingest, dict)
        self.assertTrue(ingest["ok"])
        self.assertEqual(ingest["accepted"], 2)
        self.assertEqual(ingest["storage"], "managed-runtime/icu_timeseries.jsonl")
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["vitals"]["map"], 64.0)
        self.assertIn("patient_key", rows[0])
        serialized_rows = json.dumps(rows, ensure_ascii=False)
        for raw in ("MRN-raw-12345", "RAW-SERIAL-001", "ICU-09"):
            self.assertNotIn(raw, serialized_rows)

        self.assertEqual(request.full_url, "http://model.local:8788/api/icu/timeseries/ingest")
        self.assertEqual(len(forwarded["events"]), 2)
        self.assertTrue(upload["ok"])
        self.assertEqual(upload["cloud_response"]["accepted"], 2)
        self.assertTrue(upload_state_exists)


if __name__ == "__main__":
    unittest.main()
