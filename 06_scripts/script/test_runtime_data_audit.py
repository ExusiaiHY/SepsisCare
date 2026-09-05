#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "audit_runtime_data.py"
SPEC = importlib.util.spec_from_file_location("sepsiscare_runtime_data_audit_under_test", MODULE_PATH)
audit_runtime_data = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(audit_runtime_data)


class RuntimeDataAuditTests(unittest.TestCase):
    def write_runtime_data(self, root, patients, details):
        root.mkdir(parents=True, exist_ok=True)
        (root / "history_patients.json").write_text(json.dumps(patients), encoding="utf-8")
        (root / "history_details.json").write_text(json.dumps(details), encoding="utf-8")

    def test_accepts_clean_minimal_runtime_data(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self.write_runtime_data(
                root,
                [
                    {
                        "history_id": "HX-1",
                        "masked_id": "HX-1",
                        "data_source": "MIMIC-IV",
                        "quality_tag": "真实脱敏",
                        "annotation_status": "真实脱敏",
                        "_detail_profile": {"heart_rate": 90, "map": 70, "spo2": 96, "lactate": 2.1},
                    }
                ],
                {"HX-1": [{"minute": 0, "heart_rate": 91, "map": 72, "spo2": 95, "lactate": 2.0}]},
            )

            report = audit_runtime_data.audit_runtime_data(root)

        self.assertTrue(report["ok"])
        self.assertEqual(report["summary"]["patients"], 1)
        self.assertEqual(report["summary"]["detail_series"], 1)
        self.assertEqual(report["violations"], [])

    def test_flags_pollution_sensitive_fields_duplicates_outliers_and_orphan_details(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self.write_runtime_data(
                root,
                [
                    {
                        "history_id": "HX-1",
                        "masked_id": "HX-1",
                        "data_source": "MIMIC-IV",
                        "quality_tag": "真实脱敏",
                        "annotation_status": "真实脱敏",
                        "_detail_profile": {"heart_rate": 90, "map": 70, "spo2": 96},
                    },
                    {
                        "history_id": "HX-1",
                        "masked_id": "HX-2",
                        "quality_tag": "",
                        "annotation_status": "",
                        "mrn": "MRN-12345",
                        "free_text": "contact alice@example.com",
                        "_detail_profile": {"heart_rate": 999, "spo2": 140},
                    },
                ],
                {
                    "HX-1": [{"minute": 0, "heart_rate": 91, "note": "phone 555-123-4567"}],
                    "HX-ORPHAN": [{"minute": 0, "map": -5}],
                },
            )

            report = audit_runtime_data.audit_runtime_data(root)

        self.assertFalse(report["ok"])
        categories = {item["category"] for item in report["violations"]}
        self.assertIn("missing_provenance", categories)
        self.assertIn("duplicate_identifier", categories)
        self.assertIn("sensitive_field", categories)
        self.assertIn("sensitive_text", categories)
        self.assertIn("clinical_outlier", categories)
        self.assertIn("orphan_detail_series", categories)
        encoded = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("MRN-12345", encoded)
        self.assertNotIn("alice@example.com", encoded)
        self.assertNotIn("555-123-4567", encoded)


if __name__ == "__main__":
    unittest.main()
