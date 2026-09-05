#!/usr/bin/env python3
import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "audit_training_data_integrity.py"
SPEC = importlib.util.spec_from_file_location("sepsiscare_training_data_integrity_audit_under_test", MODULE_PATH)
audit_training_data_integrity = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(audit_training_data_integrity)


class TrainingDataIntegrityAuditTests(unittest.TestCase):
    def write_package(self, root: Path, *, summary: dict, strategy_rows: list[dict[str, object]]) -> Path:
        package = root / "02_model_deploy_package"
        model_dir = package / "models" / "cloud_production" / "s7_phenotype_contrastive_full_20260516"
        report_dir = package / "reports" / "s7_phenotype_contrastive_full_20260516"
        config_dir = package / "config"
        model_dir.mkdir(parents=True)
        report_dir.mkdir(parents=True)
        config_dir.mkdir(parents=True)
        (model_dir / "s7_all_source_training_summary.json").write_text(json.dumps(summary), encoding="utf-8")
        (config_dir / "s7_phenotype_contrastive_full_20260516.yaml").write_text(
            "main_source: physionet2012\nsources:\n- name: physionet2012\n  role: train\n",
            encoding="utf-8",
        )
        with (report_dir / "phenotype_strategy_summary.csv").open("w", newline="", encoding="utf-8") as handle:
            fieldnames = [
                "run_id",
                "split_type",
                "n_patients_eval",
                "total_train_patients",
                "macro_f1",
                "mortality_auroc",
                "remaining_los_mae_hours",
            ]
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            for row in strategy_rows:
                writer.writerow(row)
        return package

    def clean_summary(self) -> dict:
        return {
            "stage": "s7_all_source_training",
            "generated_at": "2026-05-16T22:20:14",
            "intent": "Use every configured cohort as training data. Monitoring splits intentionally overlap train and must not be interpreted as held-out validation.",
            "main_source": "physionet2012",
            "total_train_patients": 106444,
            "split_policy": {
                "train": "all patients per source",
                "val": "same patients as train for early-stopping/monitoring compatibility",
                "test": "same patients as train for in-sample monitoring compatibility",
                "heldout_external_validation": False,
            },
            "sources": {
                "physionet2012": {
                    "role": "train",
                    "split_sizes": {"train": 11986, "val": 11986, "test": 11986},
                    "split_policy": "full_overlap_all_patients",
                    "heldout": False,
                },
                "mimiciv": {
                    "role": "train",
                    "split_sizes": {"train": 94458, "val": 94458, "test": 94458},
                    "split_policy": "full_overlap_all_patients",
                    "heldout": False,
                },
            },
        }

    def clean_strategy_rows(self) -> list[dict[str, object]]:
        return [
            {
                "run_id": "s7_phenotype_contrastive_full_20260516",
                "split_type": "in-sample monitoring",
                "n_patients_eval": 11986,
                "total_train_patients": 106444,
                "macro_f1": 0.956,
                "mortality_auroc": 0.848,
                "remaining_los_mae_hours": 2.95,
            }
        ]

    def test_accepts_clean_training_metadata(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            package = self.write_package(
                Path(tmp_dir),
                summary=self.clean_summary(),
                strategy_rows=self.clean_strategy_rows(),
            )

            report = audit_training_data_integrity.audit_training_data_integrity(package)

        self.assertTrue(report["ok"])
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["summary"]["sources"], 2)

    def test_flags_provenance_split_and_metric_pollution(self):
        summary = self.clean_summary()
        summary["intent"] = "held-out validation achieved"
        summary["split_policy"]["heldout_external_validation"] = True
        summary["total_train_patients"] = 100
        summary["sources"]["physionet2012"]["heldout"] = True
        summary["sources"]["physionet2012"]["split_policy"] = "random_holdout"
        summary["sources"]["physionet2012"]["split_sizes"] = {"train": 80, "val": 20, "test": 20}
        summary["sources"]["mimiciv"]["role"] = ""
        with tempfile.TemporaryDirectory() as tmp_dir:
            package = self.write_package(
                Path(tmp_dir),
                summary=summary,
                strategy_rows=[
                    {
                        "run_id": "s7_phenotype_contrastive_full_20260516",
                        "split_type": "held-out test",
                        "n_patients_eval": 999999,
                        "total_train_patients": 101,
                        "macro_f1": 1.2,
                        "mortality_auroc": -0.1,
                        "remaining_los_mae_hours": -5,
                    }
                ],
            )

            report = audit_training_data_integrity.audit_training_data_integrity(package)

        self.assertFalse(report["ok"])
        categories = {item["category"] for item in report["violations"]}
        self.assertIn("split_policy_mismatch", categories)
        self.assertIn("missing_source_provenance", categories)
        self.assertIn("training_total_mismatch", categories)
        self.assertIn("metric_out_of_range", categories)
        self.assertIn("monitoring_split_mislabel", categories)

    def test_flags_missing_target_run(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            package = self.write_package(
                Path(tmp_dir),
                summary=self.clean_summary(),
                strategy_rows=[
                    {
                        "run_id": "other",
                        "split_type": "in-sample monitoring",
                        "n_patients_eval": 10,
                        "total_train_patients": 10,
                        "macro_f1": 0.5,
                        "mortality_auroc": 0.5,
                        "remaining_los_mae_hours": 1,
                    }
                ],
            )

            report = audit_training_data_integrity.audit_training_data_integrity(package)

        self.assertFalse(report["ok"])
        self.assertIn("missing_target_run", {item["category"] for item in report["violations"]})


if __name__ == "__main__":
    unittest.main()
