#!/usr/bin/env python3
"""Audit SepsisCare runtime history data for provenance, PHI leakage, and pollution."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


PATIENTS_FILE = "history_patients.json"
DETAILS_FILE = "history_details.json"
REQUIRED_PATIENT_FIELDS = ("history_id", "masked_id", "data_source", "quality_tag", "annotation_status")
SENSITIVE_FIELD_FRAGMENTS = (
    "address",
    "birth",
    "dob",
    "email",
    "free_text",
    "hadm",
    "medical_record",
    "mrn",
    "name",
    "note",
    "phone",
    "secret",
    "ssn",
    "stay_id",
    "subject",
    "token",
)
SENSITIVE_TEXT_PATTERNS = (
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    re.compile(r"\b(?:MRN|HADM|SUBJECT|SSN|ID)\s*[:：#-]?\s*[A-Za-z0-9_-]{2,}\b", re.IGNORECASE),
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    re.compile(r"\b(?:DOB|birth|birthday)\s*[:：#-]?\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}\b", re.IGNORECASE),
    re.compile(r"(?<!\d)(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}(?!\d)"),
)
CLINICAL_RANGES = {
    "heart_rate": (20.0, 260.0),
    "pulse": (20.0, 260.0),
    "map": (20.0, 200.0),
    "sbp": (40.0, 300.0),
    "dbp": (20.0, 180.0),
    "resp_rate": (4.0, 80.0),
    "spo2": (0.0, 100.0),
    "temperature": (25.0, 45.0),
    "gcs": (3.0, 15.0),
    "lactate": (0.0, 30.0),
    "creatinine": (0.0, 20.0),
    "wbc": (0.0, 200.0),
    "platelet": (0.0, 2000.0),
    "bun": (0.0, 250.0),
    "glucose": (0.0, 1200.0),
    "potassium": (0.0, 12.0),
    "sodium": (80.0, 200.0),
    "bilirubin": (0.0, 80.0),
    "los_hours": (0.0, 24.0 * 365.0),
    "missing_rate": (0.0, 1.0),
}


class RuntimeDataAuditError(RuntimeError):
    pass


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RuntimeDataAuditError(f"cannot read {path}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeDataAuditError(f"invalid json: {path}") from exc


def short_hash(value: Any) -> str:
    text = str(value or "")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16] if text else ""


def field_is_sensitive(field: Any) -> bool:
    lowered = str(field or "").lower()
    return any(fragment in lowered for fragment in SENSITIVE_FIELD_FRAGMENTS)


def text_has_sensitive_pattern(value: str) -> bool:
    return any(pattern.search(value) for pattern in SENSITIVE_TEXT_PATTERNS)


def add_violation(violations: list[dict[str, Any]], category: str, location: str, **fields: Any) -> None:
    payload = {"category": category, "location": location}
    payload.update({key: value for key, value in fields.items() if value not in (None, "")})
    violations.append(payload)


def iter_values(value: Any, location: str) -> list[tuple[str, Any]]:
    items: list[tuple[str, Any]] = [(location, value)]
    if isinstance(value, dict):
        for key, child in value.items():
            items.extend(iter_values(child, f"{location}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            items.extend(iter_values(child, f"{location}[{index}]"))
    return items


def audit_sensitive_content(value: Any, location: str, violations: list[dict[str, Any]]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            if field_is_sensitive(key):
                add_violation(violations, "sensitive_field", child_location, field=str(key))
            audit_sensitive_content(child, child_location, violations)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            audit_sensitive_content(child, f"{location}[{index}]", violations)
        return
    if isinstance(value, str) and text_has_sensitive_pattern(value):
        add_violation(violations, "sensitive_text", location, value_hash=short_hash(value))


def audit_numeric_value(field: str, value: Any, location: str, violations: list[dict[str, Any]]) -> None:
    if field not in CLINICAL_RANGES or value in (None, ""):
        return
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        add_violation(violations, "clinical_outlier", location, field=field, reason="non_numeric")
        return
    minimum, maximum = CLINICAL_RANGES[field]
    if numeric < minimum or numeric > maximum:
        add_violation(violations, "clinical_outlier", location, field=field, value=numeric, minimum=minimum, maximum=maximum)


def audit_numeric_content(value: Any, location: str, violations: list[dict[str, Any]]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            audit_numeric_value(str(key), child, child_location, violations)
            audit_numeric_content(child, child_location, violations)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            audit_numeric_content(child, f"{location}[{index}]", violations)


def audit_patient_rows(patients: Any, violations: list[dict[str, Any]]) -> set[str]:
    if not isinstance(patients, list):
        add_violation(violations, "invalid_schema", PATIENTS_FILE, expected="list")
        return set()
    seen_history: dict[str, int] = {}
    seen_masked: dict[str, int] = {}
    history_ids: set[str] = set()
    for index, row in enumerate(patients):
        location = f"{PATIENTS_FILE}[{index}]"
        if not isinstance(row, dict):
            add_violation(violations, "invalid_schema", location, expected="object")
            continue
        missing = [field for field in REQUIRED_PATIENT_FIELDS if not str(row.get(field) or "").strip()]
        if missing:
            add_violation(violations, "missing_provenance", location, fields=missing)
        history_id = str(row.get("history_id") or "")
        masked_id = str(row.get("masked_id") or "")
        if history_id:
            history_ids.add(history_id)
            if history_id in seen_history:
                add_violation(violations, "duplicate_identifier", location, field="history_id", first_index=seen_history[history_id])
            else:
                seen_history[history_id] = index
        if masked_id:
            if masked_id in seen_masked:
                add_violation(violations, "duplicate_identifier", location, field="masked_id", first_index=seen_masked[masked_id])
            else:
                seen_masked[masked_id] = index
        audit_sensitive_content(row, location, violations)
        audit_numeric_content(row, location, violations)
    return history_ids


def audit_detail_rows(details: Any, known_history_ids: set[str], violations: list[dict[str, Any]]) -> tuple[int, int]:
    if not isinstance(details, dict):
        add_violation(violations, "invalid_schema", DETAILS_FILE, expected="object")
        return 0, 0
    detail_rows = 0
    for history_id, rows in details.items():
        location = f"{DETAILS_FILE}.{history_id}"
        if history_id not in known_history_ids:
            add_violation(violations, "orphan_detail_series", location, history_hash=short_hash(history_id))
        if not isinstance(rows, list):
            add_violation(violations, "invalid_schema", location, expected="list")
            continue
        detail_rows += len(rows)
        for index, row in enumerate(rows):
            row_location = f"{location}[{index}]"
            if not isinstance(row, dict):
                add_violation(violations, "invalid_schema", row_location, expected="object")
                continue
            audit_sensitive_content(row, row_location, violations)
            audit_numeric_content(row, row_location, violations)
    return len(details), detail_rows


def audit_runtime_data(runtime_dir: str | Path) -> dict[str, Any]:
    root = Path(runtime_dir)
    patients_path = root / PATIENTS_FILE
    details_path = root / DETAILS_FILE
    issues: list[dict[str, Any]] = []
    try:
        patients = read_json(patients_path)
        details = read_json(details_path)
    except RuntimeDataAuditError as exc:
        return {
            "ok": False,
            "runtime_dir": str(root),
            "summary": {},
            "violations": [{"category": "read_error", "location": str(root), "detail": str(exc)}],
            "warnings": [],
        }
    history_ids = audit_patient_rows(patients, issues)
    detail_series, detail_rows = audit_detail_rows(details, history_ids, issues)
    warnings: list[dict[str, Any]] = []
    violations: list[dict[str, Any]] = []
    for issue in issues:
        if issue.get("category") == "clinical_outlier" and "._detail_profile." in str(issue.get("location") or ""):
            warning = dict(issue)
            warning["category"] = "clinical_warning"
            warning["severity"] = "warning"
            warnings.append(warning)
        else:
            violation = dict(issue)
            violation["severity"] = "error"
            violations.append(violation)
    return {
        "ok": not violations,
        "runtime_dir": str(root),
        "summary": {
            "patients": len(patients) if isinstance(patients, list) else 0,
            "detail_series": detail_series,
            "detail_rows": detail_rows,
            "violations": len(violations),
            "warnings": len(warnings),
        },
        "violations": violations,
        "warnings": warnings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit SepsisCare runtime history data for PHI leakage and pollution")
    parser.add_argument("runtime_data_dir", nargs="?", default="02_model_deploy_package/runtime_data")
    args = parser.parse_args(argv)
    report = audit_runtime_data(args.runtime_data_dir)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
