#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "audit_sensitive_data.py"
SPEC = importlib.util.spec_from_file_location("sepsiscare_sensitive_data_audit_under_test", MODULE_PATH)
audit_sensitive_data = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(audit_sensitive_data)


class SensitiveDataAuditTests(unittest.TestCase):
    def test_clean_release_files_pass_and_test_fixtures_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "deploy").mkdir()
            (root / "deploy" / "model_service.py").write_text(
                'headers["Authorization"] = f"Bearer {os.getenv(\'SEPSISCARE_SERVICE_TOKEN\')}"\n',
                encoding="utf-8",
            )
            (root / "deploy" / "test_model_service.py").write_text(
                'api_key = "sk-test-12345678901234567890"\npatient = "MRN-12345"\n',
                encoding="utf-8",
            )
            (root / "README_DEPLOY.md").write_text(
                "Use SEPSISCARE_SERVICE_TOKEN from the environment.\n",
                encoding="utf-8",
            )

            report = audit_sensitive_data.audit_sensitive_data(root)

        self.assertTrue(report["ok"])
        self.assertEqual(report["findings"], [])

    def test_empty_secret_assignments_do_not_match_next_line(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / ".env.example").write_text(
                "DEEPSEEK_API_KEY=\nDEEPSEEK_MODEL=deepseek-chat\nSEPSISCARE_TRAINING_TOKEN=\nSEPSISCARE_TRAINING_TIMEOUT_SECONDS=20\n",
                encoding="utf-8",
            )

            report = audit_sensitive_data.audit_sensitive_data(root)

        self.assertTrue(report["ok"])
        self.assertEqual(report["findings"], [])

    def test_flags_hardcoded_secrets_in_readme_files_without_phi_scanning(self):
        secret = "sk-live-readme123456789012345678901234"
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "README_DEPLOY.md").write_text(
                f"Temporary setup:\nDEEPSEEK_API_KEY={secret}\nContact patient.family@example.com for demo notes.\n",
                encoding="utf-8",
            )

            report = audit_sensitive_data.audit_sensitive_data(root)

        self.assertFalse(report["ok"])
        self.assertEqual(len(report["findings"]), 1)
        finding = report["findings"][0]
        self.assertEqual(finding["category"], "hardcoded_secret")
        self.assertEqual(finding["file"], "README_DEPLOY.md")
        self.assertNotIn(secret, json.dumps(report))

    def test_flags_secrets_and_phi_without_echoing_raw_values(self):
        secret = "sk-live-123456789012345678901234567890"
        mrn = "MRN-998877"
        email = "patient.family@example.com"
        phone = "555-222-1234"
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "deploy").mkdir()
            (root / "deploy" / "model_service.py").write_text(
                f'DEEPSEEK_API_KEY = "{secret}"\n',
                encoding="utf-8",
            )
            (root / "config").mkdir()
            (root / "config" / "patient-note.txt").write_text(
                f"{mrn} contact {email} phone {phone}\n",
                encoding="utf-8",
            )

            report = audit_sensitive_data.audit_sensitive_data(root)

        self.assertFalse(report["ok"])
        categories = {finding["category"] for finding in report["findings"]}
        self.assertIn("hardcoded_secret", categories)
        self.assertIn("sensitive_text", categories)
        encoded = json.dumps(report, ensure_ascii=False)
        self.assertNotIn(secret, encoded)
        self.assertNotIn(mrn, encoded)
        self.assertNotIn(email, encoded)
        self.assertNotIn(phone, encoded)
        for finding in report["findings"]:
            self.assertRegex(finding["evidence_hash"], r"^[0-9a-f]{12}$")

    def test_cli_exits_nonzero_for_findings(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            (root / "config.env").write_text(
                "DEEPSEEK_API_KEY=sk-live-123456789012345678901234567890\n",
                encoding="utf-8",
            )

            proc = subprocess.run(
                [sys.executable, str(MODULE_PATH), str(root)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(proc.returncode, 1)
        self.assertIn('"ok": false', proc.stdout)

    def test_audits_multiple_roots_and_reports_read_errors(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace = Path(tmp_dir)
            package_root = workspace / "02_model_deploy_package"
            backend_root = workspace / "apps" / "sepsiscare-studio" / "backend"
            package_root.mkdir(parents=True)
            backend_root.mkdir(parents=True)
            (package_root / "deploy.py").write_text("print('clean')\n", encoding="utf-8")
            (backend_root / "config.env").write_text(
                "OPENAI_API_KEY=sk-live-abcdefghijklmnopqrstuvwxyz123456\n",
                encoding="utf-8",
            )
            missing_root = workspace / "apps" / "missing-client"

            report = audit_sensitive_data.audit_sensitive_data([package_root, backend_root, missing_root])

        self.assertFalse(report["ok"])
        self.assertEqual(len(report["roots"]), 3)
        categories = {finding["category"] for finding in report["findings"]}
        self.assertIn("hardcoded_secret", categories)
        self.assertIn("read_error", categories)
        for finding in report["findings"]:
            self.assertIn("root", finding)
            self.assertNotIn("sk-live-abcdefghijklmnopqrstuvwxyz123456", json.dumps(finding))

    def test_cli_accepts_multiple_roots(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace = Path(tmp_dir)
            first = workspace / "first"
            second = workspace / "second"
            first.mkdir()
            second.mkdir()
            (first / "app.py").write_text("print('ok')\n", encoding="utf-8")
            (second / "app.py").write_text("print('ok')\n", encoding="utf-8")

            proc = subprocess.run(
                [sys.executable, str(MODULE_PATH), str(first), str(second)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(proc.returncode, 0)
        report = json.loads(proc.stdout)
        self.assertEqual(len(report["roots"]), 2)


if __name__ == "__main__":
    unittest.main()
