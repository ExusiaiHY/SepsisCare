#!/usr/bin/env python3
"""Audit SepsisCare training metadata for provenance and pollution signals."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any


SUMMARY_PATH = Path("models/cloud_production/s7_phenotype_contrastive_full_20260516/s7_all_source_training_summary.json")
STRATEGY_SUMMARY_PATH = Path("reports/s7_phenotype_contrastive_full_20260516/phenotype_strategy_summary.csv")
TARGET_RUN_ID = "s7_phenotype_contrastive_full_20260516"
REQUIRED_SOURCE_FIELDS = ("role", "split_sizes", "split_policy", "heldout")
PROBABILITY_METRICS = (
    "macro_f1",
    "window_match_rate",
    "full_patient_match_rate",
    "zero_match_patient_rate",
    "encoder_macro_f1",
    "mortality_auroc",
    "sepsis_auroc",
    "next_mv_auroc",
    "next_rrt_auroc",
)
NON_NEGATIVE_METRICS = ("remaining_los_mae_hours", "n_patients_eval", "total_train_patients")


def add_violation(violations: list[dict[str, Any]], category: str, location: str, **fields: Any) -> None:
    payload = {"category": category, "location": location}
    payload.update({key: value for key, value in fields.items() if value not in (None, "")})
    violations.append(payload)


def read_json(path: Path, violations: list[dict[str, Any]]) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        add_violation(violations, "read_error", str(path), detail=str(exc))
    except json.JSONDecodeError as exc:
        add_violation(violations, "invalid_json", str(path), detail=str(exc))
    return None


def read_csv(path: Path, violations: list[dict[str, Any]]) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            return list(csv.DictReader(handle))
    except OSError as exc:
        add_violation(violations, "read_error", str(path), detail=str(exc))
    except csv.Error as exc:
        add_violation(violations, "invalid_csv", str(path), detail=str(exc))
    return []


def as_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def audit_summary(summary: Any, violations: list[dict[str, Any]]) -> tuple[int, int]:
    if not isinstance(summary, dict):
        add_violation(violations, "invalid_schema", str(SUMMARY_PATH), expected="object")
        return 0, 0
    sources = summary.get("sources")
    if not isinstance(sources, dict) or not sources:
        add_violation(violations, "missing_source_provenance", "summary.sources", reason="missing_or_empty")
        return 0, int(as_float(summary.get("total_train_patients")) or 0)
    source_count = len(sources)
    total_from_sources = 0
    seen_names: set[str] = set()
    for name, source in sources.items():
        location = f"summary.sources.{name}"
        if name in seen_names:
            add_violation(violations, "duplicate_source", location)
        seen_names.add(str(name))
        if not isinstance(source, dict):
            add_violation(violations, "missing_source_provenance", location, reason="not_object")
            continue
        missing = [field for field in REQUIRED_SOURCE_FIELDS if field not in source or source.get(field) in (None, "")]
        if missing:
            add_violation(violations, "missing_source_provenance", location, fields=missing)
        split_sizes = source.get("split_sizes")
        if not isinstance(split_sizes, dict):
            add_violation(violations, "split_policy_mismatch", location, reason="missing_split_sizes")
            continue
        train_size = as_float(split_sizes.get("train"))
        val_size = as_float(split_sizes.get("val"))
        test_size = as_float(split_sizes.get("test"))
        if train_size is not None:
            total_from_sources += int(train_size)
        if source.get("split_policy") == "full_overlap_all_patients":
            if train_size != val_size or train_size != test_size:
                add_violation(violations, "split_policy_mismatch", location, reason="full_overlap_sizes_differ")
            if source.get("heldout") is not False:
                add_violation(violations, "split_policy_mismatch", location, reason="full_overlap_marked_heldout")
        elif source.get("heldout") is False:
            add_violation(violations, "split_policy_mismatch", location, reason="non_overlap_policy_without_heldout")
    declared_total = int(as_float(summary.get("total_train_patients")) or 0)
    if declared_total and total_from_sources and declared_total != total_from_sources:
        add_violation(
            violations,
            "training_total_mismatch",
            "summary.total_train_patients",
            declared_total=declared_total,
            source_total=total_from_sources,
        )
    split_policy = summary.get("split_policy") if isinstance(summary.get("split_policy"), dict) else {}
    if split_policy.get("heldout_external_validation") is not False:
        add_violation(violations, "split_policy_mismatch", "summary.split_policy.heldout_external_validation", reason="heldout_claim_conflicts_with_all_train_package")
    intent = str(summary.get("intent") or "").lower()
    negates_heldout = "must not" in intent or "not be interpreted" in intent or "not held" in intent
    if ("held-out" in intent or "heldout" in intent) and not negates_heldout:
        add_violation(violations, "monitoring_split_mislabel", "summary.intent", reason="intent_claims_heldout")
    return source_count, declared_total


def audit_strategy_rows(rows: list[dict[str, str]], declared_total: int, violations: list[dict[str, Any]]) -> int:
    target_rows = [row for row in rows if row.get("run_id") == TARGET_RUN_ID]
    if not target_rows:
        add_violation(violations, "missing_target_run", str(STRATEGY_SUMMARY_PATH), run_id=TARGET_RUN_ID)
        return 0
    for index, row in enumerate(target_rows):
        location = f"{STRATEGY_SUMMARY_PATH}[run_id={TARGET_RUN_ID}][{index}]"
        split_type = str(row.get("split_type") or "").lower()
        if "held-out" in split_type or "heldout" in split_type:
            add_violation(violations, "monitoring_split_mislabel", f"{location}.split_type", split_type=row.get("split_type"))
        row_total = as_float(row.get("total_train_patients"))
        if declared_total and row_total is not None and int(row_total) != declared_total:
            add_violation(violations, "training_total_mismatch", f"{location}.total_train_patients", declared_total=declared_total, row_total=int(row_total))
        eval_count = as_float(row.get("n_patients_eval"))
        if declared_total and eval_count is not None and eval_count > declared_total:
            add_violation(violations, "metric_out_of_range", f"{location}.n_patients_eval", value=eval_count, maximum=declared_total)
        for field in PROBABILITY_METRICS:
            value = as_float(row.get(field))
            if value is not None and not 0.0 <= value <= 1.0:
                add_violation(violations, "metric_out_of_range", f"{location}.{field}", value=value, minimum=0.0, maximum=1.0)
        for field in NON_NEGATIVE_METRICS:
            value = as_float(row.get(field))
            if value is not None and value < 0:
                add_violation(violations, "metric_out_of_range", f"{location}.{field}", value=value, minimum=0.0)
    return len(target_rows)


def audit_training_data_integrity(package_dir: str | Path) -> dict[str, Any]:
    root = Path(package_dir)
    violations: list[dict[str, Any]] = []
    summary = read_json(root / SUMMARY_PATH, violations)
    source_count, declared_total = audit_summary(summary, violations)
    rows = read_csv(root / STRATEGY_SUMMARY_PATH, violations)
    target_rows = audit_strategy_rows(rows, declared_total, violations)
    return {
        "ok": not violations,
        "package_dir": str(root),
        "summary": {
            "sources": source_count,
            "declared_total_train_patients": declared_total,
            "strategy_rows": len(rows),
            "target_run_rows": target_rows,
            "violations": len(violations),
        },
        "violations": [{**item, "severity": "error"} for item in violations],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit SepsisCare training metadata for provenance and pollution signals")
    parser.add_argument("package_dir", nargs="?", default="02_model_deploy_package")
    args = parser.parse_args(argv)
    report = audit_training_data_integrity(args.package_dir)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
