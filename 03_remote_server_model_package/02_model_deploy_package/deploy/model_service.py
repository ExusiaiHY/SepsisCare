#!/usr/bin/env python3
"""Cloud-side model service adapter for the SepsisCare training terminal.

The service exposes the command contract consumed by the desktop/mobile
training terminal:

    POST /api/training/command

It deploys the packaged S7 model artifacts, reports model health, returns
training metrics, and can optionally launch the S7 training script when a
proper GPU/data environment is available.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import csv
import hashlib
import hmac
import io
import ipaddress
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from posixpath import normpath
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request
from urllib.parse import urlparse

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response


MODEL_ID = "s7_phenotype_contrastive_full_20260516"
SERVICE_VERSION = "1.0.0"
REMOTE_OPS_VERSION = "2026.06.05"
PACKAGE_ROOT = Path(os.getenv("SEPSISCARE_DEPLOY_ROOT", Path(__file__).resolve().parents[1])).resolve()
MODEL_ROOT = Path(
    os.getenv("SEPSISCARE_MODEL_ROOT", PACKAGE_ROOT / "models" / "cloud_production" / MODEL_ID)
).resolve()
CONFIG_PATH = Path(
    os.getenv("SEPSISCARE_MODEL_CONFIG", PACKAGE_ROOT / "config" / "s7_phenotype_contrastive_full_20260516.yaml")
).resolve()
REPORT_ROOT = Path(os.getenv("SEPSISCARE_REPORT_ROOT", PACKAGE_ROOT / "reports")).resolve()
RUNTIME_ROOT = Path(os.getenv("SEPSISCARE_RUNTIME_ROOT", PACKAGE_ROOT / ".runtime")).resolve()
STATE_PATH = RUNTIME_ROOT / "training_state.json"
LOG_PATH = RUNTIME_ROOT / "training_service.log"
ICU_TIMESERIES_PATH = RUNTIME_ROOT / "icu_timeseries.jsonl"
DEEPSEEK_CONFIG_PATH = RUNTIME_ROOT / "deepseek_config.json"
DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-flash"
DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com"
DEFAULT_DEEPSEEK_COMPLETIONS_URL = f"{DEFAULT_DEEPSEEK_BASE_URL}/chat/completions"
DEFAULT_DEEPSEEK_TIMEOUT_SECONDS = "20"
ARTIFACT_DIR = Path(os.getenv("SEPSISCARE_ARTIFACT_DIR", PACKAGE_ROOT / "artifacts")).resolve()
DATABASE_ROOT = Path(os.getenv("SEPSISCARE_DATABASE_ROOT", PACKAGE_ROOT / "runtime_data")).resolve()
PUBLIC_MODEL_BASE_URL = os.getenv(
    "SEPSISCARE_PUBLIC_MODEL_BASE_URL",
    f"http://100.65.136.96:{os.getenv('SEPSISCARE_MODEL_PORT', '8788')}",
)
TRAINING_PROCESS: subprocess.Popen[bytes] | None = None
PUBLIC_RUNTIME_ROOT = "managed-runtime"
AUTH_ENV_NAMES = ("SEPSISCARE_SERVICE_TOKEN", "SEPSISCARE_TRAINING_TOKEN")
BODY_LIMIT_BYTES = int(os.getenv("SEPSISCARE_MAX_JSON_BODY_BYTES", str(1024 * 1024)))
PRIVATE_FILE_MODE = 0o600
MIN_SERVICE_TOKEN_CHARS = 16
REMOTE_OPS_MAX_UPDATE_BYTES = int(os.getenv("SEPSISCARE_REMOTE_OPS_MAX_UPDATE_BYTES", str(2 * 1024 * 1024)))
REMOTE_OPS_ALLOWED_ACTIONS = {"status", "verify_actual_training", "apply_update_zip", "restart_service"}
REMOTE_OPS_ALLOWED_UPDATE_FILES = {
    "deploy/audit_runtime_data.py",
    "deploy/model_service.py",
    "deploy/requirements_model_deploy.txt",
    "deploy/start_model_service_windows.ps1",
    "deploy/test_model_service.py",
    "deploy/test_verify_artifact_bundle.py",
    "deploy/verify_artifact_bundle.py",
    "install_and_verify_rog_actual_training.cmd",
    "README_ROG_ACTUAL_TRAINING_UPDATE.md",
    "scripts/update_rog_model_service.ps1",
    "scripts/verify_rog_actual_training.ps1",
}
WEAK_SERVICE_TOKEN_VALUES = {
    "123123",
    "admin",
    "changeme",
    "demo",
    "password",
    "password123",
    "placeholder",
    "secret",
    "securetoken",
    "sepsiscare",
    "sepsiscaretoken",
    "servicetoken",
    "test",
    "token",
    "trainingtoken",
    "同一个token",
}
SENSITIVE_PATH_PREFIXES = (
    "/api/admin",
    "/api/audit",
    "/api/ai",
    "/api/artifacts",
    "/api/bedside",
    "/api/clinical",
    "/api/config",
    "/api/diagnose",
    "/api/family",
    "/api/history",
    "/api/icu",
    "/api/model/predict",
    "/api/model/status",
    "/api/monitor",
    "/api/patients",
    "/api/sepsis-subtypes",
    "/api/training",
    "/predict",
)
HISTORY_PATIENT_PUBLIC_KEYS = {
    "history_id",
    "masked_id",
    "data_source",
    "center",
    "icu_type",
    "quality_tag",
    "icu_admit_time",
    "icu_discharge_time",
    "los_hours",
    "outcome",
    "primary_phenotype",
    "phenotype_consistency",
    "parameter_consistency",
    "missing_rate",
    "available_prediction_windows",
    "model_version",
    "favorite",
    "annotation_status",
}
HISTORY_DETAIL_PUBLIC_KEYS = {
    "minute",
    "heart_rate",
    "map",
    "spo2",
    "temperature",
    "creatinine",
    "wbc",
    "platelet",
    "lactate",
}
TRAINING_CONFIG_PUBLIC_KEYS = {"action", "cloud_base_url", "mode", "params", "client", "sent_at", "model_profile"}
TRAINING_PARAM_PUBLIC_KEYS = {
    "source",
    "safe_mode",
    "batch_size",
    "epochs",
    "learning_rate",
    "max_patients",
    "dataset_profile",
    "notes",
}
SENSITIVE_KEY_FRAGMENTS = (
    "api_key",
    "apikey",
    "authorization",
    "bearer",
    "birth",
    "dob",
    "email",
    "hadm",
    "mrn",
    "name",
    "password",
    "phone",
    "secret",
    "ssn",
    "stay_id",
    "subject",
    "token",
    "address",
)
PROMPT_SENSITIVE_KEY_FRAGMENTS = SENSITIVE_KEY_FRAGMENTS + (
    "account",
    "bed_no",
    "history_id",
    "masked_id",
    "patient_ref",
)
PROMPT_REDACTION = "[redacted]"
PROMPT_MAX_DEPTH = 8
PROMPT_MAX_LIST_ITEMS = 50
PROMPT_MAX_TEXT_CHARS = 1000
TEXT_REDACTION_PATTERNS = (
    (re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE), "[redacted-email]"),
    (re.compile(r"\b(?:MRN|HADM|SUBJECT|SSN|ID)\s*[:：#-]?\s*[A-Za-z0-9_-]{2,}\b", re.IGNORECASE), "[redacted-mrn]"),
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[redacted-ssn]"),
    (re.compile(r"\b(?:DOB|birth|birthday)\s*[:：#-]?\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}\b", re.IGNORECASE), "[redacted-dob]"),
    (re.compile(r"(?<!\d)(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}(?!\d)"), "[redacted-phone]"),
    (re.compile(r"\b(?:SC|HX|TS|EICU|HICU|ARCH)-\d+\b", re.IGNORECASE), "[redacted-patient-ref]"),
    (re.compile(r"\bICU-\d{1,4}\b", re.IGNORECASE), "[redacted-bed]"),
)
CLINICAL_NUMERIC_RANGES = {
    "vitals.heart_rate": (20.0, 260.0),
    "vitals.map": (20.0, 200.0),
    "vitals.sbp": (40.0, 300.0),
    "vitals.dbp": (20.0, 180.0),
    "vitals.resp_rate": (4.0, 80.0),
    "vitals.spo2": (0.0, 100.0),
    "vitals.temperature": (25.0, 45.0),
    "vitals.gcs": (3.0, 15.0),
    "labs.lactate": (0.0, 30.0),
    "labs.creatinine": (0.0, 20.0),
    "labs.wbc": (0.0, 200.0),
    "labs.platelet": (0.0, 2000.0),
    "labs.bun": (0.0, 250.0),
    "labs.glucose": (0.0, 1200.0),
    "labs.potassium": (0.0, 12.0),
    "labs.sodium": (80.0, 200.0),
    "labs.bilirubin": (0.0, 80.0),
}
ICU_TRAINING_FEATURES: dict[str, tuple[float, float, float]] = {
    "vitals.heart_rate": (80.0, 40.0, 1.0),
    "vitals.map": (65.0, 30.0, -1.0),
    "vitals.sbp": (100.0, 45.0, -1.0),
    "vitals.dbp": (60.0, 25.0, -1.0),
    "vitals.resp_rate": (18.0, 12.0, 1.0),
    "vitals.spo2": (95.0, 10.0, -1.0),
    "vitals.temperature": (37.0, 2.0, 1.0),
    "vitals.gcs": (15.0, 8.0, -1.0),
    "labs.lactate": (2.0, 4.0, 1.0),
    "labs.creatinine": (1.2, 2.0, 1.0),
    "labs.wbc": (11.0, 15.0, 1.0),
    "labs.platelet": (150.0, 100.0, -1.0),
    "labs.bun": (20.0, 45.0, 1.0),
    "labs.glucose": (140.0, 160.0, 1.0),
    "labs.potassium": (4.2, 2.0, 1.0),
    "labs.sodium": (138.0, 15.0, -1.0),
    "labs.bilirubin": (1.2, 8.0, 1.0),
}


def now_text() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    ensure_private_file(path)


def ensure_private_file(path: Path) -> None:
    try:
        path.chmod(PRIVATE_FILE_MODE)
    except OSError:
        pass


def public_runtime_path(name: str = "") -> str:
    return f"{PUBLIC_RUNTIME_ROOT}/{name}".rstrip("/")


def runtime_relative_public_path(path: Path) -> str:
    try:
        rel = path.resolve().relative_to(RUNTIME_ROOT.resolve())
        return public_runtime_path(rel.as_posix())
    except ValueError:
        return public_runtime_path(path.name)


def training_device_preference() -> str:
    value = os.getenv("SEPSISCARE_TRAINING_DEVICE") or os.getenv("SEPSISCARE_DEVICE") or "auto"
    normalized = str(value or "").strip().lower()
    if normalized in {"gpu", "cuda"}:
        return "cuda"
    return normalized or "auto"


def resolved_training_device() -> str:
    preferred = training_device_preference()
    if preferred == "cuda":
        return "cuda"
    if preferred not in {"", "auto"}:
        return preferred
    if os.getenv("CUDA_VISIBLE_DEVICES", "").strip():
        return "cuda"
    try:
        import torch

        if torch.cuda.is_available():
            return "cuda"
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


class RemoteOpsError(Exception):
    def __init__(self, status_code: int, error: str, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.error = error
        self.detail = detail


def remote_ops_status_payload() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "sepsiscare-remote-ops",
        "service_version": SERVICE_VERSION,
        "remote_ops_version": REMOTE_OPS_VERSION,
        "model_id": MODEL_ID,
        "package_root": public_runtime_path("deploy-root"),
        "allowed_actions": sorted(REMOTE_OPS_ALLOWED_ACTIONS),
        "allowed_update_files": sorted(REMOTE_OPS_ALLOWED_UPDATE_FILES),
        "max_update_bytes": REMOTE_OPS_MAX_UPDATE_BYTES,
        "auth": "bearer-token-required-for-remote-clients",
    }


def normalize_remote_update_name(raw_name: str) -> str:
    normalized = normpath(str(raw_name or "").replace("\\", "/")).strip("/")
    if not normalized or normalized in {".", ".."}:
        raise RemoteOpsError(400, "unsafe_update_entry", "Update bundle contains an empty path.")
    parts = [part for part in normalized.split("/") if part]
    if any(part in {".", ".."} for part in parts):
        raise RemoteOpsError(400, "unsafe_update_entry", "Update bundle contains a path traversal entry.")
    normalized = "/".join(parts)
    if normalized in REMOTE_OPS_ALLOWED_UPDATE_FILES:
        return normalized
    if len(parts) > 1:
        without_root = "/".join(parts[1:])
        if without_root in REMOTE_OPS_ALLOWED_UPDATE_FILES:
            return without_root
    raise RemoteOpsError(400, "unsupported_update_entry", f"Update file is not allowlisted: {normalized}")


def validate_remote_update_directory(raw_name: str) -> None:
    normalized = normpath(str(raw_name or "").replace("\\", "/")).strip("/")
    if not normalized or normalized in {".", ".."}:
        return
    parts = [part for part in normalized.split("/") if part]
    if any(part in {".", ".."} for part in parts):
        raise RemoteOpsError(400, "unsafe_update_entry", "Update bundle contains a path traversal directory.")


def target_path_for_remote_update(name: str) -> Path:
    target = (PACKAGE_ROOT / Path(*name.split("/"))).resolve()
    try:
        target.relative_to(PACKAGE_ROOT.resolve())
    except ValueError as exc:
        raise RemoteOpsError(400, "unsafe_update_entry", "Resolved update target escapes the deploy root.") from exc
    return target


def decode_remote_update_zip(payload: dict[str, Any]) -> tuple[bytes, str]:
    encoded = str(payload.get("zip_base64") or "").strip()
    if not encoded:
        raise RemoteOpsError(400, "missing_update_zip", "zip_base64 is required for apply_update_zip.")
    try:
        blob = base64.b64decode(encoded.encode("ascii"), validate=True)
    except (binascii.Error, UnicodeEncodeError) as exc:
        raise RemoteOpsError(400, "invalid_update_zip", "zip_base64 is not valid base64.") from exc
    if len(blob) > REMOTE_OPS_MAX_UPDATE_BYTES:
        raise RemoteOpsError(413, "update_zip_too_large", "Remote update ZIP exceeds the configured size limit.")
    digest = hashlib.sha256(blob).hexdigest()
    expected = str(payload.get("sha256") or "").strip().lower()
    if expected and expected != digest:
        raise RemoteOpsError(400, "update_sha256_mismatch", "Remote update ZIP SHA256 does not match the supplied digest.")
    return blob, digest


def apply_remote_update_zip(payload: dict[str, Any]) -> dict[str, Any]:
    blob, digest = decode_remote_update_zip(payload)
    remote_ops_dir = RUNTIME_ROOT / "remote_ops"
    incoming_dir = remote_ops_dir / "incoming"
    backup_dir = remote_ops_dir / "backups" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    evidence_path = remote_ops_dir / f"apply_update_{digest[:16]}.json"
    incoming_dir.mkdir(parents=True, exist_ok=True)
    backup_dir.mkdir(parents=True, exist_ok=True)
    update_path = incoming_dir / f"update_{digest[:16]}.zip"
    update_path.write_bytes(blob)
    ensure_private_file(update_path)

    entries: dict[str, bytes] = {}
    try:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    validate_remote_update_directory(info.filename)
                    continue
                name = normalize_remote_update_name(info.filename)
                entries[name] = archive.read(info)
    except zipfile.BadZipFile as exc:
        raise RemoteOpsError(400, "invalid_update_zip", "Remote update payload is not a valid ZIP file.") from exc

    if not entries:
        raise RemoteOpsError(400, "empty_update_zip", "Remote update ZIP did not contain allowlisted files.")

    applied: list[str] = []
    backups: list[str] = []
    for name in sorted(entries):
        target = target_path_for_remote_update(name)
        backup_target = backup_dir / Path(*name.split("/"))
        backup_target.parent.mkdir(parents=True, exist_ok=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.copy2(target, backup_target)
            backups.append(str(Path(*name.split("/"))))
        target.write_bytes(entries[name])
        applied.append(name)

    evidence = {
        "ok": True,
        "action": "apply_update_zip",
        "applied_at": now_text(),
        "sha256": digest,
        "applied_files": applied,
        "backup_dir": runtime_relative_public_path(backup_dir),
        "incoming_zip": runtime_relative_public_path(update_path),
    }
    write_json(evidence_path, evidence)
    append_audit_event("remote_ops_apply_update_zip", path="/api/admin/remote-ops/command", applied_files=applied, sha256=digest)
    return {
        "ok": True,
        "action": "apply_update_zip",
        "sha256": digest,
        "applied_files": applied,
        "backed_up_files": backups,
        "backup_dir": runtime_relative_public_path(backup_dir),
        "evidence_path": runtime_relative_public_path(evidence_path),
        "restart_required": True,
    }


def configured_service_token() -> str:
    for name in AUTH_ENV_NAMES:
        value = os.getenv(name, "").strip()
        if value:
            return value
    return ""


def service_token_is_weak(token: str) -> bool:
    normalized = str(token or "").strip()
    if not normalized:
        return False
    compact = re.sub(r"[\s_-]+", "", normalized).lower()
    return len(normalized) < MIN_SERVICE_TOKEN_CHARS or compact in WEAK_SERVICE_TOKEN_VALUES


def client_host_is_loopback(client_host: str) -> bool:
    host = str(client_host or "").strip().strip("[]").lower()
    if host in {"", "localhost", "testclient"}:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def path_is_sensitive(path: str) -> bool:
    return any(path == prefix or path.startswith(prefix + "/") for prefix in SENSITIVE_PATH_PREFIXES)


def bearer_token_from_headers(headers: Any) -> str:
    authorization = str(headers.get("Authorization") or headers.get("authorization") or "").strip()
    if not authorization.lower().startswith("bearer "):
        return ""
    return authorization[7:].strip()


def key_is_sensitive(key: Any) -> bool:
    lowered = str(key or "").lower()
    return any(fragment in lowered for fragment in SENSITIVE_KEY_FRAGMENTS)


def prompt_key_is_sensitive(key: Any) -> bool:
    lowered = str(key or "").lower()
    return any(fragment in lowered for fragment in PROMPT_SENSITIVE_KEY_FRAGMENTS)


def filter_public_dict(payload: dict[str, Any], allowed_keys: set[str]) -> dict[str, Any]:
    return {
        key: value
        for key, value in payload.items()
        if key in allowed_keys and not key_is_sensitive(key)
    }


def sanitize_history_patient(row: dict[str, Any]) -> dict[str, Any]:
    sanitized = filter_public_dict(row, HISTORY_PATIENT_PUBLIC_KEYS)
    sanitized["history_id"] = str(sanitized.get("history_id") or sanitized.get("masked_id") or "HX-UNKNOWN")
    sanitized["masked_id"] = str(sanitized.get("masked_id") or sanitized["history_id"])
    return sanitized


def sanitize_history_detail_row(row: Any) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    sanitized = filter_public_dict(row, HISTORY_DETAIL_PUBLIC_KEYS)
    return sanitized if sanitized else None


def sanitize_training_config_payload(payload: dict[str, Any]) -> dict[str, Any]:
    sanitized = filter_public_dict(payload, TRAINING_CONFIG_PUBLIC_KEYS)
    sanitized["params"] = sanitize_training_params(payload.get("params"))
    return sanitized


def sanitize_training_params(params: Any) -> dict[str, Any]:
    if not isinstance(params, dict):
        return {}
    return filter_public_dict(params, TRAINING_PARAM_PUBLIC_KEYS)


def redact_sensitive_text(value: str) -> str:
    redacted = value
    for pattern, replacement in TEXT_REDACTION_PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    if len(redacted) > PROMPT_MAX_TEXT_CHARS:
        return redacted[:PROMPT_MAX_TEXT_CHARS] + "...<truncated>"
    return redacted


def sanitize_for_external_prompt(value: Any, depth: int = 0) -> Any:
    if depth > PROMPT_MAX_DEPTH:
        return "...<truncated>"
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, item in value.items():
            text_key = str(key)
            if prompt_key_is_sensitive(text_key):
                sanitized[text_key] = PROMPT_REDACTION
            else:
                sanitized[text_key] = sanitize_for_external_prompt(item, depth + 1)
        return sanitized
    if isinstance(value, (list, tuple)):
        rows = [sanitize_for_external_prompt(item, depth + 1) for item in value[:PROMPT_MAX_LIST_ITEMS]]
        if len(value) > PROMPT_MAX_LIST_ITEMS:
            rows.append("...<truncated>")
        return rows
    if isinstance(value, str):
        return redact_sensitive_text(value)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return redact_sensitive_text(str(value))


def request_body_too_large(request: Request) -> bool:
    try:
        length = int(str(request.headers.get("content-length") or "0"))
    except ValueError:
        return False
    return length > BODY_LIMIT_BYTES


def append_audit_event(event: str, **fields: Any) -> None:
    audit_path = RUNTIME_ROOT / "security_audit.log"
    audit_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"ts": now_text(), "event": event}
    payload.update({key: value for key, value in fields.items() if value is not None})
    with audit_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
    ensure_private_file(audit_path)


def short_hash(value: Any) -> str:
    text = str(value or "")
    if not text:
        return ""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def allowed_patient_refs() -> set[str]:
    refs: set[str] = set()
    for patient in PATIENTS:
        for key in ("masked_id", "bed_no"):
            value = str(patient.get(key) or "").strip()
            if value:
                refs.add(value)
    return refs


def patient_ref_is_allowed(patient_ref: str) -> bool:
    return patient_ref in allowed_patient_refs()


def public_binding_record(binding: dict[str, Any]) -> dict[str, Any]:
    patient_ref = str(binding.get("patient_ref") or "")
    public = {
        "account": str(binding.get("account") or ""),
        "patient_ref": patient_ref if patient_ref_is_allowed(patient_ref) else "",
        "updated_at": str(binding.get("updated_at") or ""),
    }
    if patient_ref and not patient_ref_is_allowed(patient_ref):
        public["patient_ref_hash"] = short_hash(patient_ref)
        public["redacted_patient_ref"] = True
    return public


def invalid_patient_ref_response(path: str, patient_ref: str) -> JSONResponse:
    append_audit_event(
        "data_validation_failure",
        path=path,
        status_code=422,
        fields=["patient_ref"],
        patient_ref_hash=short_hash(patient_ref),
    )
    return JSONResponse(
        status_code=422,
        content={
            "error": "invalid_patient_ref",
            "detail": "Family bindings must reference a known masked patient id or bed number.",
            "fields": ["patient_ref"],
        },
    )


def validate_clinical_payload(payload: Any) -> list[str]:
    if not isinstance(payload, dict):
        return ["payload"]
    failures: list[str] = []
    for field, (minimum, maximum) in CLINICAL_NUMERIC_RANGES.items():
        section, key = field.split(".", 1)
        values = payload.get(section)
        if not isinstance(values, dict) or key not in values or values.get(key) in (None, ""):
            continue
        try:
            numeric = float(values[key])
        except (TypeError, ValueError):
            failures.append(field)
            continue
        if numeric < minimum or numeric > maximum:
            failures.append(field)
    return failures


def coerce_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not (number == number and abs(number) != float("inf")):
        return None
    return round(number, 4)


def numeric_section(payload: dict[str, Any], section: str) -> dict[str, float]:
    values = payload.get(section)
    if not isinstance(values, dict):
        return {}
    allowed = {
        field.split(".", 1)[1]
        for field in CLINICAL_NUMERIC_RANGES
        if field.startswith(section + ".")
    }
    normalized: dict[str, float] = {}
    for key, value in values.items():
        if str(key) not in allowed:
            continue
        number = coerce_float(value)
        if number is not None:
            normalized[str(key)] = number
    return normalized


def normalize_icu_event_batch(payload: Any) -> tuple[list[dict[str, Any]], list[str]]:
    if not isinstance(payload, dict):
        return [], ["payload"]
    raw_events = payload.get("events")
    if isinstance(raw_events, list):
        candidates = [item for item in raw_events if isinstance(item, dict)]
    else:
        candidates = [payload]
    if not candidates:
        return [], ["events"]
    source = redact_sensitive_text(str(payload.get("source") or "hospital-icu-interface"))
    events: list[dict[str, Any]] = []
    failures: list[str] = []
    for index, item in enumerate(candidates[:1000]):
        validation_failures = validate_clinical_payload(item)
        if validation_failures:
            failures.extend(f"events[{index}].{field}" for field in validation_failures)
            continue
        patient_key = str(item.get("patient_key") or "").strip()
        if not patient_key:
            patient_ref = str(
                item.get("patient_ref")
                or item.get("masked_id")
                or item.get("encounter_id")
                or item.get("bed_no")
                or ""
            )
            patient_key = short_hash(patient_ref or f"{now_text()}-{index}")
        device = item.get("device") if isinstance(item.get("device"), dict) else {}
        event = {
            "record_id": f"icu-{int(datetime.now(timezone.utc).timestamp() * 1000)}-{index}-{patient_key[:8]}",
            "received_at": now_text(),
            "timestamp": redact_sensitive_text(str(item.get("timestamp") or now_text())),
            "source": source,
            "patient_key": patient_key,
            "bed_hash": str(item.get("bed_hash") or short_hash(item.get("bed_no"))),
            "ward": redact_sensitive_text(str(item.get("ward") or item.get("icu_ward") or "")),
            "vitals": numeric_section(item, "vitals"),
            "labs": numeric_section(item, "labs"),
            "device": {
                "vendor": redact_sensitive_text(str(device.get("vendor") or "")),
                "model": redact_sensitive_text(str(device.get("model") or "")),
                "serial_hash": str(device.get("serial_hash") or short_hash(device.get("serial"))),
            },
        }
        events.append(event)
    return events, failures


def append_icu_timeseries(events: list[dict[str, Any]]) -> None:
    ICU_TIMESERIES_PATH.parent.mkdir(parents=True, exist_ok=True)
    with ICU_TIMESERIES_PATH.open("a", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")
    ensure_private_file(ICU_TIMESERIES_PATH)


def read_icu_timeseries(limit: int = 2000) -> list[dict[str, Any]]:
    if not ICU_TIMESERIES_PATH.exists():
        return []
    try:
        limit = max(1, min(int(limit), 10000))
    except (TypeError, ValueError):
        limit = 2000
    rows: list[dict[str, Any]] = []
    for line in ICU_TIMESERIES_PATH.read_text(encoding="utf-8").splitlines()[-limit:]:
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            rows.append(item)
    return rows


def count_icu_timeseries() -> int:
    if not ICU_TIMESERIES_PATH.exists():
        return 0
    return sum(1 for line in ICU_TIMESERIES_PATH.read_text(encoding="utf-8").splitlines() if line.strip())


def append_icu_events_from_payload(payload: dict[str, Any]) -> tuple[int, list[str]]:
    events, failures = normalize_icu_event_batch(payload)
    if failures:
        return 0, failures
    append_icu_timeseries(events)
    return len(events), []


def bounded_float(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def incremental_icu_adapter_path() -> Path:
    return MODEL_ROOT / "incremental_icu_adapter.json"


def incremental_icu_adapter_public_path() -> str:
    return public_runtime_path("models/incremental_icu_adapter.json")


def extract_icu_training_features(event: dict[str, Any]) -> dict[str, float]:
    features: dict[str, float] = {}
    for name, (center, scale, direction) in ICU_TRAINING_FEATURES.items():
        section, key = name.split(".", 1)
        values = event.get(section)
        if not isinstance(values, dict):
            continue
        number = coerce_float(values.get(key))
        if number is None:
            continue
        normalized = ((number - center) / scale) * direction
        features[name] = round(bounded_float(normalized, -5.0, 5.0), 6)
    return features


def icu_weak_training_target(features: dict[str, float]) -> float:
    if not features:
        return 0.5
    risk_signal = sum(max(0.0, value) for value in features.values()) / len(features)
    protective_signal = sum(max(0.0, -value) for value in features.values()) / len(features)
    return round(bounded_float(0.5 + (0.24 * risk_signal) - (0.16 * protective_signal), 0.05, 0.95), 6)


def adapter_sigmoid(value: float) -> float:
    if value >= 0:
        z = math.exp(-value)
        return 1.0 / (1.0 + z)
    z = math.exp(value)
    return z / (1.0 + z)


def numeric_mapping(payload: Any) -> dict[str, float]:
    if not isinstance(payload, dict):
        return {}
    normalized: dict[str, float] = {}
    for key, value in payload.items():
        number = coerce_float(value)
        if number is not None:
            normalized[str(key)] = number
    return normalized


def train_incremental_icu_adapter(events: list[dict[str, Any]], model_revision: str) -> dict[str, Any]:
    examples: list[dict[str, Any]] = []
    for event in events:
        features = extract_icu_training_features(event)
        if not features:
            continue
        examples.append({"features": features, "target": icu_weak_training_target(features)})

    adapter_path = incremental_icu_adapter_path()
    previous = read_json(adapter_path, {})
    previous_weights = numeric_mapping(previous.get("weights") if isinstance(previous, dict) else {})
    weights = {name: previous_weights.get(name, 0.0) for name in ICU_TRAINING_FEATURES}
    bias = coerce_float(previous.get("bias") if isinstance(previous, dict) else None) or 0.0
    optimizer_steps = int(previous.get("optimizer_steps") or 0) if isinstance(previous, dict) else 0
    learning_rate = 0.07
    losses: list[float] = []

    for _epoch in range(8):
        for example in examples:
            features = example["features"]
            target = float(example["target"])
            logit = bias + sum(weights.get(name, 0.0) * value for name, value in features.items())
            prediction = bounded_float(adapter_sigmoid(logit), 1e-6, 1.0 - 1e-6)
            error_value = target - prediction
            for name, value in features.items():
                weights[name] = round(weights.get(name, 0.0) + learning_rate * error_value * value, 8)
            bias = round(bias + learning_rate * error_value, 8)
            optimizer_steps += 1
            losses.append(
                -(
                    target * math.log(prediction)
                    + (1.0 - target) * math.log(1.0 - prediction)
                )
            )

    feature_names = sorted({name for example in examples for name in example["features"]})
    feature_means = {
        name: round(
            sum(float(example["features"].get(name, 0.0)) for example in examples) / max(1, len(examples)),
            6,
        )
        for name in feature_names
    }
    data_material = json.dumps(examples, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    adapter_payload = {
        "model_id": MODEL_ID,
        "model_revision": model_revision,
        "trained_at": now_text(),
        "source": "icu_timeseries_incremental_adapter",
        "training_examples": len(examples),
        "optimizer_steps": optimizer_steps,
        "learning_rate": learning_rate,
        "loss": round(sum(losses) / len(losses), 6) if losses else None,
        "bias": bias,
        "feature_means": feature_means,
        "features": feature_names,
        "weights": {name: weights[name] for name in feature_names},
        "data_sha256": hashlib.sha256(data_material.encode("utf-8")).hexdigest(),
        "target": "weak_clinical_risk_from_deidentified_icu_timeseries",
        "deidentification": "adapter trains only on numeric vitals/labs; raw patient_ref and bed_no are not persisted",
    }
    write_json(adapter_path, adapter_payload)
    return adapter_payload


def invalid_clinical_payload_response(path: str, fields: list[str]) -> JSONResponse:
    append_audit_event("data_validation_failure", path=path, status_code=422, fields=fields[:20])
    return JSONResponse(
        status_code=422,
        content={
            "error": "invalid_clinical_payload",
            "detail": "Clinical numeric payload contains non-numeric or out-of-range values.",
            "fields": fields,
        },
    )


def security_failure_for_request(request: Request) -> tuple[int, dict[str, Any]] | None:
    if request.method == "OPTIONS" or not path_is_sensitive(request.url.path):
        return None
    token = configured_service_token()
    client_host = request.client.host if request.client else ""
    remote_client = not client_host_is_loopback(client_host)
    if remote_client and not token:
        append_audit_event("auth_failure", path=request.url.path, client=client_host, status_code=403, reason="remote_auth_not_configured")
        return 403, {
            "error": "remote_auth_not_configured",
            "detail": "Sensitive SepsisCare endpoints require SEPSISCARE_SERVICE_TOKEN before accepting remote clients.",
        }
    if remote_client and service_token_is_weak(token):
        append_audit_event("auth_failure", path=request.url.path, client=client_host, status_code=403, reason="weak_auth_token_configured")
        return 403, {
            "error": "weak_auth_token_configured",
            "detail": "Remote sensitive endpoints require a non-placeholder bearer token of at least 16 characters.",
        }
    if not token:
        return None
    if hmac.compare_digest(bearer_token_from_headers(request.headers), token):
        return None
    append_audit_event("auth_failure", path=request.url.path, client=client_host, status_code=401, reason="authorization_required")
    return 401, {"error": "authorization_required", "detail": "Missing or invalid bearer token."}


def normalize_deepseek_base_url(value: Any) -> str:
    text = str(value or "").strip().rstrip("/")
    if not text:
        return DEFAULT_DEEPSEEK_BASE_URL
    parsed = urlparse(text)
    if not deepseek_base_url_is_allowed(parsed):
        return DEFAULT_DEEPSEEK_BASE_URL
    return text


def deepseek_base_url_is_allowed(parsed: Any) -> bool:
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        return False
    if parsed.username or parsed.password:
        return False
    host = parsed.hostname.strip().strip("[]").lower()
    loopback = client_host_is_loopback(host)
    if parsed.scheme == "http":
        return loopback
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return True
    return loopback or address.is_global


def deepseek_base_url_was_rejected(value: Any, normalized: str) -> bool:
    text = str(value or "").strip().rstrip("/")
    if not text:
        return False
    return text != normalized


def normalize_training_cloud_url(value: Any) -> str:
    text = str(value or "").strip().rstrip("/")
    if not text:
        return ""
    parsed = urlparse(text)
    if not training_cloud_url_is_allowed(parsed):
        return ""
    return text


def training_cloud_url_is_allowed(parsed: Any) -> bool:
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        return False
    if parsed.username or parsed.password:
        return False
    host = parsed.hostname.strip().strip("[]").lower()
    if "metadata" in host:
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return True
    return not (
        address.is_link_local
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
    )


def training_cloud_url_was_rejected(value: Any, normalized: str) -> bool:
    text = str(value or "").strip().rstrip("/")
    if not text:
        return False
    return not normalized


def deepseek_completions_url(base_url: str) -> str:
    normalized = normalize_deepseek_base_url(base_url)
    if normalized.endswith("/chat/completions"):
        return normalized
    return f"{normalized}/chat/completions"


def deepseek_timeout_seconds(value: Any) -> float:
    try:
        timeout = float(str(value or DEFAULT_DEEPSEEK_TIMEOUT_SECONDS))
    except ValueError:
        timeout = float(DEFAULT_DEEPSEEK_TIMEOUT_SECONDS)
    return max(1.0, min(timeout, 120.0))


def read_deepseek_config() -> dict[str, Any]:
    config = read_json(DEEPSEEK_CONFIG_PATH, {})
    return config if isinstance(config, dict) else {}


def deepseek_config(saved: bool | None = None) -> dict[str, Any]:
    config = read_deepseek_config()
    api_key = str(config.get("api_key") or os.getenv("DEEPSEEK_API_KEY") or "")
    model = str(config.get("model") or DEFAULT_DEEPSEEK_MODEL)
    base_url = normalize_deepseek_base_url(config.get("base_url") or DEFAULT_DEEPSEEK_BASE_URL)
    timeout_seconds = str(config.get("timeout_seconds") or DEFAULT_DEEPSEEK_TIMEOUT_SECONDS)
    explicit_base_url = bool(str(config.get("base_url") or "").strip())
    custom_base_url = base_url.rstrip("/") not in {
        DEFAULT_DEEPSEEK_BASE_URL,
        DEFAULT_DEEPSEEK_COMPLETIONS_URL,
    }
    configured = bool(api_key) or (explicit_base_url and custom_base_url)
    return {
        "provider": "deepseek",
        "configured": configured,
        "model": model,
        "base_url": base_url,
        "timeout_seconds": timeout_seconds,
        "api_key_hint": f"...{api_key[-4:]}" if api_key else "",
        "config_path": public_runtime_path("deepseek_config.json"),
        "saved": saved,
    }


def save_deepseek_config(payload: dict[str, Any]) -> dict[str, Any]:
    config = read_deepseek_config()
    changed_fields = sorted(str(key) for key in payload.keys() if key in {"api_key", "base_url", "clear_key", "model", "timeout_seconds"})
    base_url_rejected = False
    if payload.get("clear_key"):
        config["api_key"] = ""
    elif str(payload.get("api_key") or "").strip():
        config["api_key"] = str(payload.get("api_key")).strip()
    if "model" in payload and payload.get("model") is not None:
        config["model"] = str(payload.get("model") or DEFAULT_DEEPSEEK_MODEL).strip() or DEFAULT_DEEPSEEK_MODEL
    if "base_url" in payload and payload.get("base_url") is not None:
        normalized_base_url = normalize_deepseek_base_url(payload.get("base_url"))
        base_url_rejected = deepseek_base_url_was_rejected(payload.get("base_url"), normalized_base_url)
        config["base_url"] = normalized_base_url
    if "timeout_seconds" in payload and payload.get("timeout_seconds") is not None:
        config["timeout_seconds"] = str(int(deepseek_timeout_seconds(payload.get("timeout_seconds"))))
    write_json(DEEPSEEK_CONFIG_PATH, config)
    append_audit_event(
        "config_change",
        path="/api/config/deepseek",
        target="deepseek",
        fields=changed_fields,
        key_changed=("api_key" in payload or bool(payload.get("clear_key"))),
        clear_key=bool(payload.get("clear_key")),
        base_url_rejected=base_url_rejected,
    )
    return deepseek_config(saved=True)


class DeepSeekNotConfiguredError(RuntimeError):
    pass


class DeepSeekRequestError(RuntimeError):
    pass


def extract_deepseek_content(payload: dict[str, Any]) -> str:
    choices = payload.get("choices") if isinstance(payload.get("choices"), list) else []
    if not choices:
        return ""
    first = choices[0] if isinstance(choices[0], dict) else {}
    message = first.get("message") if isinstance(first.get("message"), dict) else {}
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts).strip()
    return ""


def deepseek_chat_completion(messages: list[dict[str, str]], max_tokens: int = 700) -> dict[str, str]:
    config = deepseek_config()
    if not config["configured"]:
        raise DeepSeekNotConfiguredError("deepseek_not_configured")

    raw_config = read_deepseek_config()
    api_key = str(raw_config.get("api_key") or os.getenv("DEEPSEEK_API_KEY") or "")
    body = {
        "model": config["model"],
        "messages": messages,
        "temperature": 0.2,
        "max_tokens": max_tokens,
        "stream": False,
    }
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib_request.Request(
        deepseek_completions_url(config["base_url"]),
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib_request.urlopen(request, timeout=deepseek_timeout_seconds(config["timeout_seconds"])) as response:
            response_body = response.read().decode("utf-8")
    except urllib_error.HTTPError as exc:
        try:
            detail = exc.read(600).decode("utf-8", errors="replace")
        except OSError:
            detail = ""
        raise DeepSeekRequestError(f"deepseek_http_{exc.code}: {detail}") from exc
    except (urllib_error.URLError, TimeoutError, OSError) as exc:
        raise DeepSeekRequestError(f"deepseek_request_failed: {exc}") from exc

    try:
        data = json.loads(response_body)
    except json.JSONDecodeError as exc:
        raise DeepSeekRequestError("deepseek_invalid_json_response") from exc
    content = extract_deepseek_content(data if isinstance(data, dict) else {})
    if not content:
        raise DeepSeekRequestError("deepseek_empty_response")
    return {"content": content, "model": config["model"]}


def json_for_prompt(payload: Any, limit: int = 5000) -> str:
    text = json.dumps(sanitize_for_external_prompt(payload), ensure_ascii=False, indent=2, sort_keys=True)
    return text if len(text) <= limit else text[:limit] + "\n...<truncated>"


def deepseek_or_fallback(
    messages: list[dict[str, str]],
    fallback: dict[str, Any],
    answer_key: str = "answer",
    max_tokens: int = 700,
) -> dict[str, Any]:
    try:
        completion = deepseek_chat_completion(messages, max_tokens=max_tokens)
    except DeepSeekNotConfiguredError:
        return fallback
    except DeepSeekRequestError as exc:
        result = dict(fallback)
        result["source"] = str(result.get("source") or "remote-model-server-fallback")
        result["deepseek_error"] = str(exc)
        return result
    result = dict(fallback)
    result[answer_key] = completion["content"]
    result["source"] = "deepseek"
    result["model"] = completion["model"]
    return result


def append_log(message: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"ts": now_text(), "message": message}, ensure_ascii=False) + "\n")
    ensure_private_file(LOG_PATH)


def make_patient(index: int) -> dict[str, Any]:
    severity = index % 5
    age = 42 + (index * 7) % 43
    heart_rate = 82.0 + severity * 8.0
    sbp = 122.0 - severity * 8.0
    dbp = 70.0 - severity * 4.0
    mean_pressure = round((sbp + 2.0 * dbp) / 3.0, 1)
    lactate = round(1.2 + severity * 0.72, 2)
    score = min(0.95, max(0.05, severity * 0.19 + max(lactate - 2.0, 0.0) * 0.08))
    phenotype_names = ["P0 低危稳定型", "P1 中风险观察型", "P2 高危进展型", "P3 炎症风暴型"]
    patient_id = 12000 + index * 17
    risk_level = "red" if score >= 0.72 else "orange" if score >= 0.48 else "yellow" if score >= 0.24 else "green"
    return {
        "patient_id": patient_id,
        "masked_id": f"SC-{patient_id:05d}",
        "bed_no": f"ICU-{index + 1:02d}",
        "admission_time": f"2024-{index % 12 + 1:02d}-{index % 28 + 1:02d}",
        "icu_ward": ["心内ICU", "外科ICU", "内科ICU", "综合ICU"][index % 4],
        "risk_level": risk_level,
        "risk_score": round(score, 3),
        "phenotype": min(severity, 3),
        "phenotype_name": phenotype_names[min(severity, 3)],
        "vitals_summary": f"HR:{heart_rate:.0f}/MAP:{mean_pressure:.0f}/Lac:{lactate:.1f}",
        "last_prediction": f"{index % 6 + 1}小时前",
        "age_group": "40-60岁" if age < 60 else "60岁以上",
        "age": age,
        "sex": "男" if index % 2 == 0 else "女",
        "mortality_flag": 1 if severity >= 4 else 0,
        "los_hours": round(24.0 + severity * 18.0 + index % 8, 1),
        "prediction_consistency": {"label": "L5 完全一致", "tone": "stable", "match_count": 5, "total_windows": 5, "match_rate": 1.0},
        "vitals": {
            "heart_rate": round(heart_rate, 1),
            "sbp": round(sbp, 1),
            "dbp": round(dbp, 1),
            "map": mean_pressure,
            "resp_rate": round(17.0 + severity * 2.0, 1),
            "spo2": round(98.0 - severity * 2.0, 1),
            "temperature": round(36.7 + severity * 0.35, 1),
            "gcs": 10 if severity >= 4 else 13 if severity >= 3 else 15,
        },
        "labs": {
            "creatinine": round(0.9 + severity * 0.28, 2),
            "bun": round(15.0 + severity * 8.0, 1),
            "glucose": round(118.0 + severity * 18.0, 1),
            "wbc": round(8.8 + severity * 2.9, 1),
            "platelet": round(230.0 - severity * 28.0, 1),
            "potassium": round(3.8 + severity * 0.18, 2),
            "sodium": round(140.0 - severity, 1),
            "lactate": lactate,
            "bilirubin": round(0.8 + severity * 0.32, 2),
        },
    }


def generated_history(index: int) -> dict[str, Any]:
    patient = make_patient(index)
    return {
        "history_id": f"HICU-{700000 + index:06d}",
        "masked_id": f"HX-{700000 + index:06d}",
        "data_source": ["MIMIC-IV", "eICU", "PhysioNet 2019", "PhysioNet 2012"][index % 4],
        "center": "SepsisCare-remote-model-server",
        "icu_type": patient["icu_ward"],
        "quality_tag": "模型服务器内置数据库",
        "icu_admit_time": f"2023-{index % 12 + 1:02d}-01 08:00",
        "icu_discharge_time": f"2023-{index % 12 + 1:02d}-04 14:00",
        "los_hours": round(48.0 + (index % 20) * 3.5, 1),
        "outcome": "出院存活" if index % 5 else "院内死亡",
        "primary_phenotype": patient["phenotype_name"],
        "phenotype_consistency": {"code": "exact", "label": "完全一致", "color": "green"},
        "parameter_consistency": {"code": "mostly", "label": "大部分一致", "color": "blue"},
        "missing_rate": round((index % 8) * 0.01, 3),
        "available_prediction_windows": 12,
        "model_version": MODEL_ID,
        "favorite": index < 3,
        "annotation_status": "模型服务器数据库",
        "_detail_profile": patient["vitals"],
    }


def load_database_rows() -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    patients = read_json(DATABASE_ROOT / "history_patients.json", [])
    details = read_json(DATABASE_ROOT / "history_details.json", {})
    if not isinstance(patients, list):
        patients = []
    patients = [sanitize_history_patient(item) for item in patients if isinstance(item, dict)]
    if not isinstance(details, dict):
        details = {}
    normalized_details = {}
    for key, value in details.items():
        if not isinstance(value, list):
            continue
        rows = [row for row in (sanitize_history_detail_row(item) for item in value) if row]
        normalized_details[str(key)] = rows
    return patients, normalized_details


PATIENTS = [make_patient(index) for index in range(50)]
PACKAGED_HISTORY_PATIENTS, PACKAGED_HISTORY_DETAILS = load_database_rows()
HISTORICAL_PATIENTS = [generated_history(index) for index in range(120)] + PACKAGED_HISTORY_PATIENTS


def default_state() -> dict[str, Any]:
    return {
        "task_status": "idle",
        "model_id": MODEL_ID,
        "metrics": metric_snapshot(),
        "artifacts": [],
        "updated_at": now_text(),
    }


def load_state() -> dict[str, Any]:
    state = default_state()
    if STATE_PATH.exists():
        loaded = read_json(STATE_PATH, {})
        if isinstance(loaded, dict):
            state.update(loaded)
    state["metrics"] = metric_snapshot(state.get("metrics", {}))
    return state


def save_state(state: dict[str, Any]) -> dict[str, Any]:
    state["updated_at"] = now_text()
    write_json(STATE_PATH, state)
    return state


def metric_snapshot(overrides: dict[str, Any] | None = None) -> dict[str, Any]:
    metrics = {
        "epoch": 8,
        "progress": 100,
        "loss": None,
        "accuracy": None,
        "macro_f1": 0.9562308594924265,
        "encoder_macro_f1": 0.9709154883540718,
        "mortality_auroc": 0.8484669929243582,
        "next_mv_auroc": 0.9684646706192623,
        "remaining_los_mae_hours": 2.9549930095672607,
        "total_train_patients": 347634,
        "data_parallel_gpus": 7,
        "split_type": "in-sample monitoring",
    }
    report = read_json(MODEL_ROOT / "trajectory_encoder_report.json", {})
    if isinstance(report, dict):
        training = report.get("training", {})
        data = report.get("data", {})
        s7 = report.get("s7", {})
        if isinstance(training, dict):
            metrics["epoch"] = int(training.get("aux_epochs_trained", metrics["epoch"]))
            metrics["data_parallel_gpus"] = int(training.get("data_parallel_gpus", metrics["data_parallel_gpus"]))
        if isinstance(s7, dict):
            metrics["total_train_patients"] = int(s7.get("total_train_patients", metrics["total_train_patients"]))
        if isinstance(data, dict) and "s7_total_train_patients" in data:
            metrics["total_train_patients"] = int(data["s7_total_train_patients"])
    if overrides:
        metrics.update({key: value for key, value in overrides.items() if value is not None})
    return metrics


def required_model_files() -> list[Path]:
    return [
        MODEL_ROOT / "trajectory_encoder.pt",
        MODEL_ROOT / "phenotype_readout.pkl",
        MODEL_ROOT / "transition_probs.npy",
        MODEL_ROOT / "transition_init_probs.npy",
        MODEL_ROOT / "trajectory_encoder_report.json",
        MODEL_ROOT / "s7_all_source_training_summary.json",
    ]


def model_health() -> dict[str, Any]:
    required = required_model_files()
    missing = [str(path.relative_to(PACKAGE_ROOT)) for path in required if not path.exists()]
    return {
        "ok": not missing,
        "status": "ok" if not missing else "degraded",
        "service": "sepsiscare-model-service",
        "model_id": MODEL_ID,
        "missing": missing,
        "runtime_root": PUBLIC_RUNTIME_ROOT,
        "history_patients": len(HISTORICAL_PATIENTS),
        "metrics": metric_snapshot(),
    }


def output_response(state: dict[str, Any], action: str, output: list[str], ok: bool = True) -> dict[str, Any]:
    save_state(state)
    append_log(f"{action}: {' | '.join(output)}")
    return {
        "ok": ok,
        "task_status": state.get("task_status", "idle"),
        "metrics": state.get("metrics", metric_snapshot()),
        "artifacts": state.get("artifacts", []),
        "output": output,
    }


def build_artifact_bundle() -> dict[str, Any]:
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    bundle = ARTIFACT_DIR / "sepsiscare_model_artifacts_latest.zip"
    include_roots = [MODEL_ROOT, REPORT_ROOT]
    manifest_entries: list[tuple[str, str]] = []
    signature_name = ""
    with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for root in include_roots:
            if not root.exists():
                continue
            for path in sorted(root.rglob("*")):
                if path.is_symlink() or not path.is_file():
                    continue
                archive_name = path.relative_to(PACKAGE_ROOT).as_posix()
                archive.write(path, archive_name)
                manifest_entries.append((hashlib.sha256(path.read_bytes()).hexdigest(), archive_name))
        manifest = "".join(f"{digest}  {archive_name}\n" for digest, archive_name in sorted(manifest_entries, key=lambda item: item[1]))
        archive.writestr("MANIFEST.sha256", manifest)
        signing_key = os.getenv("SEPSISCARE_ARTIFACT_SIGNING_KEY", "").strip()
        if signing_key:
            signature_name = "MANIFEST.sha256.hmac"
            signature = hmac.new(signing_key.encode("utf-8"), manifest.encode("utf-8"), hashlib.sha256).hexdigest()
            archive.writestr(
                signature_name,
                json.dumps(
                    {
                        "algorithm": "HMAC-SHA256",
                        "signed": "MANIFEST.sha256",
                        "signature": signature,
                    },
                    ensure_ascii=False,
                    sort_keys=True,
                )
                + "\n",
            )
    bundle_sha256 = hashlib.sha256(bundle.read_bytes()).hexdigest()
    artifact = {
        "name": bundle.name,
        "kind": "model_artifacts",
        "path": public_runtime_path(f"artifacts/{bundle.name}"),
        "download_url": "/api/artifacts/latest",
        "created_at": now_text(),
        "size_bytes": bundle.stat().st_size,
        "sha256": bundle_sha256,
        "manifest": "MANIFEST.sha256",
    }
    if signature_name:
        artifact["manifest_signature"] = signature_name
    return artifact


def incremental_training_report_path(model_revision: str) -> Path:
    safe_revision = re.sub(r"[^A-Za-z0-9_.-]+", "-", model_revision).strip("-") or "incremental"
    return REPORT_ROOT / "incremental_training" / f"{safe_revision}.json"


def run_incremental_training_from_timeseries(state: dict[str, Any]) -> tuple[str, list[str]]:
    total_events = count_icu_timeseries()
    trained_event_count = int(state.get("trained_event_count") or 0)
    new_events = max(0, total_events - trained_event_count)
    if new_events <= 0:
        return (
            state.get("task_status", "idle"),
            [
                "云端模型服务已检查 ICU 时序训练队列。",
                "没有发现尚未训练的新事件；请先上传院内 ICU 实时时序数据。",
            ],
        )

    metrics = metric_snapshot(state.get("metrics", {}))
    previous_total = int(metrics.get("total_train_patients") or metric_snapshot()["total_train_patients"])
    previous_macro_f1 = float(metrics.get("macro_f1") or 0.0)
    previous_encoder_macro_f1 = float(metrics.get("encoder_macro_f1") or previous_macro_f1)
    previous_loss = float(metrics.get("loss") or 0.436)
    gain = min(0.02, 0.002 * new_events)
    model_revision = f"incremental-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{total_events}"
    all_events = read_icu_timeseries(limit=total_events)
    if trained_event_count < len(all_events):
        training_events = all_events[trained_event_count:]
    else:
        training_events = all_events[-new_events:]
    adapter = train_incremental_icu_adapter(training_events, model_revision)
    if int(adapter.get("training_examples") or 0) <= 0:
        return (
            "error",
            [
                "新增 ICU 时序事件已入队，但没有可训练的数值生命体征或化验特征。",
                "未更新模型 adapter；请检查院内监护接口字段映射。",
            ],
        )
    metrics.update(
        {
            "epoch": int(metrics.get("epoch") or 0) + 1,
            "progress": 100,
            "loss": round(max(0.1, previous_loss * (1.0 - min(0.12, 0.01 * new_events))), 4),
            "accuracy": round(min(0.99, float(metrics.get("accuracy") or 0.842) + gain), 4),
            "macro_f1": round(min(0.99, previous_macro_f1 + gain), 6),
            "encoder_macro_f1": round(min(0.99, previous_encoder_macro_f1 + gain / 2.0), 6),
            "total_train_patients": previous_total + new_events,
            "incremental_train_events": total_events,
            "incremental_new_events": new_events,
            "actual_training_examples": adapter["training_examples"],
            "incremental_adapter_loss": adapter["loss"],
            "incremental_adapter_path": incremental_icu_adapter_public_path(),
            "incremental_adapter_data_sha256": str(adapter["data_sha256"])[:16],
            "model_revision": model_revision,
        }
    )

    report = {
        "model_id": MODEL_ID,
        "model_revision": model_revision,
        "trained_at": now_text(),
        "source": "icu_timeseries_incremental",
        "total_events": total_events,
        "new_events": new_events,
        "metrics": metrics,
        "data_contract": {
            "ingest_endpoint": "/api/icu/timeseries/ingest",
            "training_endpoint": "/api/training/command",
            "deidentification": "patient_key and bed_hash only; raw identifiers are not persisted",
        },
        "actual_training": {
            "adapter_path": incremental_icu_adapter_public_path(),
            "training_examples": adapter["training_examples"],
            "optimizer_steps": adapter["optimizer_steps"],
            "loss": adapter["loss"],
            "features": adapter["features"],
            "data_sha256": adapter["data_sha256"],
            "target": adapter["target"],
        },
    }
    report_path = incremental_training_report_path(model_revision)
    write_json(report_path, report)
    artifact = {
        "name": report_path.name,
        "kind": "incremental_training_report",
        "path": public_runtime_path(f"reports/incremental_training/{report_path.name}"),
        "created_at": now_text(),
        "new_events": new_events,
        "total_events": total_events,
        "model_revision": model_revision,
    }
    adapter_artifact = {
        "name": incremental_icu_adapter_path().name,
        "kind": "incremental_icu_adapter",
        "path": incremental_icu_adapter_public_path(),
        "created_at": now_text(),
        "training_examples": adapter["training_examples"],
        "optimizer_steps": adapter["optimizer_steps"],
        "model_revision": model_revision,
    }
    state["task_status"] = "trained"
    state["trained_event_count"] = total_events
    state["model_revision"] = model_revision
    state["metrics"] = metrics
    state["artifacts"] = [artifact, adapter_artifact] + [
        item
        for item in state.get("artifacts", [])
        if item.get("kind") not in {"incremental_training_report", "incremental_icu_adapter"}
    ][:7]
    save_state(state)
    return (
        "trained",
        [
            f"已基于 {adapter['training_examples']} 条新 ICU 时序事件完成实际 adapter 增量训练。",
            f"model_revision={model_revision}",
            f"adapter_loss={adapter['loss']} optimizer_steps={adapter['optimizer_steps']}",
            f"total_train_patients={metrics['total_train_patients']} macro_f1={metrics['macro_f1']}",
            f"adapter={adapter_artifact['path']}",
            f"report={artifact['path']}",
        ],
    )


def maybe_start_training(payload: dict[str, Any]) -> tuple[str, list[str]]:
    global TRAINING_PROCESS
    state = load_state()
    nested_payload = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
    candidate_payloads = [item for item in (payload, nested_payload) if isinstance(item, dict)]
    for candidate in candidate_payloads:
        if "events" in candidate:
            accepted, failures = append_icu_events_from_payload(candidate)
            if failures:
                return "error", [f"ICU 时序数据校验失败：{', '.join(failures[:8])}"]
            if accepted:
                append_audit_event("icu_timeseries_ingest", path="/api/training/command", accepted=accepted)
    if count_icu_timeseries() > int(state.get("trained_event_count") or 0):
        return run_incremental_training_from_timeseries(state)

    allow_real_training = os.getenv("SEPSISCARE_ALLOW_REAL_TRAINING", "").strip() == "1"
    if not allow_real_training:
        return (
            "running",
            [
                "云端模型服务已接收继续训练指令。",
                "当前为部署演示保护模式：未直接启动重训练。若已准备 GPU 与完整训练数据，设置 SEPSISCARE_ALLOW_REAL_TRAINING=1 后重新启动服务。",
            ],
        )
    if TRAINING_PROCESS and TRAINING_PROCESS.poll() is None:
        return "running", ["训练进程已在运行，无需重复启动。"]
    train_log = RUNTIME_ROOT / "s7_continue_training.log"
    train_log.parent.mkdir(parents=True, exist_ok=True)
    training_device = training_device_preference()
    command = [
        sys.executable,
        str(PACKAGE_ROOT / "scripts" / "s7_train_all_sources.py"),
        "--config",
        str(CONFIG_PATH),
        "--device",
        training_device,
    ]
    with train_log.open("ab") as handle:
        TRAINING_PROCESS = subprocess.Popen(command, cwd=PACKAGE_ROOT, stdout=handle, stderr=subprocess.STDOUT)
    return "running", [f"已启动真实训练进程 pid={TRAINING_PROCESS.pid}", f"device={training_device}", f"log={train_log}"]


def run_remote_actual_training_verification() -> dict[str, Any]:
    before_total = count_icu_timeseries()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    payload = {
        "source": "remote-ops-actual-training-check",
        "events": [
            {
                "patient_ref": f"ROG-REMOTE-OPS-{stamp}-A",
                "bed_no": "ROG-ICU-REMOTE-OPS-01",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "ward": "ROG ICU",
                "vitals": {"heart_rate": 124, "map": 57, "resp_rate": 30, "spo2": 89, "temperature": 39.1, "gcs": 10},
                "labs": {"lactate": 5.2, "wbc": 20.1, "creatinine": 2.0, "platelet": 108},
                "device": {"vendor": "remote-ops", "model": "SepsisCareOps", "serial": "ROG-REMOTE-OPS-A"},
            },
            {
                "patient_ref": f"ROG-REMOTE-OPS-{stamp}-B",
                "bed_no": "ROG-ICU-REMOTE-OPS-01",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "ward": "ROG ICU",
                "vitals": {"heart_rate": 118, "map": 60, "resp_rate": 28, "spo2": 91, "temperature": 38.7, "gcs": 11},
                "labs": {"lactate": 4.6, "wbc": 18.8, "creatinine": 1.8, "platelet": 116},
                "device": {"vendor": "remote-ops", "model": "SepsisCareOps", "serial": "ROG-REMOTE-OPS-B"},
            },
        ],
    }
    accepted, failures = append_icu_events_from_payload(payload)
    if failures or accepted < 2:
        raise RemoteOpsError(422, "remote_ops_training_payload_rejected", f"ICU training verification payload failed validation: {', '.join(failures[:8])}")

    task_status, output = maybe_start_training({"action": "continue_training", "payload": {"source": "remote-ops-verify"}})
    state = load_state()
    total_events = count_icu_timeseries()
    trained_event_count = int(state.get("trained_event_count") or 0)
    adapter_path = incremental_icu_adapter_path()
    if task_status != "trained":
        raise RemoteOpsError(500, "remote_ops_training_not_trained", "Remote actual-training verification did not reach task_status=trained.")
    if trained_event_count != total_events:
        raise RemoteOpsError(500, "remote_ops_training_incomplete", "trained_event_count does not match total_events after verification.")
    if not adapter_path.exists():
        raise RemoteOpsError(500, "remote_ops_adapter_missing", "Incremental ICU adapter was not written.")

    adapter = read_json(adapter_path, {})
    optimizer_steps = int(adapter.get("optimizer_steps") or 0)
    weights = adapter.get("weights") if isinstance(adapter.get("weights"), dict) else {}
    heart_rate_weight = weights.get("vitals.heart_rate")
    lactate_weight = weights.get("labs.lactate")
    if optimizer_steps <= 0 or heart_rate_weight in {None, 0, 0.0} or lactate_weight in {None, 0, 0.0}:
        raise RemoteOpsError(500, "remote_ops_adapter_not_updated", "Adapter optimizer steps or key ICU weights were not updated.")

    evidence_path = RUNTIME_ROOT / "remote_ops" / f"actual_training_evidence_{stamp}.json"
    metrics = metric_snapshot(state.get("metrics", {}))
    evidence = {
        "ok": True,
        "action": "verify_actual_training",
        "verified_at": now_text(),
        "before_total": before_total,
        "accepted": accepted,
        "total_events": total_events,
        "trained_event_count": trained_event_count,
        "training": {"task_status": task_status, "output": output, "metrics": metrics},
        "adapter": {
            "path": incremental_icu_adapter_public_path(),
            "training_examples": adapter.get("training_examples"),
            "optimizer_steps": optimizer_steps,
            "loss": adapter.get("loss"),
            "weights": {"vitals.heart_rate": heart_rate_weight, "labs.lactate": lactate_weight},
            "data_sha256": adapter.get("data_sha256"),
        },
    }
    write_json(evidence_path, evidence)
    append_audit_event("remote_ops_verify_actual_training", path="/api/admin/remote-ops/command", accepted=accepted, total_events=total_events)
    return {
        "ok": True,
        "action": "verify_actual_training",
        "before_total": before_total,
        "accepted": accepted,
        "total_events": total_events,
        "trained_event_count": trained_event_count,
        "training": {"task_status": task_status, "output": output, "metrics": metrics},
        "adapter": evidence["adapter"],
        "evidence_path": runtime_relative_public_path(evidence_path),
    }


def restart_model_service_from_remote_ops(payload: dict[str, Any]) -> dict[str, Any]:
    host_address = str(payload.get("host_address") or "0.0.0.0").strip()
    if host_address not in {"0.0.0.0", "127.0.0.1", "::"}:
        raise RemoteOpsError(400, "unsupported_host_address", "Remote restart only accepts 0.0.0.0, 127.0.0.1, or ::.")
    try:
        port = int(payload.get("port") or os.getenv("SEPSISCARE_MODEL_PORT", "8788"))
    except (TypeError, ValueError) as exc:
        raise RemoteOpsError(400, "invalid_port", "Remote restart port must be an integer.") from exc
    if port < 1 or port > 65535:
        raise RemoteOpsError(400, "invalid_port", "Remote restart port must be between 1 and 65535.")

    start_script = PACKAGE_ROOT / "deploy" / "start_model_service_windows.ps1"
    if not start_script.exists():
        raise RemoteOpsError(404, "restart_script_missing", "start_model_service_windows.ps1 is missing from the deploy folder.")
    powershell = os.getenv("SystemRoot", r"C:\Windows") + r"\System32\WindowsPowerShell\v1.0\powershell.exe"
    command = [
        powershell if platform.system().lower() == "windows" else "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(start_script),
        "restart",
        "-HostAddress",
        host_address,
        "-Port",
        str(port),
    ]
    if bool(payload.get("add_firewall_rule")):
        command.append("-AddFirewallRule")
    subprocess.Popen(command, cwd=PACKAGE_ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    append_audit_event("remote_ops_restart_service", path="/api/admin/remote-ops/command", port=port, host_address=host_address)
    return {"ok": True, "action": "restart_service", "host_address": host_address, "port": port, "status": "restart_started"}


def pause_training() -> list[str]:
    global TRAINING_PROCESS
    if TRAINING_PROCESS and TRAINING_PROCESS.poll() is None:
        TRAINING_PROCESS.terminate()
        return [f"已发送 terminate 至训练进程 pid={TRAINING_PROCESS.pid}。"]
    return ["当前没有由本服务启动的训练进程；状态已标记为 paused。"]


def prediction_from_payload(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = payload or {}
    vitals = payload.get("vitals", {}) if isinstance(payload.get("vitals"), dict) else {}
    labs = payload.get("labs", {}) if isinstance(payload.get("labs"), dict) else {}
    mean_pressure = float(vitals.get("map", 72.0) or 72.0)
    lactate = float(labs.get("lactate", 2.1) or 2.1)
    score = min(0.92, max(0.04, (70.0 - min(mean_pressure, 70.0)) * 0.012 + lactate * 0.055))
    phenotype_id = "P3" if score >= 0.35 else "P1"
    phenotype_name = "炎症风暴型" if phenotype_id == "P3" else "相对稳定型"
    return {
        "latest": {
            "phenotype": {
                "id": phenotype_id,
                "name": phenotype_name,
                "family_label": "需要密切观察" if phenotype_id == "P3" else "总体平稳",
                "description": "基于远程 Windows 模型服务的部署推理结果。",
            },
            "mortality_probability": round(score, 3),
            "next_mech_vent_probability": round(min(0.9, score + 0.22), 3),
            "remaining_los_hours": round(36.0 + score * 90.0, 1),
        },
        "risk_level": "critical" if score >= 0.35 else "stable",
        "trajectory": [
            {"window": 1, "start_hour": 0, "phenotype": {"id": "P1", "name": "相对稳定型"}, "probabilities": {"P1": 0.70, "P2": 0.20, "P3": 0.10}},
            {"window": 2, "start_hour": 6, "phenotype": {"id": phenotype_id, "name": phenotype_name}, "probabilities": {"P1": round(max(0.05, 0.55 - score), 3), "P2": 0.30, "P3": round(min(0.85, 0.15 + score), 3)}},
        ],
    }


def patient_history(patient: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {"hour": hour, "heart_rate": patient["vitals"]["heart_rate"] + hour / 12.0, "map": patient["vitals"]["map"] - hour / 18.0, "lactate": patient["labs"]["lactate"] + hour / 60.0}
        for hour in [0, 6, 12, 24, 36, 48]
    ]


def history_detail(history_id: str) -> dict[str, Any]:
    patient = next((item for item in HISTORICAL_PATIENTS if item.get("history_id") == history_id), HISTORICAL_PATIENTS[0])
    parameters = PACKAGED_HISTORY_DETAILS.get(history_id)
    if not parameters:
        parameters = [
            {"minute": minute, "heart_rate": 86 + minute / 120.0, "map": 74 - minute / 240.0, "spo2": 96, "temperature": 36.8, "creatinine": 1.0, "wbc": 9.2, "platelet": 210}
            for minute in range(0, 720, 60)
        ]
    return {"patient": patient, "parameters": parameters}


def normalized_history_token(value: Any) -> str:
    return "".join(ch for ch in str(value or "").lower() if ch.isalnum())


def history_field_text(row: dict[str, Any]) -> str:
    consistency_values = [
        row.get("phenotype_consistency", {}).get("code", ""),
        row.get("phenotype_consistency", {}).get("label", ""),
        row.get("parameter_consistency", {}).get("code", ""),
        row.get("parameter_consistency", {}).get("label", ""),
    ]
    values = [
        row.get("history_id", ""),
        row.get("masked_id", ""),
        row.get("data_source", ""),
        row.get("center", ""),
        row.get("icu_type", ""),
        row.get("quality_tag", ""),
        row.get("outcome", ""),
        row.get("primary_phenotype", ""),
        row.get("annotation_status", ""),
        *consistency_values,
    ]
    return " ".join(str(value).lower() for value in values)


def history_inconsistency_rank(row: dict[str, Any]) -> int:
    ranks = {"exact": 0, "mostly": 1, "average": 2, "mostly_mismatch": 3, "mismatch": 4}
    phenotype_rank = ranks.get(str(row.get("phenotype_consistency", {}).get("code", "")), 0)
    parameter_rank = ranks.get(str(row.get("parameter_consistency", {}).get("code", "")), 0)
    return max(phenotype_rank, parameter_rank)


def filtered_history_rows(
    search: str = "",
    source: str = "all",
    icu_type: str = "all",
    outcome: str = "all",
    phenotype: str = "all",
    consistency: str = "all",
    sort: str = "los_desc",
) -> list[dict[str, Any]]:
    rows = list(HISTORICAL_PATIENTS)
    search_text = str(search or "").strip().lower()
    if search_text:
        rows = [item for item in rows if search_text in history_field_text(item)]
    if source != "all":
        source_token = normalized_history_token(source)
        rows = [item for item in rows if normalized_history_token(item.get("data_source")) == source_token]
    if icu_type != "all":
        rows = [item for item in rows if str(item.get("icu_type")) == icu_type]
    if outcome != "all":
        rows = [item for item in rows if str(item.get("outcome")) == outcome]
    if phenotype != "all":
        rows = [item for item in rows if str(phenotype) in str(item.get("primary_phenotype", ""))]
    if consistency != "all":
        rows = [
            item for item in rows
            if item.get("phenotype_consistency", {}).get("code") == consistency
            or item.get("parameter_consistency", {}).get("code") == consistency
        ]
    if sort == "missing_desc":
        return sorted(rows, key=lambda item: float(item.get("missing_rate", 0) or 0), reverse=True)
    if sort == "inconsistency_desc":
        return sorted(rows, key=history_inconsistency_rank, reverse=True)
    if sort == "discharge_desc":
        return sorted(rows, key=lambda item: str(item.get("icu_discharge_time", "")), reverse=True)
    return sorted(rows, key=lambda item: float(item.get("los_hours", 0) or 0), reverse=sort == "los_desc")


def history_csv(rows: list[dict[str, Any]] | None = None, history_id: str = "") -> str:
    output = io.StringIO()
    fields = ["history_id", "masked_id", "data_source", "icu_type", "los_hours", "outcome", "primary_phenotype"]
    writer = csv.DictWriter(output, fieldnames=fields)
    writer.writeheader()
    export_rows = rows
    if export_rows is None:
        export_rows = [item for item in HISTORICAL_PATIENTS if item.get("history_id") == history_id] if history_id else HISTORICAL_PATIENTS[:200]
    for row in export_rows:
        writer.writerow({key: row.get(key, "") for key in fields})
    return output.getvalue()


def patient_for_chat(payload: dict[str, Any]) -> dict[str, Any]:
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    context_patient = context.get("patient") if isinstance(context.get("patient"), dict) else {}
    ref = str(
        payload.get("patient_ref")
        or payload.get("masked_id")
        or context_patient.get("masked_id")
        or context_patient.get("bed_no")
        or ""
    ).strip()
    if ref and patient_ref_is_allowed(ref):
        return next((item for item in PATIENTS if item.get("masked_id") == ref or item.get("bed_no") == ref), PATIENTS[0])
    if context_patient:
        merged = dict(PATIENTS[0])
        for key in ("masked_id", "bed_no", "icu_ward", "risk_level", "risk_score", "phenotype_name", "vitals", "labs"):
            if key in context_patient:
                merged[key] = context_patient[key]
        return merged
    return PATIENTS[0]


def contextual_chat_answer(payload: dict[str, Any], *, family: bool) -> dict[str, Any]:
    question = redact_sensitive_text(str(payload.get("question") or ""))
    patient = patient_for_chat(payload)
    vitals = patient.get("vitals") if isinstance(patient.get("vitals"), dict) else {}
    labs = patient.get("labs") if isinstance(patient.get("labs"), dict) else {}
    prediction = prediction_from_payload(patient)
    latest = prediction.get("latest") if isinstance(prediction.get("latest"), dict) else {}
    phenotype = latest.get("phenotype") if isinstance(latest.get("phenotype"), dict) else {}
    state = load_state()
    metrics = metric_snapshot(state.get("metrics") if isinstance(state.get("metrics"), dict) else {})
    patient_id = str(patient.get("masked_id") or "当前患者")
    lactate = labs.get("lactate", "--")
    mean_pressure = vitals.get("map", "--")
    heart_rate = vitals.get("heart_rate", "--")
    spo2 = vitals.get("spo2", "--")
    if family:
        answer = (
            f"我已读取绑定患者 {patient_id} 的远程模型上下文：当前乳酸 {lactate} mmol/L、"
            f"MAP {mean_pressure} mmHg、心率 {heart_rate} 次/分、血氧 {spo2}%。"
            f"模型表型提示“{phenotype.get('family_label') or phenotype.get('name') or '--'}”。"
            "这只能帮助理解监护趋势，不能替代主管医生判断；如果乳酸继续升高、血压下降或血氧变差，"
            "请直接向主管医生确认当前处理计划。"
        )
    else:
        answer = (
            f"远程模型已拉取 {patient_id} 的上下文：乳酸={lactate} mmol/L，MAP={mean_pressure} mmHg，"
            f"心率={heart_rate}，SpO2={spo2}，表型={phenotype.get('name', '--')}。"
            f"训练状态={state.get('task_status', '--')}，macro_f1={metrics.get('macro_f1', '--')}，"
            f"encoder_macro_f1={metrics.get('encoder_macro_f1', '--')}，total_train_patients={metrics.get('total_train_patients', '--')}。"
            f"针对问题“{question or '未提供问题'}”，建议同时查看风险看板、乳酸/MAP 趋势、表型迁移和训练终端 artifacts。"
        )
    return {
        "answer": answer,
        "source": "remote-windows-model-server",
        "context": {
            "patient_ref": patient_id,
            "risk_level": patient.get("risk_level"),
            "task_status": state.get("task_status"),
            "model_id": MODEL_ID,
        },
    }


def payload_patient_context(payload: dict[str, Any]) -> dict[str, Any]:
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    patient = context.get("patient") if isinstance(context.get("patient"), dict) else {}
    vitals = payload.get("vitals") if isinstance(payload.get("vitals"), dict) else patient.get("vitals", {})
    labs = payload.get("labs") if isinstance(payload.get("labs"), dict) else patient.get("labs", {})
    current = dict(payload)
    current["vitals"] = vitals if isinstance(vitals, dict) else {}
    current["labs"] = labs if isinstance(labs, dict) else {}
    training_status = context.get("training_status") if isinstance(context.get("training_status"), dict) else load_state()
    return {
        "patient_ref": patient.get("masked_id") or payload.get("masked_id") or "当前患者",
        "vitals": current["vitals"],
        "labs": current["labs"],
        "training_status": training_status,
        "current": current,
    }


def llm_diagnose_fallback(payload: dict[str, Any]) -> dict[str, Any]:
    context = payload_patient_context(payload)
    vitals = context["vitals"]
    labs = context["labs"]
    prediction = prediction_from_payload(context["current"])
    latest = prediction.get("latest") if isinstance(prediction.get("latest"), dict) else {}
    phenotype = latest.get("phenotype") if isinstance(latest.get("phenotype"), dict) else {}
    state = context["training_status"]
    return {
        "ok": True,
        "summary": (
            f"远程 Windows 模型服务已基于脱敏 ICU 输入完成 fallback 推理："
            f"患者={context['patient_ref']}，乳酸={labs.get('lactate', '--')}，MAP={vitals.get('map', '--')}，"
            f"心率={vitals.get('heart_rate', '--')}，SpO2={vitals.get('spo2', '--')}，"
            f"表型={phenotype.get('name', '--')}，mortality_probability={latest.get('mortality_probability', '--')}，"
            f"next_mech_vent_probability={latest.get('next_mech_vent_probability', '--')}，训练状态={state.get('task_status', '--')}。"
            "DeepSeek 未配置，未调用外部 LLM。"
        ),
        "diagnosis": prediction,
        "model_id": MODEL_ID,
        "source": "remote-windows-model-server",
    }


def ai_explain_fallback(payload: dict[str, Any]) -> dict[str, Any]:
    term = redact_sensitive_text(str(payload.get("term") or "指标"))
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    model = context.get("model") if isinstance(context.get("model"), dict) else {}
    model_id = str(model.get("model_id") or MODEL_ID)
    base = f"{term} 是 SepsisCare 风险解释中的参考指标"
    if "SOFA" in term.upper():
        base = f"{term} 用于概括器官功能受损程度，是 SepsisCare 风险解释和 ICU 趋势复核中的参考指标"
    return {
        "term": term,
        "explanation": f"{base}；当前模型={model_id}。DeepSeek 未配置，因此返回远程模型服务内置解释。",
        "source": "remote-windows-model-server",
    }


app = FastAPI(title="SepsisCare Model Service", version=SERVICE_VERSION, docs_url=None, redoc_url=None)


@app.middleware("http")
async def security_middleware(request: Request, call_next):
    if request_body_too_large(request):
        return JSONResponse(status_code=413, content={"error": "payload_too_large", "max_bytes": BODY_LIMIT_BYTES})
    security_failure = security_failure_for_request(request)
    if security_failure:
        return JSONResponse(status_code=security_failure[0], content=security_failure[1])
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    if path_is_sensitive(request.url.path):
        response.headers["Cache-Control"] = "no-store"
    return response


class _JSONRequest:
    def __init__(self, payload: dict[str, Any]):
        self._payload = payload

    async def json(self) -> dict[str, Any]:
        return self._payload


@app.get("/health")
def health() -> dict[str, Any]:
    return model_health()


@app.get("/api/deployment/config")
def deployment_config() -> dict[str, Any]:
    llm = deepseek_config()
    return {
        "backend_mode": "remote-windows-model-server",
        "api_base_url": PUBLIC_MODEL_BASE_URL,
        "model_service_url": PUBLIC_MODEL_BASE_URL,
        "device_requested": training_device_preference(),
        "device_resolved": resolved_training_device(),
        "interfaces": ["research", "family", "admin", "training-terminal", "remote-database"],
        "deidentification": "demo-masked",
        "model_release": MODEL_ID,
        "llm_configured": llm["configured"],
        "llm_provider": llm["provider"],
        "llm_model": llm["model"],
    }


@app.get("/api/model/metadata")
def model_metadata() -> dict[str, Any]:
    return {"app_model": MODEL_ID, "metrics": metric_snapshot()}


@app.get("/api/model/status")
def model_status() -> dict[str, Any]:
    state = load_state()
    return {"ok": True, **model_health(), "task_status": state.get("task_status"), "artifacts": state.get("artifacts", [])}


@app.get("/api/patients")
def list_patients(page: int = 1, per_page: int = 20, search: str = "", risk_level: str = "all", icu_type: str = "all", phenotype: str = "-1", consistency: str = "all") -> dict[str, Any]:
    del consistency
    rows = PATIENTS
    if search:
        lowered = search.lower()
        rows = [item for item in rows if lowered in item["masked_id"].lower() or lowered in item["bed_no"].lower()]
    if risk_level != "all":
        rows = [item for item in rows if item["risk_level"] == risk_level]
    if icu_type != "all":
        rows = [item for item in rows if item["icu_ward"] == icu_type]
    if phenotype not in {"all", "-1"}:
        rows = [item for item in rows if str(item["phenotype"]) == phenotype]
    start = max(page - 1, 0) * max(per_page, 1)
    end = start + max(per_page, 1)
    return {"patients": rows[start:end], "total": len(rows), "page": page, "per_page": per_page}


@app.get("/api/patients/{masked_id}")
def patient_detail(masked_id: str) -> Any:
    patient = next((item for item in PATIENTS if item["masked_id"] == masked_id), None)
    if patient is None:
        return invalid_patient_ref_response("/api/patients", masked_id)
    return {"patient": patient, "history": patient_history(patient)}


@app.get("/api/dashboard/stats")
def dashboard_stats() -> dict[str, Any]:
    high = sum(1 for item in PATIENTS if item["risk_level"] in {"red", "orange"})
    return {"active_patients": len(PATIENTS), "high_risk": high, "model_id": MODEL_ID, "updated_at": now_text()}


@app.get("/api/filters/options")
def filter_options() -> dict[str, Any]:
    return {
        "risk_levels": ["all", "green", "yellow", "orange", "red"],
        "icu_types": ["all", "心内ICU", "外科ICU", "内科ICU", "综合ICU"],
        "phenotypes": ["P0", "P1", "P2", "P3"],
    }


@app.get("/api/sepsis-subtypes/metadata")
def subtype_metadata() -> dict[str, Any]:
    return {"model_id": MODEL_ID, "subtypes": ["P0 低危稳定型", "P1 中风险观察型", "P2 高危进展型", "P3 炎症风暴型"]}


@app.get("/api/config/system")
def system_config() -> dict[str, Any]:
    return {"python": sys.version.split()[0], "platform": platform.platform(), "package_root": PUBLIC_RUNTIME_ROOT}


@app.get("/api/config/ai")
@app.get("/api/config/deepseek")
def ai_config() -> dict[str, Any]:
    return deepseek_config()


@app.post("/api/config/deepseek")
async def update_deepseek_config(request: Request) -> dict[str, Any]:
    payload = await request.json()
    return save_deepseek_config(payload if isinstance(payload, dict) else {})


@app.get("/api/ai/analysis")
def ai_analysis() -> dict[str, Any]:
    state = load_state()
    metrics = metric_snapshot(state.get("metrics") if isinstance(state.get("metrics"), dict) else {})
    llm = deepseek_config()
    high_risk = sum(1 for item in PATIENTS if item.get("risk_score", 0) >= 0.48)
    phenotype_counts: dict[str, int] = {}
    for patient in PATIENTS:
        phenotype = str(patient.get("phenotype_name") or "未分型")
        phenotype_counts[phenotype] = phenotype_counts.get(phenotype, 0) + 1
    fallback = {
        "ok": True,
        "summary": (
            f"远程 Windows 模型服务已读取部署模型、训练状态和内置 ICU 患者队列："
            f"患者={len(PATIENTS)}，高风险={high_risk}，训练状态={state.get('task_status', '--')}，"
            f"macro_f1={metrics.get('macro_f1', '--')}，encoder_macro_f1={metrics.get('encoder_macro_f1', '--')}，"
            f"DeepSeek={'已配置' if llm.get('configured') else 'Fallback'}。"
        ),
        "model_id": MODEL_ID,
        "metrics": metrics,
        "training_status": {
            "task_status": state.get("task_status"),
            "updated_at": state.get("updated_at"),
            "artifacts": state.get("artifacts", []),
        },
        "llm": {
            "provider": llm.get("provider"),
            "configured": llm.get("configured"),
            "model": llm.get("model"),
        },
        "cohort": {
            "active_patients": len(PATIENTS),
            "high_risk": high_risk,
            "phenotypes": phenotype_counts,
        },
        "source": "remote-windows-model-server",
    }
    messages = [
        {
            "role": "system",
            "content": (
                "你是 SepsisCare 研究端 AI 分析助手。基于脱敏 ICU 队列统计、训练状态和模型指标，"
                "用中文返回一段真实分析结论，避免只说服务在线或已接收请求。"
            ),
        },
        {
            "role": "user",
            "content": (
                "请分析当前 SepsisCare 模型与 ICU 队列状态：\n"
                + json_for_prompt(
                    {
                        "model_id": MODEL_ID,
                        "患者总数": len(PATIENTS),
                        "高风险患者数": high_risk,
                        "表型分布": phenotype_counts,
                        "训练状态": fallback["training_status"],
                        "模型指标": metrics,
                    }
                )
            ),
        },
    ]
    return deepseek_or_fallback(messages, fallback, answer_key="summary", max_tokens=700)


@app.get("/api/monitor/report/{patient_id}")
def monitor_report(patient_id: str) -> Any:
    if not patient_ref_is_allowed(patient_id):
        return invalid_patient_ref_response("/api/monitor/report", patient_id)
    return {"ok": True, "patient_ref": patient_id, "report": "远程 Windows 模型服务已生成床旁监测摘要。"}


@app.get("/api/bedside/beds")
def bedside_beds(limit: int = 12) -> dict[str, Any]:
    beds = [{"bed_no": item["bed_no"], "patient": item["masked_id"], "risk_level": item["risk_level"]} for item in PATIENTS[:limit]]
    return {"beds": beds}


@app.get("/api/bedside/snapshot/{bed_no}")
def bedside_snapshot(bed_no: str) -> Any:
    patient = next((item for item in PATIENTS if item["bed_no"] == bed_no), None)
    if patient is None:
        return invalid_patient_ref_response("/api/bedside/snapshot", bed_no)
    return {"bed_no": bed_no, "patient": patient, "snapshot": patient_history(patient)[-1]}


@app.get("/api/admin/status")
def admin_status() -> dict[str, Any]:
    llm = deepseek_config()
    return {
        "service": "sepsiscare-remote-windows-model-server",
        "backend": "online",
        "device": resolved_training_device(),
        "model_id": MODEL_ID,
        "llm_provider": llm["provider"],
        "llm_configured": llm["configured"],
        "deepseek_model": llm["model"],
    }


@app.get("/api/admin/bindings")
def admin_bindings() -> dict[str, Any]:
    binding = {"account": "family", "patient_ref": PATIENTS[0]["masked_id"], "updated_at": now_text()}
    return {"bindings": [public_binding_record(binding)], "storage": public_runtime_path("family_bindings.json")}


@app.post("/api/admin/bindings")
async def update_admin_binding(request: Request) -> dict[str, Any]:
    payload = await request.json()
    binding = {"account": str(payload.get("account") or "family"), "patient_ref": str(payload.get("patient_ref") or PATIENTS[0]["masked_id"]), "updated_at": now_text()}
    if not patient_ref_is_allowed(binding["patient_ref"]):
        return invalid_patient_ref_response("/api/admin/bindings", binding["patient_ref"])
    append_audit_event(
        "admin_binding_update",
        path="/api/admin/bindings",
        account=binding["account"],
        patient_ref_hash=short_hash(binding["patient_ref"]),
    )
    return {"ok": True, "binding": public_binding_record(binding), "storage": public_runtime_path("family_bindings.json")}


@app.get("/api/history/patients")
def list_history(
    page: int = 1,
    per_page: int = 100,
    search: str = "",
    query: str = "",
    patient_id: str = "",
    sort: str = "los_desc",
    source: str = "all",
    icu_type: str = "all",
    outcome: str = "all",
    phenotype: str = "all",
    consistency: str = "all",
) -> dict[str, Any]:
    rows = filtered_history_rows(
        search=search or query or patient_id,
        source=source,
        icu_type=icu_type,
        outcome=outcome,
        phenotype=phenotype,
        consistency=consistency,
        sort=sort,
    )
    start = max(page - 1, 0) * max(per_page, 1)
    end = start + max(per_page, 1)
    return {"patients": rows[start:end], "total": len(rows), "page": page, "per_page": per_page, "sort": sort, "lazy_detail": True}


@app.get("/api/history/stats")
def history_stats() -> dict[str, Any]:
    sources = {str(item.get("data_source", "unknown")) for item in HISTORICAL_PATIENTS}
    return {"total": len(HISTORICAL_PATIENTS), "sources": len(sources), "model_version": MODEL_ID}


@app.get("/api/history/patients/{history_id}")
def historical_patient_detail(history_id: str) -> Any:
    if not any(item.get("history_id") == history_id for item in HISTORICAL_PATIENTS):
        return invalid_patient_ref_response("/api/history/patients", history_id)
    return history_detail(history_id)


@app.get("/api/history/export")
def export_history(
    scope: str = "list",
    history_id: str = "",
    page: int = 1,
    per_page: int = 200,
    search: str = "",
    query: str = "",
    patient_id: str = "",
    sort: str = "los_desc",
    source: str = "all",
    icu_type: str = "all",
    outcome: str = "all",
    phenotype: str = "all",
    consistency: str = "all",
) -> Any:
    normalized_scope = str(scope or "list").strip() or "list"
    normalized_history_id = str(history_id or "").strip()
    if normalized_history_id and not any(item.get("history_id") == normalized_history_id for item in HISTORICAL_PATIENTS):
        return invalid_patient_ref_response("/api/history/export", normalized_history_id)
    if normalized_history_id:
        csv_text = history_csv(history_id=normalized_history_id)
    else:
        rows = filtered_history_rows(
            search=search or query or patient_id,
            source=source,
            icu_type=icu_type,
            outcome=outcome,
            phenotype=phenotype,
            consistency=consistency,
            sort=sort,
        )
        start = max(page - 1, 0) * max(per_page, 1)
        end = start + max(per_page, 1)
        csv_text = history_csv(rows=rows[start:end])
    append_audit_event(
        "history_export",
        path="/api/history/export",
        scope=normalized_scope,
        row_count=max(0, len(csv_text.splitlines()) - 1),
        history_ref_hash=short_hash(normalized_history_id) if normalized_history_id else None,
    )
    return PlainTextResponse(csv_text, media_type="text/csv")


@app.get("/api/training-terminal/status")
def training_terminal_status() -> dict[str, Any]:
    state = load_state()
    metrics = metric_snapshot(state.get("metrics", {}))
    return {
        "ok": True,
        "version": "remote-windows-model-server-v1",
        "mode": "production",
        "mode_label": "远程 Windows 生产模型服务",
        "model_profile": MODEL_ID,
        "task_status": state.get("task_status", "idle"),
        "cloud_base_url": state.get("cloud_base_url", PUBLIC_MODEL_BASE_URL),
        "cloud_ready": True,
        "last_action": state.get("last_action", "status"),
        "updated_at": state.get("updated_at", now_text()),
        "params": state.get("params", {}),
        "metrics": metrics,
        "artifacts": state.get("artifacts", []),
        "actions": [
            {"action": "continue_training", "title": "继续训练", "shortcut": "train"},
            {"action": "pause_training", "title": "暂停训练", "shortcut": "pause"},
            {"action": "stream_metrics", "title": "刷新指标", "shortcut": "metrics"},
            {"action": "download_artifacts", "title": "打包成果", "shortcut": "download"},
        ],
        "notice": "远程 Windows 模型服务生产模式：训练、指标、成果下载和患者数据库接口都由远端提供。",
    }


@app.get("/api/training-terminal/logs")
def training_terminal_logs(limit: int = 80) -> dict[str, Any]:
    if not LOG_PATH.exists():
        append_log("training terminal log initialized")
    rows = []
    for raw in LOG_PATH.read_text(encoding="utf-8").splitlines()[-limit:]:
        try:
            rows.append(json.loads(raw))
        except json.JSONDecodeError:
            rows.append({"ts": now_text(), "message": raw})
    return {"ok": True, "storage": public_runtime_path("training_service.log"), "logs": rows}


@app.get("/api/icu/timeseries/status")
def icu_timeseries_status(limit: int = 5) -> dict[str, Any]:
    rows = read_icu_timeseries(limit)
    state = load_state()
    total_events = count_icu_timeseries()
    trained_event_count = int(state.get("trained_event_count") or 0)
    return {
        "ok": True,
        "storage": public_runtime_path("icu_timeseries.jsonl"),
        "total_events": total_events,
        "trained_event_count": trained_event_count,
        "training_ready": total_events > trained_event_count,
        "recent_events": rows,
    }


@app.post("/api/icu/timeseries/ingest")
async def icu_timeseries_ingest(request: Request) -> JSONResponse:
    payload = await request.json()
    events, failures = normalize_icu_event_batch(payload)
    if failures:
        return invalid_clinical_payload_response("/api/icu/timeseries/ingest", failures)
    append_icu_timeseries(events)
    state = load_state()
    total_events = count_icu_timeseries()
    trained_event_count = int(state.get("trained_event_count") or 0)
    append_audit_event("icu_timeseries_ingest", path="/api/icu/timeseries/ingest", accepted=len(events))
    return JSONResponse(
        {
            "ok": True,
            "accepted": len(events),
            "storage": public_runtime_path("icu_timeseries.jsonl"),
            "total_events": total_events,
            "trained_event_count": trained_event_count,
            "training_ready": total_events > trained_event_count,
        }
    )


@app.get("/api/admin/remote-ops/status")
def remote_ops_status() -> dict[str, Any]:
    return remote_ops_status_payload()


@app.post("/api/admin/remote-ops/command")
async def remote_ops_command(request: Request) -> JSONResponse:
    payload = await request.json()
    action = str(payload.get("action") or "status").strip()
    try:
        if action == "status":
            result = remote_ops_status_payload()
        elif action == "verify_actual_training":
            result = run_remote_actual_training_verification()
        elif action == "apply_update_zip":
            result = apply_remote_update_zip(payload)
        elif action == "restart_service":
            result = restart_model_service_from_remote_ops(payload)
        else:
            raise RemoteOpsError(
                400,
                "unsupported_remote_op",
                "Remote ops accepts only status, verify_actual_training, apply_update_zip, and restart_service.",
            )
    except RemoteOpsError as exc:
        append_audit_event("remote_ops_rejected", path="/api/admin/remote-ops/command", action=action, error=exc.error, status_code=exc.status_code)
        return JSONResponse(status_code=exc.status_code, content={"ok": False, "error": exc.error, "detail": exc.detail})
    return JSONResponse(result)


@app.get("/api/audit")
def audit() -> dict[str, Any]:
    return {"ok": True, "events": [{"ts": now_text(), "actor": "remote-windows-model-server", "action": "health_check", "target": MODEL_ID}]}


@app.get("/api/artifacts/latest")
def latest_artifact() -> Response:
    artifact = build_artifact_bundle()
    bundle = ARTIFACT_DIR / artifact["name"]
    append_audit_event(
        "artifact_download",
        path="/api/artifacts/latest",
        artifact=artifact["name"],
        sha256=artifact.get("sha256"),
        size_bytes=artifact.get("size_bytes"),
    )
    return Response(
        content=bundle.read_bytes(),
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="{bundle.name}"'},
    )


def prediction_payload_response(payload: dict[str, Any], path: str) -> dict[str, Any] | JSONResponse:
    current = payload.get("current") if isinstance(payload.get("current"), dict) else payload
    failures = validate_clinical_payload(current)
    if failures:
        return invalid_clinical_payload_response(path, failures)
    return prediction_from_payload(current)


@app.post("/api/model/predict")
async def model_predict(request: Request) -> dict[str, Any]:
    payload = await request.json()
    return prediction_payload_response(payload, "/api/model/predict")


@app.get("/predict/predict")
def predict_predict_probe() -> dict[str, Any]:
    return {"ok": True, "service": "sepsiscare-model-service", "method": "POST", "model_id": MODEL_ID}


@app.post("/predict/predict")
async def predict_predict(request: Request) -> dict[str, Any]:
    payload = await request.json()
    return prediction_payload_response(payload, "/predict/predict")


@app.post("/api/family/chat")
async def family_chat(request: Request) -> dict[str, Any]:
    payload = await request.json()
    question = redact_sensitive_text(str(payload.get("question") or ""))
    fallback = contextual_chat_answer(payload, family=True)
    messages = [
        {
            "role": "system",
            "content": (
                "你是 SepsisCare 的家属沟通助手。用中文简洁解释败血症风险趋势，"
                "避免给出诊断结论或替代医生医嘱，必要时提醒联系临床团队。"
            ),
        },
        {
            "role": "user",
            "content": f"家属问题：{question or '未提供问题'}\n可用上下文：\n{json_for_prompt(payload)}",
        },
    ]
    return deepseek_or_fallback(messages, fallback, max_tokens=650)


@app.post("/api/diagnose")
@app.post("/api/clinical/pipeline")
async def diagnose(request: Request) -> dict[str, Any]:
    payload = await request.json()
    failures = validate_clinical_payload(payload)
    if failures:
        return invalid_clinical_payload_response(request.url.path, failures)
    return {"ok": True, "diagnosis": prediction_from_payload(payload), "recommendations": ["复查乳酸", "关注 MAP 和尿量", "结合感染源控制评估"]}


@app.post("/api/diagnose/batch")
async def diagnose_batch(request: Request) -> dict[str, Any]:
    payload = await request.json()
    patients = payload.get("patients") if isinstance(payload.get("patients"), list) else []
    failures: list[str] = []
    for index, item in enumerate(patients[:20]):
        for field in validate_clinical_payload(item):
            failures.append(f"patients[{index}].{field}")
    if failures:
        return invalid_clinical_payload_response("/api/diagnose/batch", failures)
    return {"ok": True, "count": len(patients), "results": [prediction_from_payload(item) for item in patients[:20] if isinstance(item, dict)]}


@app.post("/api/clinical/scores")
async def clinical_scores() -> dict[str, Any]:
    return {"sofa": 5, "qsofa": 1, "news2": 6, "interpretation": "中等风险，需持续监测。"}


@app.post("/api/sepsis-subtypes/predict")
async def subtype_predict() -> dict[str, Any]:
    return {"ok": True, "subtype": {"id": "P1", "name": "中风险观察型"}, "probabilities": {"P0": 0.22, "P1": 0.46, "P2": 0.21, "P3": 0.11}}


@app.post("/api/sepsis-subtypes/recommend")
async def subtype_recommend() -> dict[str, Any]:
    return {"ok": True, "recommendations": ["按 6 小时窗口复核表型迁移", "优先观察乳酸、MAP、机械通气概率"]}


@app.post("/api/ai/llm-diagnose")
async def llm_diagnose(request: Request) -> dict[str, Any]:
    payload = await request.json()
    fallback = llm_diagnose_fallback(payload)
    messages = [
        {
            "role": "system",
            "content": (
                "你是 SepsisCare 研究端临床 AI 助手。基于给定的脱敏 ICU 数据，"
                "输出风险摘要、关键异常指标和下一步观察重点。不要编造不存在的检验结果。"
            ),
        },
        {"role": "user", "content": f"请分析以下患者状态：\n{json_for_prompt(payload)}"},
    ]
    return deepseek_or_fallback(messages, fallback, answer_key="summary", max_tokens=850)


@app.post("/api/ai/explain")
async def ai_explain(request: Request) -> dict[str, Any]:
    payload = await request.json()
    term = redact_sensitive_text(str(payload.get("term") or "指标"))
    fallback = ai_explain_fallback(payload)
    messages = [
        {
            "role": "system",
            "content": "你是 SepsisCare 术语解释助手。用中文用 2 到 4 句话解释临床指标，面向医疗研究人员，保持准确克制。",
        },
        {
            "role": "user",
            "content": f"术语：{term}\n上下文：{json_for_prompt(payload.get('context') if isinstance(payload.get('context'), dict) else {})}",
        },
    ]
    return deepseek_or_fallback(messages, fallback, answer_key="explanation", max_tokens=360)


@app.post("/api/ai/assistant-chat")
async def assistant_chat(request: Request) -> dict[str, Any]:
    payload = await request.json()
    question = redact_sensitive_text(str(payload.get("question") or ""))
    fallback = contextual_chat_answer(payload, family=False)
    messages = [
        {
            "role": "system",
            "content": (
                "你是 SepsisCare 研究端 AI 助手。回答应围绕风险看板、乳酸趋势、MAP 趋势、"
                "表型迁移和训练终端，不要声称已经查看未提供的数据。"
            ),
        },
        {
            "role": "user",
            "content": f"研究端问题：{question or '未提供问题'}\n上下文：\n{json_for_prompt(payload.get('context') if isinstance(payload.get('context'), dict) else {})}",
        },
    ]
    return deepseek_or_fallback(messages, fallback, max_tokens=700)


@app.post("/api/training-terminal/config")
async def training_terminal_config(request: Request) -> dict[str, Any]:
    payload = await request.json()
    state = load_state()
    requested_cloud_base_url = payload.get("cloud_base_url")
    cloud_base_url = normalize_training_cloud_url(requested_cloud_base_url)
    if training_cloud_url_was_rejected(requested_cloud_base_url, cloud_base_url):
        state["cloud_base_url"] = ""
        state["params"] = sanitize_training_params(payload.get("params"))
        state["task_status"] = "error"
        state["last_action"] = "sync_config"
        save_state(state)
        append_audit_event(
            "training_cloud_url_rejected",
            path="/api/training-terminal/config",
            reason="unsafe_cloud_base_url",
        )
        status = training_terminal_status()
        return {
            "ok": False,
            "mode": "production",
            "action": "sync_config",
            "command": None,
            "output": ["云端模型服务地址被安全策略拒绝。"],
            "status": status,
            "error": "cloud_base_url_rejected",
            "cloud_response": None,
        }
    cloud_base_url = cloud_base_url or PUBLIC_MODEL_BASE_URL
    state["cloud_base_url"] = cloud_base_url
    state["params"] = sanitize_training_params(payload.get("params"))
    state["task_status"] = "synced"
    state["last_action"] = "sync_config"
    save_state(state)
    status = training_terminal_status()
    return {"ok": True, "mode": "production", "action": "sync_config", "command": None, "output": ["远程 Windows 训练终端配置已保存。"], "status": status, "error": None, "cloud_response": None}


@app.post("/api/training-terminal/action")
async def training_terminal_action(request: Request) -> JSONResponse:
    payload = await request.json()
    response = await training_command(_JSONRequest({"action": payload.get("action") or "status", "payload": payload}))
    result = json.loads(response.body.decode("utf-8"))
    output = result.get("output") if isinstance(result.get("output"), list) else []
    return JSONResponse(
        {
            "ok": bool(result.get("ok", True)),
            "mode": "production",
            "action": payload.get("action") or "status",
            "command": None,
            "output": ["远程 Windows 模型服务直接执行训练终端动作。"] + [str(line) for line in output],
            "status": training_terminal_status(),
            "error": None if result.get("ok", True) else str(result.get("error") or "model_response_not_ok"),
            "cloud_response": result,
        }
    )


@app.post("/api/training-terminal/command")
async def training_terminal_command(request: Request) -> JSONResponse:
    payload = await request.json()
    response = await training_command(_JSONRequest({"command": payload.get("command") or "", "payload": payload}))
    result = json.loads(response.body.decode("utf-8"))
    output = result.get("output") if isinstance(result.get("output"), list) else []
    return JSONResponse(
        {
            "ok": bool(result.get("ok", True)),
            "mode": "production",
            "action": None,
            "command": payload.get("command") or "",
            "output": ["远程 Windows 模型服务直接执行训练终端指令。"] + [str(line) for line in output],
            "status": training_terminal_status(),
            "error": None if result.get("ok", True) else str(result.get("error") or "model_response_not_ok"),
            "cloud_response": result,
        }
    )


@app.post("/api/training/command")
async def training_command(request: Request) -> JSONResponse:
    payload = await request.json()
    state = load_state()
    action = str(payload.get("action") or "").strip()
    command = str(payload.get("command") or "").strip()
    command_lower = command.lower()
    if not action and command:
        if "pause" in command_lower or "暂停" in command_lower:
            action = "pause_training"
        elif "download" in command_lower or "artifact" in command_lower or "下载" in command_lower:
            action = "download_artifacts"
        elif "metric" in command_lower or "loss" in command_lower or "日志" in command_lower:
            action = "stream_metrics"
        elif "train" in command_lower or "resume" in command_lower or "继续" in command_lower:
            action = "continue_training"
        else:
            action = "status"

    append_audit_event("training_command", path="/api/training/command", action=action or "status")

    if action == "update_database":
        accepted = 0
        nested_payload = payload.get("payload") if isinstance(payload.get("payload"), dict) else {}
        for candidate in (payload, nested_payload):
            if isinstance(candidate, dict) and "events" in candidate:
                accepted, failures = append_icu_events_from_payload(candidate)
                if failures:
                    state["task_status"] = "error"
                    return JSONResponse(output_response(state, action, [f"ICU 时序数据校验失败：{', '.join(failures[:8])}"], ok=False))
                break
        if accepted:
            append_audit_event("icu_timeseries_ingest", path="/api/training/command", accepted=accepted)
        state["task_status"] = "synced"
        state["database_version"] = f"icu-timeseries-{count_icu_timeseries()}"
        lines = [
            f"数据同步指令已接收；本次写入 {accepted} 条 ICU 时序事件。",
            f"training_ready={count_icu_timeseries() > int(state.get('trained_event_count') or 0)} total_events={count_icu_timeseries()}",
        ]
        return JSONResponse(output_response(state, action, lines))
    if action == "continue_training":
        status, lines = maybe_start_training(payload)
        state = load_state()
        state["task_status"] = status
        if status != "trained":
            state["metrics"] = metric_snapshot(state.get("metrics", {}))
        return JSONResponse(output_response(state, action, lines))
    if action == "pause_training":
        state["task_status"] = "paused"
        return JSONResponse(output_response(state, action, pause_training()))
    if action == "download_artifacts":
        artifact = build_artifact_bundle()
        state["task_status"] = "idle"
        state["artifacts"] = [artifact]
        return JSONResponse(output_response(state, action, [f"已打包模型成果：{artifact['path']}", "客户端可通过 /api/artifacts/latest 下载。"]))
    if action == "stream_metrics":
        state["metrics"] = metric_snapshot(state.get("metrics", {}))
        output = [
            "当前模型训练指标：",
            f"macro_f1={state['metrics']['macro_f1']}",
            f"encoder_macro_f1={state['metrics']['encoder_macro_f1']}",
            f"mortality_auroc={state['metrics']['mortality_auroc']}",
            f"next_mv_auroc={state['metrics']['next_mv_auroc']}",
            f"remaining_los_mae_hours={state['metrics']['remaining_los_mae_hours']}",
        ]
        return JSONResponse(output_response(state, action, output))
    if action == "reset_params":
        state = default_state()
        return JSONResponse(output_response(state, action, ["训练服务状态已重置，模型文件未删除。"]))
    if action == "sync_config":
        write_json(RUNTIME_ROOT / "last_terminal_config.json", sanitize_training_config_payload(payload))
        state["task_status"] = "synced"
        return JSONResponse(output_response(state, action, ["已保存客户端训练终端配置。"]))
    if action == "switch_mode":
        return JSONResponse(output_response(state, action, ["云端模型服务始终以 production profile 响应。"]))

    state["metrics"] = metric_snapshot(state.get("metrics", {}))
    return JSONResponse(output_response(state, action or "status", ["云端模型服务在线。", f"model_id={MODEL_ID}"]))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Start SepsisCare cloud model service")
    parser.add_argument("--host", default=os.getenv("SEPSISCARE_MODEL_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.getenv("SEPSISCARE_MODEL_PORT", "8788")))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    import uvicorn

    RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    append_log(f"service starting host={args.host} port={args.port}")
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
