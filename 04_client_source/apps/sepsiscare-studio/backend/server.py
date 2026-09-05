#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lightweight local API for the transferred SepsisCare macOS package.

The original studio backend is not included in this transfer bundle.  The
Swift app already looks for this path during development, so this server keeps
the app runnable from Xcode without requiring extra Python packages.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import io
import ipaddress
import json
import os
import platform
import re
import socket
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request
from urllib.parse import parse_qs, unquote, urlparse


MODEL_ID = "s7_phenotype_contrastive_full_20260516"
SERVER_ROOT = Path(__file__).resolve().parent
WORKSPACE_ROOT = SERVER_ROOT.parents[2]
DEPLOY_ROOT = Path(os.getenv("SEPSISCARE_DEPLOY_ROOT", WORKSPACE_ROOT / "02_model_deploy_package")).resolve()
MODEL_ROOT = DEPLOY_ROOT / "models" / "cloud_production" / MODEL_ID
REPORT_PATH = MODEL_ROOT / "trajectory_encoder_report.json"
RUNTIME_ROOT = Path(os.getenv("SEPSISCARE_RUNTIME_ROOT", WORKSPACE_ROOT / ".sepsiscare-runtime")).resolve()
DEEPSEEK_CONFIG_PATH = RUNTIME_ROOT / "deepseek_config.json"
BINDINGS_PATH = RUNTIME_ROOT / "family_bindings.json"
TRAINING_STATE_PATH = RUNTIME_ROOT / "training_state.json"
TRAINING_LOG_PATH = RUNTIME_ROOT / "training_terminal.log"
ICU_TIMESERIES_PATH = RUNTIME_ROOT / "icu_timeseries.jsonl"
ICU_UPLOAD_STATE_PATH = RUNTIME_ROOT / "icu_upload_state.json"
PUBLIC_API_BASE_URL = os.getenv("SEPSISCARE_PUBLIC_API_BASE_URL", "http://127.0.0.1:8765")
DEFAULT_ROG_MODEL_BASE_URL = "http://100.65.136.96:8788"
LEGACY_LOOPBACK_MODEL_BASE_URLS = {"http://127.0.0.1:8788", "http://localhost:8788"}
_PUBLIC_MODEL_BASE_URL_FROM_ENV = os.getenv("SEPSISCARE_PUBLIC_MODEL_BASE_URL", "").strip().rstrip("/")
PUBLIC_MODEL_BASE_URL = (
    _PUBLIC_MODEL_BASE_URL_FROM_ENV
    if _PUBLIC_MODEL_BASE_URL_FROM_ENV and _PUBLIC_MODEL_BASE_URL_FROM_ENV not in LEGACY_LOOPBACK_MODEL_BASE_URLS
    else DEFAULT_ROG_MODEL_BASE_URL
)
DEFAULT_DEEPSEEK_MODEL = "deepseek-v4-flash"
DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com"
STARTED_AT = time.time()
PUBLIC_RUNTIME_ROOT = "managed-runtime"
AUTH_ENV_NAMES = ("SEPSISCARE_SERVICE_TOKEN", "SEPSISCARE_TRAINING_TOKEN")
AUTH_TOKEN_FILE_ENV_NAMES = ("SEPSISCARE_SERVICE_TOKEN_FILE", "SEPSISCARE_TRAINING_TOKEN_FILE")
AUTH_TOKEN_FILE_NAMES = ("sepsiscare_service_token.txt", "sepsiscare_training_token.txt")
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
TRAINING_SENSITIVE_KEY_FRAGMENTS = (
    "account",
    "address",
    "api_key",
    "apikey",
    "authorization",
    "bearer",
    "bed_no",
    "birth",
    "dob",
    "email",
    "hadm",
    "history_id",
    "masked_id",
    "mrn",
    "name",
    "password",
    "patient_ref",
    "phone",
    "secret",
    "ssn",
    "stay_id",
    "subject",
    "token",
)
TRAINING_PAYLOAD_REDACTION = "[redacted]"
TRAINING_PAYLOAD_MAX_DEPTH = 8
TRAINING_PAYLOAD_MAX_LIST_ITEMS = 50
MIN_SERVICE_TOKEN_CHARS = 16
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
    "/api/bedside",
    "/api/clinical",
    "/api/config",
    "/api/diagnose",
    "/api/family",
    "/api/history",
    "/api/icu",
    "/api/model/predict",
    "/api/monitor",
    "/api/patients",
    "/api/sepsis-subtypes",
    "/api/training",
)
BODY_LIMIT_BYTES = int(os.getenv("SEPSISCARE_MAX_JSON_BODY_BYTES", str(1024 * 1024)))
PRIVATE_FILE_MODE = 0o600
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
TEXT_REDACTION_MAX_CHARS = 1000
TEXT_REDACTION_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE), "[redacted-email]"),
    (re.compile(r"\b(?:MRN|HADM|SUBJECT|ID)\s*[:#-]?\s*[A-Z0-9-]{3,}\b", re.IGNORECASE), "[redacted-mrn]"),
    (re.compile(r"\bSSN\s*[:#-]?\s*\d{3}-?\d{2}-?\d{4}\b", re.IGNORECASE), "[redacted-ssn]"),
    (re.compile(r"\b(?:DOB|DATE OF BIRTH|BIRTHDATE)\s*[:#-]?\s*\d{1,4}[/-]\d{1,2}[/-]\d{1,4}\b", re.IGNORECASE), "[redacted-dob]"),
    (re.compile(r"\b(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b"), "[redacted-phone]"),
    (re.compile(r"\b(?:SC|HX|TS|EICU|HICU|ARCH)-\d+\b", re.IGNORECASE), "[redacted-patient-ref]"),
    (re.compile(r"\bICU-\d{1,4}\b", re.IGNORECASE), "[redacted-bed]"),
]


class RequestBodyTooLarge(ValueError):
    pass


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


def configured_service_token() -> str:
    for name in AUTH_ENV_NAMES:
        value = os.getenv(name, "").strip()
        if value:
            return value
    token_envs_explicitly_empty = all(name in os.environ and not os.getenv(name, "").strip() for name in AUTH_ENV_NAMES)
    token_file_env_configured = any(os.getenv(name, "").strip() for name in AUTH_TOKEN_FILE_ENV_NAMES)
    if token_envs_explicitly_empty and not token_file_env_configured:
        return ""
    if os.getenv("SEPSISCARE_DISABLE_TOKEN_FILE_LOOKUP", "").strip().lower() in {"1", "true", "yes"}:
        return ""
    for path in service_token_file_candidates():
        try:
            value = path.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    return ""


def service_token_file_candidates() -> list[Path]:
    candidates: list[Path] = []
    for name in AUTH_TOKEN_FILE_ENV_NAMES:
        raw_path = os.getenv(name, "").strip()
        if raw_path:
            candidates.append(Path(raw_path).expanduser())
    for filename in AUTH_TOKEN_FILE_NAMES:
        candidates.append(RUNTIME_ROOT / filename)
    app_support = Path.home() / "Library" / "Application Support" / "SepsisCare"
    for filename in AUTH_TOKEN_FILE_NAMES:
        candidates.append(app_support / filename)

    seen: set[str] = set()
    result: list[Path] = []
    for candidate in candidates:
        key = str(candidate)
        if key not in seen:
            seen.add(key)
            result.append(candidate)
    return result


def service_token_is_weak(token: str) -> bool:
    normalized = str(token or "").strip()
    if not normalized:
        return False
    compact = re.sub(r"[\s_-]+", "", normalized).lower()
    return len(normalized) < MIN_SERVICE_TOKEN_CHARS or compact in WEAK_SERVICE_TOKEN_VALUES


def header_value(headers: Any, key: str) -> str:
    try:
        value = headers.get(key, "")
    except AttributeError:
        value = ""
    return str(value or "").strip()


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
    authorization = header_value(headers, "Authorization")
    if not authorization.lower().startswith("bearer "):
        return ""
    return authorization[7:].strip()


def security_failure_for_request(method: str, path: str, headers: Any, client_host: str) -> tuple[int, dict[str, Any]] | None:
    if method == "OPTIONS" or not path_is_sensitive(path):
        return None
    token = configured_service_token()
    remote_client = not client_host_is_loopback(client_host)
    if remote_client and not token:
        return 403, {
            "error": "remote_auth_not_configured",
            "detail": "Sensitive SepsisCare endpoints require SEPSISCARE_SERVICE_TOKEN before accepting remote clients.",
        }
    if remote_client and service_token_is_weak(token):
        return 403, {
            "error": "weak_auth_token_configured",
            "detail": "Remote sensitive endpoints require a non-placeholder bearer token of at least 16 characters.",
        }
    if not token:
        return None
    if hmac.compare_digest(bearer_token_from_headers(headers), token):
        return None
    return 401, {"error": "authorization_required", "detail": "Missing or invalid bearer token."}


def local_cpu_status() -> dict[str, Any]:
    try:
        load_1m, load_5m, load_15m = os.getloadavg()
    except (AttributeError, OSError):
        load_1m, load_5m, load_15m = 0.0, 0.0, 0.0
    cores = os.cpu_count() or 1
    return {
        "cores": cores,
        "load_1m": load_1m,
        "load_5m": load_5m,
        "load_15m": load_15m,
        "estimated_usage_percent": round(min(100.0, max(0.0, (load_1m / max(1, cores)) * 100.0)), 2),
    }


def unreported_remote_cpu_status() -> dict[str, Any]:
    return {
        "cores": 0,
        "load_1m": 0.0,
        "load_5m": 0.0,
        "load_15m": 0.0,
        "estimated_usage_percent": 0.0,
    }


def gpu_status_from_runtime_device(runtime_device: Any) -> dict[str, Any]:
    device = str(runtime_device or "").strip()
    lowered = device.lower()
    available = any(marker in lowered for marker in ("cuda", "gpu", "mps"))
    if "cuda" in lowered:
        name = "CUDA remote GPU"
    elif "mps" in lowered:
        name = "Apple MPS"
    elif available:
        name = "Remote GPU"
    else:
        name = "Not detected"
    return {
        "available": available,
        "name": name,
        "utilization_percent": None,
        "memory_used_mb": None,
        "memory_total_mb": None,
    }


def local_admin_status_payload() -> dict[str, Any]:
    return {
        "service": {
            "name": "SepsisCare local transfer backend",
            "status": "online",
            "uptime_hint": f"{int(time.time() - STARTED_AT)}s",
            "python": sys.version.split()[0],
            "platform": platform.system(),
        },
        "backend": {
            "runtime_device": "cpu",
            "llm_provider": "deepseek",
            "llm_configured": deepseek_config()["configured"],
            "deepseek_model": deepseek_config()["model"],
        },
        "device": {
            "cpu": local_cpu_status(),
            "gpu": gpu_status_from_runtime_device("cpu"),
        },
    }


def cloud_base_url_is_self_reference(base_url: str) -> bool:
    try:
        parsed = urlparse(base_url)
    except ValueError:
        return True
    host = (parsed.hostname or "").strip().lower()
    try:
        port = int(parsed.port or (443 if parsed.scheme == "https" else 80))
    except ValueError:
        port = 0
    public = urlparse(PUBLIC_API_BASE_URL)
    public_host = (public.hostname or "").strip().lower()
    public_port = int(public.port or (443 if public.scheme == "https" else 80))
    return host in {"127.0.0.1", "localhost", "::1"} and port == public_port and public_host in {"127.0.0.1", "localhost", "::1"}


def remote_admin_status_payload(base_url: str) -> dict[str, Any] | None:
    if cloud_base_url_is_self_reference(base_url):
        return None
    headers: dict[str, str] = {}
    token = configured_service_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    endpoint = f"{base_url.rstrip('/')}/api/admin/status"
    request = urllib_request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib_request.urlopen(request, timeout=float(os.getenv("SEPSISCARE_ADMIN_STATUS_TIMEOUT_SECONDS", "6"))) as response:
            result = json.loads(response.read().decode("utf-8") or "{}")
    except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        append_training_log("admin_status", f"远端管理员状态读取失败：{str(exc)[:180]}", level="error")
        return None
    if not isinstance(result, dict):
        return None
    return normalize_remote_admin_status(result, base_url)


def remote_deployment_config_payload(base_url: str) -> dict[str, Any] | None:
    if cloud_base_url_is_self_reference(base_url):
        return None
    headers: dict[str, str] = {}
    token = configured_service_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    endpoint = f"{base_url.rstrip('/')}/api/deployment/config"
    request = urllib_request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib_request.urlopen(request, timeout=float(os.getenv("SEPSISCARE_ADMIN_STATUS_TIMEOUT_SECONDS", "6"))) as response:
            result = json.loads(response.read().decode("utf-8") or "{}")
    except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
        append_training_log("deployment_config", f"远端部署状态读取失败：{str(exc)[:180]}", level="error")
        return None
    return result if isinstance(result, dict) else None


def normalize_remote_admin_status(result: dict[str, Any], base_url: str) -> dict[str, Any]:
    service_raw = result.get("service") if isinstance(result.get("service"), dict) else {}
    backend_raw = result.get("backend") if isinstance(result.get("backend"), dict) else {}
    device_raw = result.get("device") if isinstance(result.get("device"), dict) else {}
    runtime_device = str(
        backend_raw.get("runtime_device")
        or result.get("device")
        or result.get("device_resolved")
        or "cpu"
    )
    service_name = (
        service_raw.get("name")
        if isinstance(service_raw, dict)
        else result.get("service")
    )
    backend_status = result.get("backend") if isinstance(result.get("backend"), str) else service_raw.get("status")
    return {
        "service": {
            "name": str(service_name or "sepsiscare-remote-windows-model-server"),
            "status": str(backend_status or result.get("status") or "online"),
            "uptime_hint": str(service_raw.get("uptime_hint") or f"remote {base_url}"),
            "python": str(service_raw.get("python") or "--"),
            "platform": str(service_raw.get("platform") or "Windows"),
        },
        "backend": {
            "runtime_device": runtime_device,
            "llm_provider": str(backend_raw.get("llm_provider") or result.get("llm_provider") or "deepseek"),
            "llm_configured": bool(backend_raw.get("llm_configured", result.get("llm_configured", False))),
            "deepseek_model": str(backend_raw.get("deepseek_model") or result.get("deepseek_model") or result.get("llm_model") or DEFAULT_DEEPSEEK_MODEL),
        },
        "device": {
            "cpu": device_raw.get("cpu") if isinstance(device_raw.get("cpu"), dict) else unreported_remote_cpu_status(),
            "gpu": device_raw.get("gpu") if isinstance(device_raw.get("gpu"), dict) else gpu_status_from_runtime_device(runtime_device),
        },
    }


def admin_status_payload() -> dict[str, Any]:
    status = training_status()
    cloud_base_url = effective_training_cloud_base_url(status.get("cloud_base_url"))
    if cloud_base_url:
        remote = remote_admin_status_payload(cloud_base_url)
        if remote:
            return remote
    return local_admin_status_payload()


def deployment_config_payload() -> dict[str, Any]:
    cloud_base_url = effective_training_cloud_base_url(training_status().get("cloud_base_url"))
    if cloud_base_url:
        remote = remote_deployment_config_payload(cloud_base_url)
        if remote:
            return remote
    return {
        "backend_mode": "transfer-local",
        "api_base_url": PUBLIC_API_BASE_URL,
        "device_requested": os.getenv("SEPSISCARE_DEVICE", "cpu"),
        "device_resolved": "cpu",
        "llm_configured": deepseek_config()["configured"],
        "llm_provider": "deepseek",
        "llm_model": deepseek_config()["model"],
        "deidentification": "demo-masked",
        "model_release": MODEL_ID,
        "interfaces": ["research", "family", "admin", "training-terminal"],
    }


def append_training_log(action: str, message: str, level: str = "info") -> None:
    TRAINING_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {"ts": now_text(), "level": level, "source": "local", "action": action, "message": message}
    with TRAINING_LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
    ensure_private_file(TRAINING_LOG_PATH)


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


def invalid_clinical_payload_response(path: str, fields: list[str]) -> tuple[int, dict[str, Any]]:
    append_audit_event("data_validation_failure", path=path, status_code=422, fields=fields[:20])
    return (
        422,
        {
            "error": "invalid_clinical_payload",
            "detail": "Clinical numeric payload contains non-numeric or out-of-range values.",
            "fields": fields,
        },
    )


def diagnose_feature_schema() -> dict[str, Any]:
    feature_groups: dict[str, list[str]] = {"vitals": [], "labs": []}
    numeric_ranges: dict[str, dict[str, float]] = {}
    for field, (minimum, maximum) in CLINICAL_NUMERIC_RANGES.items():
        section, key = field.split(".", 1)
        feature_groups.setdefault(section, []).append(key)
        numeric_ranges[field] = {"min": minimum, "max": maximum}
    return {
        "ok": True,
        "model_id": MODEL_ID,
        "feature_groups": {key: sorted(values) for key, values in feature_groups.items()},
        "numeric_ranges": numeric_ranges,
        "payload_schema": {
            "required_sections": ["vitals", "labs"],
            "optional_fields": ["age", "sex", "icu_type"],
            "endpoints": ["/api/diagnose", "/api/diagnose/batch", "/api/model/predict"],
        },
        "source": "local-transfer-backend",
    }


def redact_sensitive_text(value: Any) -> str:
    text = str(value or "")[:TEXT_REDACTION_MAX_CHARS]
    for pattern, replacement in TEXT_REDACTION_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def training_key_is_sensitive(key: Any) -> bool:
    lowered = str(key or "").lower()
    return any(fragment in lowered for fragment in TRAINING_SENSITIVE_KEY_FRAGMENTS)


def sanitize_training_value(value: Any, depth: int = 0) -> Any:
    if depth > TRAINING_PAYLOAD_MAX_DEPTH:
        return "...<truncated>"
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, item in value.items():
            text_key = str(key)
            if training_key_is_sensitive(text_key):
                sanitized[text_key] = TRAINING_PAYLOAD_REDACTION
            else:
                sanitized[text_key] = sanitize_training_value(item, depth + 1)
        return sanitized
    if isinstance(value, (list, tuple)):
        rows = [sanitize_training_value(item, depth + 1) for item in value[:TRAINING_PAYLOAD_MAX_LIST_ITEMS]]
        if len(value) > TRAINING_PAYLOAD_MAX_LIST_ITEMS:
            rows.append("...<truncated>")
        return rows
    if isinstance(value, str):
        return redact_sensitive_text(value)
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return redact_sensitive_text(value)


def sanitize_training_params(params: Any) -> dict[str, Any]:
    if not isinstance(params, dict):
        return {}
    return {
        key: sanitize_training_value(value)
        for key, value in params.items()
        if key in TRAINING_PARAM_PUBLIC_KEYS and not training_key_is_sensitive(key)
    }


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
    source = redact_sensitive_text(payload.get("source") or "hospital-icu-interface")
    events: list[dict[str, Any]] = []
    failures: list[str] = []
    for index, item in enumerate(candidates[:500]):
        validation_failures = validate_clinical_payload(item)
        if validation_failures:
            failures.extend(f"events[{index}].{field}" for field in validation_failures)
            continue
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
            "record_id": f"icu-{int(time.time() * 1000)}-{index}-{patient_key[:8]}",
            "received_at": now_text(),
            "timestamp": redact_sensitive_text(item.get("timestamp") or now_text()),
            "source": source,
            "patient_key": patient_key,
            "bed_hash": short_hash(item.get("bed_no")),
            "ward": redact_sensitive_text(item.get("ward") or item.get("icu_ward") or ""),
            "vitals": numeric_section(item, "vitals"),
            "labs": numeric_section(item, "labs"),
            "device": {
                "vendor": redact_sensitive_text(device.get("vendor") or ""),
                "model": redact_sensitive_text(device.get("model") or ""),
                "serial_hash": short_hash(device.get("serial")),
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


def read_icu_timeseries(limit: int = 200) -> list[dict[str, Any]]:
    if not ICU_TIMESERIES_PATH.exists():
        return []
    try:
        limit = max(1, min(int(limit), 2000))
    except (TypeError, ValueError):
        limit = 200
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


def icu_realtime_status() -> dict[str, Any]:
    rows = read_icu_timeseries(1)
    return {
        "ok": True,
        "storage": public_runtime_path("icu_timeseries.jsonl"),
        "total_events": count_icu_timeseries(),
        "last_event": rows[-1] if rows else None,
        "upload": read_json(ICU_UPLOAD_STATE_PATH, {}),
    }


def demo_icu_event() -> dict[str, Any]:
    return {
        "source": "hospital-icu-monitor-demo",
        "events": [
            {
                "patient_ref": "DEMO-ICU-001",
                "bed_no": "ICU-01",
                "timestamp": now_text(),
                "ward": "综合 ICU",
                "vitals": {"heart_rate": 112, "map": 64, "resp_rate": 26, "spo2": 92, "temperature": 38.4, "gcs": 13},
                "labs": {"lactate": 3.4, "wbc": 16.2, "creatinine": 1.4, "platelet": 142},
                "device": {"vendor": "demo-monitor", "model": "ICU-Link"},
            }
        ],
    }


def sanitize_cloud_url(value: Any) -> str:
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


def effective_training_cloud_base_url(value: Any) -> str:
    normalized = sanitize_cloud_url(value)
    if not normalized:
        return PUBLIC_MODEL_BASE_URL
    if normalized.rstrip("/") in LEGACY_LOOPBACK_MODEL_BASE_URLS:
        return PUBLIC_MODEL_BASE_URL
    return normalized


def normalize_deepseek_base_url(value: Any) -> str:
    text = str(value or "").strip().rstrip("/")
    default = DEFAULT_DEEPSEEK_BASE_URL
    if not text:
        return default
    parsed = urlparse(text)
    if not deepseek_base_url_is_allowed(parsed):
        return default
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


def metric_snapshot() -> dict[str, Any]:
    metrics = {
        "macro_f1": 0.9562308594924265,
        "encoder_macro_f1": 0.9709154883540718,
        "encoder_transition_macro_f1": 0.9562308594924265,
        "mortality_auroc": 0.8484669929243582,
        "next_mv_auroc": 0.9684646706192623,
        "remaining_los_mae_hours": 2.9549930095672607,
        "total_train_patients": 347634,
        "data_parallel_gpus": 7,
        "epoch": 8,
        "progress": 100,
    }
    report = read_json(REPORT_PATH, {})
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
    return metrics


def phenotype_for_score(score: float) -> tuple[int, str]:
    if score >= 0.72:
        return 3, "P3 炎症风暴型"
    if score >= 0.48:
        return 2, "P2 高危进展型"
    if score >= 0.24:
        return 1, "P1 中风险观察型"
    return 0, "P0 低危稳定型"


def consistency_for_index(index: int) -> dict[str, Any]:
    choices = [
        ("L5 完全一致", "stable", 5, 5, 1.0),
        ("L4 大部分一致", "good", 4, 5, 0.8),
        ("L3 中等一致", "watch", 3, 5, 0.6),
        ("L2 大部分不一致", "warning", 2, 5, 0.4),
        ("L1 完全不一致", "critical", 1, 5, 0.2),
    ]
    label, tone, match_count, total_windows, match_rate = choices[index % len(choices)]
    return {
        "label": label,
        "tone": tone,
        "match_count": match_count,
        "total_windows": total_windows,
        "match_rate": match_rate,
    }


def make_patient(index: int) -> dict[str, Any]:
    severity = index % 5
    wave = float((index * 37) % 11) - 5.0
    age = 42 + (index * 7) % 43
    heart_rate = 82.0 + severity * 8.0 + wave
    sbp = 122.0 - severity * 8.0 + wave
    dbp = 70.0 - severity * 4.0
    mean_pressure = round((sbp + 2.0 * dbp) / 3.0, 1)
    lactate = round(1.2 + severity * 0.72 + max(wave, 0.0) * 0.08, 2)
    score = min(0.95, max(0.05, severity * 0.19 + max(lactate - 2.0, 0.0) * 0.08))
    phenotype, phenotype_name = phenotype_for_score(score)
    wards = ["心内ICU", "外科ICU", "内科ICU", "综合ICU"]
    patient_id = 12000 + index * 17
    risk_level = "red" if score >= 0.72 else "orange" if score >= 0.48 else "yellow" if score >= 0.24 else "green"
    return {
        "patient_id": patient_id,
        "masked_id": f"SC-{patient_id:05d}",
        "bed_no": f"ICU-{index + 1:02d}",
        "admission_time": f"2024-{index % 12 + 1:02d}-{index % 28 + 1:02d}",
        "icu_ward": wards[index % len(wards)],
        "risk_level": risk_level,
        "risk_score": round(score, 3),
        "phenotype": phenotype,
        "phenotype_name": phenotype_name,
        "vitals_summary": f"HR:{heart_rate:.0f}/MAP:{mean_pressure:.0f}/Lac:{lactate:.1f}",
        "last_prediction": f"{index % 6 + 1}小时前",
        "age_group": "40-60岁" if age < 60 else "60岁以上",
        "age": age,
        "sex": "男" if index % 2 == 0 else "女",
        "mortality_flag": 1 if severity >= 4 else 0,
        "los_hours": round(24.0 + severity * 18.0 + index % 8, 1),
        "prediction_consistency": consistency_for_index(index),
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


PATIENTS = [make_patient(index) for index in range(50)]


def prediction_from_payload(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = payload or {}
    vitals = payload.get("vitals", {}) if isinstance(payload.get("vitals"), dict) else {}
    labs = payload.get("labs", {}) if isinstance(payload.get("labs"), dict) else {}
    mean_pressure = float(vitals.get("map", 72.0) or 72.0)
    lactate = float(labs.get("lactate", 2.1) or 2.1)
    score = min(0.92, max(0.04, (70.0 - min(mean_pressure, 70.0)) * 0.012 + lactate * 0.055))
    phenotype_id = "P3" if score >= 0.35 else "P1"
    phenotype_name = "炎症风暴型" if phenotype_id == "P3" else "相对稳定型"
    latest = {
        "phenotype": {
            "id": phenotype_id,
            "name": phenotype_name,
            "family_label": "需要密切观察" if phenotype_id == "P3" else "总体平稳",
            "description": "基于迁移包本地后端的部署推理结果。",
        },
        "mortality_probability": round(score, 3),
        "next_mech_vent_probability": round(min(0.9, score + 0.22), 3),
        "remaining_los_hours": round(36.0 + score * 90.0, 1),
    }
    trajectory = [
        {
            "window": 1,
            "start_hour": 0,
            "phenotype": {"id": "P1", "name": "相对稳定型", "family_label": "稳定", "description": ""},
            "probabilities": {"P1": 0.70, "P2": 0.20, "P3": 0.10},
        },
        {
            "window": 2,
            "start_hour": 6,
            "phenotype": {"id": "P2", "name": "炎症进展型", "family_label": "观察", "description": ""},
            "probabilities": {"P1": 0.30, "P2": 0.50, "P3": 0.20},
        },
        {
            "window": 3,
            "start_hour": 12,
            "phenotype": {"id": phenotype_id, "name": phenotype_name, "family_label": "重点关注", "description": ""},
            "probabilities": {"P1": round(max(0.05, 0.55 - score), 3), "P2": 0.30, "P3": round(min(0.85, 0.15 + score), 3)},
        },
    ]
    return {"latest": latest, "risk_level": "critical" if score >= 0.35 else "stable", "trajectory": trajectory}


def training_status() -> dict[str, Any]:
    state = read_json(TRAINING_STATE_PATH, {})
    if not isinstance(state, dict):
        state = {}
    metrics = metric_snapshot()
    if (
        "cloud_base_url" in state
        and not str(state.get("cloud_base_url") or "").strip()
        and state.get("task_status") == "error"
    ):
        cloud_base_url = ""
    else:
        cloud_base_url = effective_training_cloud_base_url(state.get("cloud_base_url"))
    defaults = {
        "ok": True,
        "version": "1.0.1",
        "mode": state.get("mode", "production"),
        "mode_label": "生产模型演示",
        "model_profile": MODEL_ID,
        "task_status": state.get("task_status", "idle"),
        "cloud_base_url": cloud_base_url,
        "cloud_ready": True,
        "last_action": state.get("last_action", "status"),
        "updated_at": state.get("updated_at", now_text()),
        "params": state.get("params", {}),
        "metrics": {
            "macro_f1": metrics["macro_f1"],
            "encoder_macro_f1": metrics["encoder_macro_f1"],
            "mortality_auroc": metrics["mortality_auroc"],
            "next_mv_auroc": metrics["next_mv_auroc"],
            "remaining_los_mae_hours": metrics["remaining_los_mae_hours"],
            "total_train_patients": metrics["total_train_patients"],
        },
        "artifacts": state.get("artifacts", []),
        "actions": [
            {"action": "continue_training", "title": "继续训练", "shortcut": "train"},
            {"action": "pause_training", "title": "暂停训练", "shortcut": "pause"},
            {"action": "stream_metrics", "title": "刷新指标", "shortcut": "metrics"},
            {"action": "download_artifacts", "title": "打包成果", "shortcut": "download"},
        ],
        "notice": "迁移包本地后端：返回已打包 S7 模型指标，不自动发起昂贵训练。",
    }
    return defaults


def training_config_response(status: dict[str, Any], ok: bool, output: list[str], error: str | None = None) -> dict[str, Any]:
    response = dict(status)
    response.update(
        {
            "ok": ok,
            "mode": status["mode"],
            "action": "sync_config",
            "command": None,
            "output": output,
            "status": status,
            "error": error,
            "cloud_response": None,
        }
    )
    return response


def patient_for_chat(patient_ref: Any) -> dict[str, Any]:
    ref = str(patient_ref or "").strip()
    if ref and patient_ref_is_allowed(ref):
        return next((item for item in PATIENTS if item.get("masked_id") == ref or item.get("bed_no") == ref), PATIENTS[0])
    return PATIENTS[0]


def chat_context(patient_ref: Any = "") -> dict[str, Any]:
    patient = patient_for_chat(patient_ref)
    return {
        "patient": {
            "masked_id": patient.get("masked_id"),
            "bed_no": patient.get("bed_no"),
            "icu_ward": patient.get("icu_ward"),
            "risk_level": patient.get("risk_level"),
            "risk_score": patient.get("risk_score"),
            "phenotype_name": patient.get("phenotype_name"),
            "vitals": patient.get("vitals", {}),
            "labs": patient.get("labs", {}),
        },
        "prediction": prediction_from_payload(patient),
        "training_status": training_status(),
        "model": {"model_id": MODEL_ID, "metrics": metric_snapshot()},
    }


def local_chat_answer(question: str, context: dict[str, Any], *, family: bool) -> dict[str, Any]:
    patient = context.get("patient") if isinstance(context.get("patient"), dict) else {}
    vitals = patient.get("vitals") if isinstance(patient.get("vitals"), dict) else {}
    labs = patient.get("labs") if isinstance(patient.get("labs"), dict) else {}
    status = context.get("training_status") if isinstance(context.get("training_status"), dict) else {}
    metrics = status.get("metrics") if isinstance(status.get("metrics"), dict) else {}
    patient_id = str(patient.get("masked_id") or "当前患者")
    lactate = labs.get("lactate", "--")
    mean_pressure = vitals.get("map", "--")
    phenotype = str(patient.get("phenotype_name") or "--")
    if family:
        answer = (
            f"已基于绑定患者 {patient_id} 的脱敏监护数据生成说明：当前乳酸 {lactate} mmol/L，"
            f"MAP {mean_pressure} mmHg，模型表型为 {phenotype}。这些信息用于帮助理解趋势，"
            "不能替代主管医生解释；若乳酸继续升高或血压下降，应及时向 ICU 医护确认。"
        )
    else:
        answer = (
            f"已读取 {patient_id} 的当前风险上下文和训练终端状态。乳酸={lactate} mmol/L，"
            f"MAP={mean_pressure} mmHg，表型={phenotype}；训练状态={status.get('task_status', '--')}，"
            f"macro_f1={metrics.get('macro_f1', '--')}，total_train_patients={metrics.get('total_train_patients', '--')}。"
            f"问题摘要：{question or '未提供问题'}"
        )
    return {"answer": answer, "source": "local-transfer-backend-contextual"}


def ai_request_context(body: dict[str, Any] | None = None) -> dict[str, Any]:
    body = body or {}
    patient_ref = str(body.get("patient_ref") or body.get("masked_id") or "").strip()
    context = chat_context(patient_ref)
    client_context = body.get("context")
    if isinstance(client_context, dict):
        context["client_context"] = sanitize_training_value(client_context)
    elif client_context:
        context["client_context"] = {"text": redact_sensitive_text(client_context)}
    return context


def local_ai_analysis() -> dict[str, Any]:
    status = training_status()
    metrics = status.get("metrics") if isinstance(status.get("metrics"), dict) else metric_snapshot()
    llm = deepseek_config()
    high_risk = sum(1 for item in PATIENTS if item.get("risk_score", 0) >= 0.48)
    return {
        "ok": True,
        "summary": (
            f"本地迁移后端已读取模型指标与 ICU 队列：患者={len(PATIENTS)}，高风险={high_risk}，"
            f"训练状态={status.get('task_status', '--')}，macro_f1={metrics.get('macro_f1', '--')}，"
            f"encoder_macro_f1={metrics.get('encoder_macro_f1', '--')}，"
            f"DeepSeek={'已配置' if llm.get('configured') else 'Fallback'}。"
        ),
        "model_id": MODEL_ID,
        "metrics": metrics,
        "training_status": {
            "task_status": status.get("task_status"),
            "last_action": status.get("last_action"),
            "cloud_base_url": status.get("cloud_base_url"),
        },
        "llm": {
            "provider": llm.get("provider"),
            "configured": llm.get("configured"),
            "model": llm.get("model"),
        },
        "source": "local-transfer-backend-contextual",
    }


def remote_ai_analysis_is_placeholder(result: dict[str, Any]) -> bool:
    summary = str(result.get("summary") or result.get("answer") or "").strip()
    if not summary:
        return True
    placeholder_snippets = (
        "远程 Windows 模型服务在线",
        "远程 Windows 模型服务已接受",
        "当前返回部署模型指标和内置患者数据库分析",
    )
    return any(snippet in summary for snippet in placeholder_snippets)


def local_llm_diagnosis(body: dict[str, Any]) -> dict[str, Any]:
    context = ai_request_context(body)
    patient = context.get("patient") if isinstance(context.get("patient"), dict) else {}
    vitals = patient.get("vitals") if isinstance(patient.get("vitals"), dict) else {}
    labs = patient.get("labs") if isinstance(patient.get("labs"), dict) else {}
    prediction = context.get("prediction") if isinstance(context.get("prediction"), dict) else prediction_from_payload(body)
    latest = prediction.get("latest") if isinstance(prediction.get("latest"), dict) else {}
    return {
        "ok": True,
        "summary": (
            f"已基于脱敏 ICU 上下文生成本地诊断摘要：患者={patient.get('masked_id', body.get('masked_id', '当前患者'))}，"
            f"乳酸={labs.get('lactate', body.get('lactate', '--'))} mmol/L，MAP={vitals.get('map', body.get('mean_arterial_pressure', '--'))} mmHg，"
            f"风险={prediction.get('risk_level', '--')}，死亡风险={latest.get('mortality_probability', '--')}。"
        ),
        "diagnosis": prediction,
        "context": context,
        "source": "local-transfer-backend-contextual",
    }


def local_ai_explanation(body: dict[str, Any]) -> dict[str, Any]:
    term = redact_sensitive_text(body.get("term") or "指标")
    context = ai_request_context(body)
    return {
        "term": term,
        "explanation": (
            f"{term} 是 SepsisCare 风险解释中的参考指标。当前解释已附带训练终端状态 "
            f"{context.get('training_status', {}).get('task_status', '--')} 与模型指标，"
            "用于研究端核对风险看板和时序趋势。"
        ),
        "context": context,
        "source": "local-transfer-backend-contextual",
    }


def update_training_state(**changes: Any) -> dict[str, Any]:
    status = training_status()
    status.update(changes)
    status["params"] = sanitize_training_params(status.get("params"))
    status["updated_at"] = now_text()
    write_json(
        TRAINING_STATE_PATH,
        {
            "mode": status["mode"],
            "task_status": status["task_status"],
            "cloud_base_url": status["cloud_base_url"],
            "last_action": status["last_action"],
            "updated_at": status["updated_at"],
            "params": status["params"],
            "artifacts": status["artifacts"],
        },
    )
    return status


def historical_summary(index: int) -> dict[str, Any]:
    consistency = [
        {"code": "exact", "label": "完全一致", "color": "green"},
        {"code": "mostly", "label": "大部分一致", "color": "blue"},
        {"code": "average", "label": "中等一致", "color": "yellow"},
    ]
    sources = ["MIMIC-IV", "eICU", "PhysioNet 2019", "PhysioNet 2012"]
    history_id = f"HICU-{700000 + index:06d}"
    return {
        "history_id": history_id,
        "masked_id": f"HX-{700000 + index:06d}",
        "data_source": sources[index % len(sources)],
        "center": "BIDMC" if index % 2 == 0 else "Multi-center",
        "icu_type": ["心内ICU", "外科ICU", "内科ICU", "综合ICU"][index % 4],
        "quality_tag": "高质量" if index % 3 else "可用",
        "icu_admit_time": f"2023-{index % 12 + 1:02d}-01 08:00",
        "icu_discharge_time": f"2023-{index % 12 + 1:02d}-04 14:00",
        "los_hours": round(48.0 + (index % 20) * 3.5, 1),
        "outcome": "出院存活" if index % 5 else "院内死亡",
        "primary_phenotype": ["P0 低危稳定型", "P1 中风险观察型", "P2 高危进展型", "P3 炎症风暴型"][index % 4],
        "phenotype_consistency": consistency[index % len(consistency)],
        "parameter_consistency": consistency[(index + 1) % len(consistency)],
        "missing_rate": round((index % 8) * 0.01, 3),
        "available_prediction_windows": 8 + index % 7,
        "model_version": "S7-contrastive-20260516",
        "favorite": index % 9 == 0,
        "annotation_status": "已标注" if index % 4 == 0 else "未标注",
    }


HISTORICAL_PATIENTS = [historical_summary(index) for index in range(120)]


def first_query_value(query: dict[str, list[str]], *names: str, default: str = "") -> str:
    for name in names:
        values = query.get(name)
        if values:
            value = str(values[0]).strip()
            if value:
                return value
    return default


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


def filtered_history_rows(query: dict[str, list[str]]) -> list[dict[str, Any]]:
    rows = list(HISTORICAL_PATIENTS)
    search = first_query_value(query, "search", "query", "patient_id").lower()
    if search:
        rows = [item for item in rows if search in history_field_text(item)]

    source = first_query_value(query, "source", "data_source", "dataset", default="all")
    if source != "all":
        source_token = normalized_history_token(source)
        rows = [item for item in rows if normalized_history_token(item.get("data_source")) == source_token]

    icu_type = first_query_value(query, "icu_type", "icu", default="all")
    if icu_type != "all":
        rows = [item for item in rows if str(item.get("icu_type")) == icu_type]

    outcome = first_query_value(query, "outcome", default="all")
    if outcome != "all":
        rows = [item for item in rows if str(item.get("outcome")) == outcome]

    phenotype = first_query_value(query, "phenotype", default="all")
    if phenotype != "all":
        rows = [item for item in rows if phenotype in str(item.get("primary_phenotype", ""))]

    consistency = first_query_value(query, "consistency", default="all")
    if consistency != "all":
        rows = [
            item for item in rows
            if item.get("phenotype_consistency", {}).get("code") == consistency
            or item.get("parameter_consistency", {}).get("code") == consistency
        ]

    sort = first_query_value(query, "sort", default="los_desc")
    if sort == "missing_desc":
        return sorted(rows, key=lambda item: float(item.get("missing_rate", 0) or 0), reverse=True)
    if sort == "inconsistency_desc":
        return sorted(rows, key=history_inconsistency_rank, reverse=True)
    if sort == "discharge_desc":
        return sorted(rows, key=lambda item: str(item.get("icu_discharge_time", "")), reverse=True)
    return sorted(rows, key=lambda item: float(item.get("los_hours", 0) or 0), reverse=sort == "los_desc")


def historical_detail(history_id: str) -> dict[str, Any]:
    patient = next((item for item in HISTORICAL_PATIENTS if item["history_id"] == history_id), HISTORICAL_PATIENTS[0])
    points = []
    for minute in range(0, 721, 60):
        actual = 86.0 + minute / 180.0
        predicted = actual + (minute % 180) / 100.0
        points.append(
            {
                "minute": minute,
                "actual": round(actual, 2) if minute % 240 else None,
                "predicted": round(predicted, 2),
                "smoothed_predicted": round((actual + predicted) / 2.0, 2),
                "error": None if minute % 240 == 0 else round(actual - predicted, 2),
                "missing": minute % 240 == 0,
            }
        )
    return {
        "patient": patient,
        "resolution": "1min",
        "duration_minutes": 720,
        "grouping_modes": {"clinical_system": ["循环", "感染/炎症"], "data_source": ["生命体征", "实验室"]},
        "display_contract": {
            "chart_columns": 4,
            "chart_library": "Swift Charts",
            "curves": ["actual", "predicted", "error", "smoothed_predicted"],
            "missing_display": "point_markers",
            "window_overlap_display": "translucent_bands",
            "ai_summary": False,
        },
        "formulae": [{"name": "mae", "latex": r"MAE_w = \frac{1}{n}\sum |y_t-\hat{y}_t|"}],
        "parameters": [
            {
                "name": "heart_rate",
                "label": "心率",
                "unit": "bpm",
                "clinical_system": "循环",
                "data_source": "生命体征",
                "points": points,
                "metrics": {"mae": 0.9, "rmse": 1.1, "mape": 0.98, "dtw": 1.53},
            }
        ],
        "prediction_windows": [
            {
                "window_index": 1,
                "start_minute": 0,
                "end_minute": 360,
                "phenotype_actual": "P0",
                "phenotype_predicted": "P1",
                "phenotype_consistency": {"code": "mostly", "label": "大部分一致", "color": "blue"},
                "parameter_consistency": {"code": "average", "label": "中等一致", "color": "yellow"},
                "mae": 0.08,
                "rmse": 0.12,
                "mape": 4.5,
                "dtw": 0.22,
                "key_deviation_parameters": ["lactate", "map"],
            }
        ],
        "phenotype_transition": {"display": "transition_matrix", "states": ["P0", "P1"], "matrix": [[0.8, 0.2], [0.1, 0.9]]},
    }


def deepseek_config(saved: bool | None = None) -> dict[str, Any]:
    config = read_json(DEEPSEEK_CONFIG_PATH, {})
    if not isinstance(config, dict):
        config = {}
    api_key = str(config.get("api_key") or "")
    base_url = normalize_deepseek_base_url(config.get("base_url") or DEFAULT_DEEPSEEK_BASE_URL)
    payload = {
        "provider": "deepseek",
        "configured": bool(api_key),
        "model": str(config.get("model") or DEFAULT_DEEPSEEK_MODEL),
        "base_url": base_url,
        "timeout_seconds": str(config.get("timeout_seconds") or "18"),
        "api_key_hint": f"...{api_key[-4:]}" if api_key else "",
        "config_path": public_runtime_path("deepseek_config.json"),
        "saved": saved,
    }
    return payload


def binding_state() -> dict[str, Any]:
    bindings = read_binding_records()
    return {"bindings": [public_binding_record(item) for item in bindings], "storage": public_runtime_path("family_bindings.json")}


def read_binding_records() -> list[dict[str, Any]]:
    bindings = read_json(BINDINGS_PATH, [{"account": "family", "patient_ref": PATIENTS[0]["masked_id"], "updated_at": now_text()}])
    if not isinstance(bindings, list):
        return []
    return [item for item in bindings if isinstance(item, dict)]


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


def invalid_patient_ref_response(path: str, patient_ref: str) -> tuple[int, dict[str, Any]]:
    append_audit_event(
        "data_validation_failure",
        path=path,
        status_code=422,
        fields=["patient_ref"],
        patient_ref_hash=short_hash(patient_ref),
    )
    return 422, {
        "error": "invalid_patient_ref",
        "detail": "Family bindings must reference a known masked patient id or bed number.",
        "fields": ["patient_ref"],
    }


def public_health_payload() -> dict[str, Any]:
    metrics = metric_snapshot()
    return {
        "status": "ok",
        "service": "sepsis",
        "history_patients": len(HISTORICAL_PATIENTS),
        "data_dir": PUBLIC_RUNTIME_ROOT,
        "model_id": MODEL_ID,
        "device": os.getenv("SEPSISCARE_DEVICE", "cpu"),
        "metrics": metrics,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "SepsisCareLocal/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        try:
            sys.stderr.write("[%s] %s\n" % (now_text(), fmt % args))
        except (BrokenPipeError, OSError, ValueError):
            pass

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.add_common_headers()
        self.add_cors_headers()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self) -> None:
        self.route("GET")

    def do_POST(self) -> None:
        self.route("POST")

    def route(self, method: str) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = parse_qs(parsed.query)
        security_failure = security_failure_for_request(method, path, self.headers, self.client_address[0])
        if security_failure:
            self.send_json(security_failure[0], security_failure[1])
            return
        try:
            body = self.read_json_body() if method == "POST" else {}
        except RequestBodyTooLarge:
            self.send_json(413, {"error": "payload_too_large", "max_bytes": BODY_LIMIT_BYTES})
            return

        try:
            if method == "GET":
                response = self.handle_get(path, query)
            elif method == "POST":
                response = self.handle_post(path, body)
            else:
                response = (405, {"error": "method_not_allowed"})
        except Exception as exc:  # pragma: no cover - defensive local server guard
            response = (500, {"error": "internal_error", "detail": str(exc)})

        if isinstance(response, tuple):
            status, payload = response
        else:
            status, payload = 200, response

        if isinstance(payload, str):
            self.send_text(status, payload)
        else:
            self.send_json(status, payload)

    def read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return {}
        if length > BODY_LIMIT_BYTES:
            raise RequestBodyTooLarge()
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
            return payload if isinstance(payload, dict) else {}
        except json.JSONDecodeError:
            return {}

    def send_json(self, status: int, payload: Any) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.add_common_headers()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.add_cors_headers()
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, status: int, text: str) -> None:
        data = text.encode("utf-8")
        self.send_response(status)
        self.add_common_headers()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.add_cors_headers()
        self.end_headers()
        self.wfile.write(data)

    def add_common_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")

    def add_cors_headers(self) -> None:
        origin = header_value(self.headers, "Origin")
        if not origin:
            return
        allowed = {
            item.strip()
            for item in os.getenv("SEPSISCARE_ALLOWED_ORIGINS", "http://127.0.0.1,http://localhost,null").split(",")
            if item.strip()
        }
        if origin in allowed:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def handle_get(self, path: str, query: dict[str, list[str]]) -> Any:
        if path == "/health":
            return public_health_payload()

        if path == "/api/model/metadata":
            metrics = metric_snapshot()
            return {"app_model": MODEL_ID, "device": os.getenv("SEPSISCARE_DEVICE", "cpu"), "metrics": metrics}

        if path in {"/api/model/status", "/api/deployment/config"}:
            if path == "/api/model/status":
                return {"ok": True, "model_id": MODEL_ID, "metrics": metric_snapshot()}
            return deployment_config_payload()

        if path == "/api/patients":
            return self.patient_list(query)
        if path.startswith("/api/patients/"):
            masked_id = unquote(path.rsplit("/", 1)[-1])
            patient = next((item for item in PATIENTS if item["masked_id"] == masked_id), None)
            if patient is None:
                return invalid_patient_ref_response("/api/patients", masked_id)
            return {"patient": patient, "history": self.patient_history(patient)}
        if path == "/api/dashboard/stats":
            high = sum(1 for item in PATIENTS if item["risk_score"] >= 0.48)
            return {"active_patients": len(PATIENTS), "high_risk": high, "model_id": MODEL_ID, "updated_at": now_text()}
        if path == "/api/filters/options":
            return {
                "risk_levels": ["all", "green", "yellow", "orange", "red"],
                "icu_types": sorted({item["icu_ward"] for item in PATIENTS}),
                "phenotypes": sorted({item["phenotype_name"] for item in PATIENTS}),
            }
        if path == "/api/sepsis-subtypes/metadata":
            return {
                "subtypes": [
                    {"id": "P0", "name": "低危稳定型"},
                    {"id": "P1", "name": "中风险观察型"},
                    {"id": "P2", "name": "高危进展型"},
                    {"id": "P3", "name": "炎症风暴型"},
                ],
                "model_id": MODEL_ID,
            }
        if path == "/api/config/system":
            return {"python": sys.version.split()[0], "platform": platform.platform(), "workspace_root": PUBLIC_RUNTIME_ROOT}
        if path == "/api/config/ai":
            return {"provider": "deepseek", "configured": deepseek_config()["configured"], "model": deepseek_config()["model"]}
        if path == "/api/config/deepseek":
            return deepseek_config()
        if path == "/api/ai/analysis":
            return self.forward_ai_analysis_request()
        if path == "/api/diagnose/features":
            return diagnose_feature_schema()
        if path.startswith("/api/monitor/report/"):
            patient_ref = unquote(path.rsplit("/", 1)[-1])
            if not patient_ref_is_allowed(patient_ref):
                return invalid_patient_ref_response("/api/monitor/report", patient_ref)
            return {"ok": True, "patient_ref": patient_ref, "summary": "当前趋势总体可控，建议持续观察乳酸和 MAP。"}
        if path == "/api/bedside/beds":
            limit = int(query.get("limit", ["12"])[0])
            return {"beds": [{"bed_no": item["bed_no"], "patient_ref": item["masked_id"], "risk_score": item["risk_score"]} for item in PATIENTS[:limit]]}
        if path.startswith("/api/bedside/snapshot/"):
            bed_no = unquote(path.rsplit("/", 1)[-1])
            patient = next((item for item in PATIENTS if item["bed_no"] == bed_no), None)
            if patient is None:
                return invalid_patient_ref_response("/api/bedside/snapshot", bed_no)
            return {"bed_no": bed_no, "patient": patient, "vitals": patient["vitals"], "updated_at": now_text()}
        if path == "/api/admin/status":
            return admin_status_payload()
        if path == "/api/admin/bindings":
            return binding_state()
        if path == "/api/history/patients":
            return self.history_list(query)
        if path == "/api/history/stats":
            return {"total": len(HISTORICAL_PATIENTS), "sources": 4, "model_version": "S7-contrastive-20260516"}
        if path.startswith("/api/history/patients/"):
            history_id = unquote(path.rsplit("/", 1)[-1])
            if not any(item["history_id"] == history_id for item in HISTORICAL_PATIENTS):
                return invalid_patient_ref_response("/api/history/patients", history_id)
            return historical_detail(history_id)
        if path == "/api/history/export":
            scope = query.get("scope", ["list"])[0].strip() or "list"
            history_id = query.get("history_id", [""])[0].strip()
            if history_id and not any(item["history_id"] == history_id for item in HISTORICAL_PATIENTS):
                return invalid_patient_ref_response("/api/history/export", history_id)
            csv_text = self.history_csv(query)
            append_audit_event(
                "history_export",
                path="/api/history/export",
                scope=scope,
                row_count=max(0, len(csv_text.splitlines()) - 1),
                history_ref_hash=short_hash(history_id) if history_id else None,
            )
            return csv_text
        if path == "/api/training-terminal/status":
            return training_status()
        if path == "/api/training-terminal/logs":
            return {"ok": True, "storage": public_runtime_path("training_terminal.log"), "logs": self.training_logs(int(query.get("limit", ["80"])[0]))}
        if path == "/api/icu/realtime/status":
            return icu_realtime_status()
        if path == "/api/icu/realtime/demo":
            return {"ok": True, "demo": demo_icu_event(), "status": icu_realtime_status()}
        if path == "/api/audit":
            return {"ok": True, "events": [{"ts": now_text(), "actor": "local", "action": "health_check", "target": MODEL_ID}]}

        return 404, {"error": "not_found", "path": path}

    def handle_post(self, path: str, body: dict[str, Any]) -> Any:
        if path == "/api/config/deepseek":
            existing = read_json(DEEPSEEK_CONFIG_PATH, {})
            if not isinstance(existing, dict):
                existing = {}
            changed_fields = sorted(str(key) for key in body.keys() if key in {"api_key", "base_url", "clear_key", "model", "timeout_seconds"})
            base_url_rejected = False
            if body.get("clear_key"):
                existing["api_key"] = ""
            elif "api_key" in body and body.get("api_key"):
                existing["api_key"] = str(body.get("api_key"))
            for key in ("model", "timeout_seconds"):
                if key in body and body.get(key) is not None:
                    existing[key] = str(body.get(key))
            if "base_url" in body and body.get("base_url") is not None:
                normalized_base_url = normalize_deepseek_base_url(body.get("base_url"))
                base_url_rejected = deepseek_base_url_was_rejected(body.get("base_url"), normalized_base_url)
                existing["base_url"] = normalized_base_url
            write_json(DEEPSEEK_CONFIG_PATH, existing)
            append_audit_event(
                "config_change",
                path="/api/config/deepseek",
                target="deepseek",
                fields=changed_fields,
                key_changed=("api_key" in body or bool(body.get("clear_key"))),
                clear_key=bool(body.get("clear_key")),
                base_url_rejected=base_url_rejected,
            )
            return deepseek_config(saved=True)
        if path == "/api/admin/bindings":
            account = str(body.get("account") or "family")
            patient_ref = str(body.get("patient_ref") or PATIENTS[0]["masked_id"])
            if not patient_ref_is_allowed(patient_ref):
                return invalid_patient_ref_response(path, patient_ref)
            current = read_binding_records()
            current = [item for item in current if item.get("account") != account]
            binding = {"account": account, "patient_ref": patient_ref, "updated_at": now_text()}
            current.append(binding)
            write_json(BINDINGS_PATH, current)
            append_audit_event(
                "admin_binding_update",
                path="/api/admin/bindings",
                account=account,
                patient_ref_hash=short_hash(patient_ref),
            )
            return {"ok": True, "binding": public_binding_record(binding), "storage": public_runtime_path("family_bindings.json")}
        if path == "/api/model/predict":
            current = body.get("current") if isinstance(body.get("current"), dict) else body
            failures = validate_clinical_payload(current)
            if failures:
                return invalid_clinical_payload_response(path, failures)
            return prediction_from_payload(current)
        if path == "/api/family/chat":
            question = redact_sensitive_text(body.get("question"))
            return self.forward_chat_request("/api/family/chat", body, question, family=True)
        if path in {"/api/diagnose", "/api/clinical/pipeline"}:
            failures = validate_clinical_payload(body)
            if failures:
                return invalid_clinical_payload_response(path, failures)
            result = prediction_from_payload(body)
            return {"ok": True, "diagnosis": result, "recommendations": ["复查乳酸", "关注 MAP 和尿量", "结合感染源控制评估"]}
        if path == "/api/diagnose/batch":
            patients = body.get("patients") if isinstance(body.get("patients"), list) else []
            failures: list[str] = []
            for index, item in enumerate(patients[:20]):
                for field in validate_clinical_payload(item):
                    failures.append(f"patients[{index}].{field}")
            if failures:
                return invalid_clinical_payload_response(path, failures)
            return {"ok": True, "count": len(patients), "results": [prediction_from_payload(item) for item in patients[:20] if isinstance(item, dict)]}
        if path == "/api/clinical/scores":
            return {"sofa": 5, "qsofa": 1, "news2": 6, "interpretation": "中等风险，需持续监测。"}
        if path == "/api/sepsis-subtypes/predict":
            return {"ok": True, "subtype": {"id": "P1", "name": "中风险观察型"}, "probabilities": {"P0": 0.22, "P1": 0.46, "P2": 0.21, "P3": 0.11}}
        if path == "/api/sepsis-subtypes/recommend":
            return {"ok": True, "recommendations": ["按 6 小时窗口复核表型迁移", "优先观察乳酸、MAP、机械通气概率"]}
        if path == "/api/ai/llm-diagnose":
            payload = dict(body)
            payload["context"] = ai_request_context(body)
            return self.forward_model_request("/api/ai/llm-diagnose", local_llm_diagnosis(body), body=payload, log_action="ai_llm_diagnose")
        if path == "/api/ai/explain":
            payload = dict(body)
            payload["term"] = redact_sensitive_text(body.get("term") or "指标")
            payload["context"] = ai_request_context(body)
            return self.forward_model_request("/api/ai/explain", local_ai_explanation(body), body=payload, log_action="ai_explain")
        if path == "/api/ai/assistant-chat":
            question = redact_sensitive_text(body.get("question"))
            return self.forward_chat_request("/api/ai/assistant-chat", body, question, family=False)
        if path == "/api/icu/realtime/ingest":
            events, failures = normalize_icu_event_batch(body)
            if failures:
                return invalid_clinical_payload_response(path, failures)
            append_icu_timeseries(events)
            append_audit_event("icu_realtime_ingest", path=path, accepted=len(events))
            latest_prediction = prediction_from_payload(events[-1]) if events else prediction_from_payload({})
            return {
                "ok": True,
                "accepted": len(events),
                "storage": public_runtime_path("icu_timeseries.jsonl"),
                "status": icu_realtime_status(),
                "latest_prediction": latest_prediction,
            }
        if path == "/api/icu/realtime/upload":
            return self.upload_icu_timeseries(body)
        if path == "/api/training-terminal/config":
            requested_cloud_base_url = body.get("cloud_base_url")
            cloud_base_url = sanitize_cloud_url(requested_cloud_base_url)
            if training_cloud_url_was_rejected(requested_cloud_base_url, cloud_base_url):
                status = update_training_state(
                    mode=str(body.get("mode") or "production"),
                    cloud_base_url="",
                    params=body.get("params") if isinstance(body.get("params"), dict) else {},
                    last_action="sync_config",
                    task_status="error",
                )
                append_training_log("sync_config", "训练终端云端模型服务地址被安全策略拒绝。", level="error")
                append_audit_event(
                    "training_cloud_url_rejected",
                    path="/api/training-terminal/config",
                    reason="unsafe_cloud_base_url",
                )
                return training_config_response(
                    status,
                    ok=False,
                    output=["云端模型服务地址被安全策略拒绝。"],
                    error="cloud_base_url_rejected",
                )
            cloud_base_url = effective_training_cloud_base_url(cloud_base_url)
            status = update_training_state(
                mode=str(body.get("mode") or "production"),
                cloud_base_url=cloud_base_url,
                params=sanitize_training_params(body.get("params")),
                last_action="sync_config",
                task_status="synced",
            )
            append_training_log("sync_config", "训练终端配置已保存。")
            return training_config_response(status, ok=True, output=["训练终端配置已保存。"])
        if path in {"/api/training-terminal/action", "/api/training-terminal/command"}:
            action = str(body.get("action") or "")
            command = str(body.get("command") or "")
            resolved = action or self.action_from_command(command)
            status = training_status()
            if status.get("mode") == "production":
                return self.forward_training_command(status, resolved, command, body)
            status_text = "running" if resolved == "continue_training" else "paused" if resolved == "pause_training" else "idle"
            output = self.training_output(resolved, command)
            status = update_training_state(last_action=resolved or "status", task_status=status_text)
            append_training_log(resolved or "status", " | ".join(output))
            return {"ok": True, "mode": status["mode"], "action": action or None, "command": command or None, "output": output, "status": status, "error": None, "cloud_response": {"ok": True, "model_id": MODEL_ID}}

        return 404, {"error": "not_found", "path": path}

    def patient_list(self, query: dict[str, list[str]]) -> dict[str, Any]:
        page = max(1, int(query.get("page", ["1"])[0]))
        per_page = max(1, int(query.get("per_page", ["20"])[0]))
        search = query.get("search", [""])[0].strip().lower()
        filtered = PATIENTS
        if search:
            filtered = [item for item in filtered if search in item["masked_id"].lower() or search in item["bed_no"].lower()]
        start = (page - 1) * per_page
        end = start + per_page
        return {"patients": filtered[start:end], "total": len(filtered), "page": page, "per_page": per_page}

    def patient_history(self, patient: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            {"hour": hour, "heart_rate": patient["vitals"]["heart_rate"] + hour / 12.0, "map": patient["vitals"]["map"] - hour / 18.0, "lactate": patient["labs"]["lactate"] + hour / 60.0}
            for hour in [0, 6, 12, 24, 36, 48]
        ]

    def history_list(self, query: dict[str, list[str]]) -> dict[str, Any]:
        page = max(1, int(query.get("page", ["1"])[0]))
        per_page = max(1, int(query.get("per_page", ["100"])[0]))
        start = (page - 1) * per_page
        end = start + per_page
        sort = first_query_value(query, "sort", default="los_desc")
        rows = filtered_history_rows(query)
        return {"patients": rows[start:end], "total": len(rows), "page": page, "per_page": per_page, "sort": sort, "lazy_detail": True}

    def history_csv(self, query: dict[str, list[str]]) -> str:
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=["history_id", "masked_id", "data_source", "icu_type", "los_hours", "outcome", "primary_phenotype"])
        writer.writeheader()
        history_id = query.get("history_id", [""])[0].strip()
        if history_id:
            rows = [item for item in HISTORICAL_PATIENTS if item["history_id"] == history_id]
        else:
            page = max(1, int(query.get("page", ["1"])[0]))
            per_page = max(1, int(query.get("per_page", ["100"])[0]))
            start = (page - 1) * per_page
            end = start + per_page
            rows = filtered_history_rows(query)[start:end]
        for row in rows:
            writer.writerow({key: row[key] for key in writer.fieldnames or []})
        return output.getvalue()

    def upload_icu_timeseries(self, body: dict[str, Any]) -> dict[str, Any]:
        requested_cloud_base_url = body.get("cloud_base_url") or training_status().get("cloud_base_url")
        cloud_base_url = sanitize_cloud_url(requested_cloud_base_url)
        if training_cloud_url_was_rejected(requested_cloud_base_url, cloud_base_url) or not cloud_base_url:
            append_audit_event("icu_realtime_upload_failed", path="/api/icu/realtime/upload", reason="cloud_base_url_not_configured")
            return {
                "ok": False,
                "error": "cloud_base_url_not_configured",
                "output": ["请先配置有效的云端模型服务地址。"],
                "status": icu_realtime_status(),
                "cloud_response": None,
            }
        cloud_base_url = effective_training_cloud_base_url(cloud_base_url)
        events = body.get("events") if isinstance(body.get("events"), list) else []
        if events:
            events, failures = normalize_icu_event_batch({"events": events, "source": body.get("source") or "manual-upload"})
            if failures:
                status, payload = invalid_clinical_payload_response("/api/icu/realtime/upload", failures)
                return {"ok": False, "error": payload["error"], "status_code": status, "fields": payload["fields"]}
        else:
            events = read_icu_timeseries(int(body.get("limit") or 500))
        if not events:
            return {
                "ok": False,
                "error": "no_timeseries_events",
                "output": ["本地还没有可上传的 ICU 时序事件。"],
                "status": icu_realtime_status(),
                "cloud_response": None,
            }

        endpoint = f"{cloud_base_url}/api/icu/timeseries/ingest"
        request_payload = {"source": "sepsiscare-local-icu-interface", "sent_at": now_text(), "events": events}
        data = json.dumps(request_payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib_request.Request(endpoint, data=data, headers=headers, method="POST")
        timeout = float(os.getenv("SEPSISCARE_TRAINING_TIMEOUT_SECONDS", "20"))
        try:
            with urllib_request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
            if not isinstance(result, dict):
                raise ValueError("cloud response was not a JSON object")
        except urllib_error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            append_audit_event("icu_realtime_upload_failed", path="/api/icu/realtime/upload", reason=f"HTTP {exc.code}")
            return {"ok": False, "error": "cloud_upload_failed", "output": [f"HTTP {exc.code}: {detail}"], "status": icu_realtime_status(), "cloud_response": None}
        except (urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            append_audit_event("icu_realtime_upload_failed", path="/api/icu/realtime/upload", reason="request_failed")
            return {"ok": False, "error": "cloud_upload_failed", "output": [str(exc)], "status": icu_realtime_status(), "cloud_response": None}

        upload_state = {
            "last_upload_at": now_text(),
            "endpoint": endpoint,
            "uploaded_events": len(events),
            "cloud_accepted": result.get("accepted"),
            "training_ready": bool(result.get("training_ready")),
        }
        write_json(ICU_UPLOAD_STATE_PATH, upload_state)
        append_audit_event("icu_realtime_upload", path="/api/icu/realtime/upload", uploaded_events=len(events), cloud_accepted=result.get("accepted"))
        return {
            "ok": bool(result.get("ok", True)),
            "uploaded_events": len(events),
            "status": icu_realtime_status(),
            "output": [f"已上传 {len(events)} 条 ICU 时序事件至云端模型服务。"],
            "cloud_response": result,
        }

    def training_logs(self, limit: int) -> list[dict[str, Any]]:
        if not TRAINING_LOG_PATH.exists():
            append_training_log("startup", "本地训练终端已就绪。")
        rows = []
        for raw in TRAINING_LOG_PATH.read_text(encoding="utf-8").splitlines()[-limit:]:
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                item = {"ts": now_text(), "level": "info", "source": "local", "action": "log", "message": raw}
            rows.append(item)
        return rows

    def forward_ai_analysis_request(self) -> dict[str, Any]:
        fallback = local_ai_analysis()
        result = self.forward_model_request("/api/ai/analysis", fallback, method="GET", log_action="ai_analysis")
        if not remote_ai_analysis_is_placeholder(result):
            return result

        assistant_result = self.forward_ai_analysis_via_assistant(result)
        return assistant_result if assistant_result else result

    def forward_ai_analysis_via_assistant(self, placeholder: dict[str, Any]) -> dict[str, Any] | None:
        status = training_status()
        cloud_base_url = sanitize_cloud_url(status.get("cloud_base_url"))
        if not cloud_base_url:
            return None

        metrics = metric_snapshot()
        high_risk = sum(1 for item in PATIENTS if item.get("risk_score", 0) >= 0.48)
        context = chat_context("")
        context["metrics"] = metrics
        context["cohort"] = {
            "patient_count": len(PATIENTS),
            "high_risk_count": high_risk,
            "phenotypes": sorted({str(item.get("phenotype_name") or "") for item in PATIENTS if item.get("phenotype_name")}),
        }
        context["remote_analysis_placeholder"] = sanitize_training_value(placeholder)
        question = (
            "请基于当前 SepsisCare ICU 队列、训练状态和模型指标生成模型分析摘要。"
            "必须返回真实 DeepSeek 分析，不要只回答远程服务在线。"
        )
        payload = {
            "client": "sepsiscare-macos-transfer-backend",
            "sent_at": now_text(),
            "question": question,
            "patient_ref": context["patient"].get("masked_id"),
            "context": context,
        }
        endpoint = f"{cloud_base_url}/api/ai/assistant-chat"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib_request.Request(endpoint, data=data, headers=headers, method="POST")
        timeout = float(os.getenv("SEPSISCARE_AI_TIMEOUT_SECONDS", "20"))

        try:
            with urllib_request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
            if not isinstance(result, dict):
                raise ValueError("cloud response was not a JSON object")
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            append_training_log("ai_analysis", f"云端 DeepSeek 兼容分析连接失败：{str(exc)[:220]}", level="error")
            return None

        answer = str(result.get("answer") or result.get("summary") or "").strip()
        if not answer:
            append_training_log("ai_analysis", "云端 DeepSeek 兼容分析缺少 answer。", level="error")
            return None

        analysis = dict(placeholder)
        analysis.update(
            {
                "ok": bool(result.get("ok", True)),
                "summary": answer,
                "source": result.get("source") or "remote-windows-model-server",
                "model": result.get("model"),
                "metrics": metrics,
                "training_status": {
                    "task_status": status.get("task_status"),
                    "last_action": status.get("last_action"),
                    "cloud_base_url": status.get("cloud_base_url"),
                },
                "analysis_via": "/api/ai/assistant-chat",
                "assistant_response": sanitize_training_value(result),
            }
        )
        append_training_log("ai_analysis", f"云端 DeepSeek 兼容分析已返回结果：{endpoint}")
        return analysis

    def forward_model_request(
        self,
        remote_path: str,
        fallback: dict[str, Any],
        *,
        method: str = "POST",
        body: dict[str, Any] | None = None,
        log_action: str = "ai_request",
    ) -> dict[str, Any]:
        status = training_status()
        cloud_base_url = sanitize_cloud_url(status.get("cloud_base_url"))
        if not cloud_base_url:
            return fallback

        endpoint = f"{cloud_base_url}{remote_path}"
        headers = {"Content-Type": "application/json"}
        token = configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        if method.upper() == "GET":
            request = urllib_request.Request(endpoint, headers=headers, method="GET")
        else:
            payload = body if isinstance(body, dict) else {}
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            request = urllib_request.Request(endpoint, data=data, headers=headers, method=method.upper())
        timeout = float(os.getenv("SEPSISCARE_AI_TIMEOUT_SECONDS", "20"))

        try:
            with urllib_request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
            if not isinstance(result, dict):
                raise ValueError("cloud response was not a JSON object")
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            fallback["cloud_error"] = str(exc)[:220]
            append_training_log(log_action, f"云端 AI 接口连接失败：{fallback['cloud_error']}", level="error")
            return fallback

        result.setdefault("source", "remote-windows-model-server")
        append_training_log(log_action, f"云端 AI 接口已返回结果：{endpoint}")
        return result

    def forward_chat_request(self, remote_path: str, body: dict[str, Any], question: str, *, family: bool) -> dict[str, Any]:
        patient_ref = str(body.get("patient_ref") or body.get("masked_id") or "").strip()
        context = chat_context(patient_ref)
        if isinstance(body.get("context"), dict):
            context["client_context"] = sanitize_training_value(body["context"])

        status = context["training_status"]
        cloud_base_url = sanitize_cloud_url(status.get("cloud_base_url"))
        fallback = local_chat_answer(question, context, family=family)
        if not cloud_base_url:
            return fallback

        payload = {
            "client": "sepsiscare-macos-transfer-backend",
            "sent_at": now_text(),
            "question": question,
            "patient_ref": context["patient"].get("masked_id"),
            "context": context,
        }
        endpoint = f"{cloud_base_url}{remote_path}"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib_request.Request(endpoint, data=data, headers=headers, method="POST")
        timeout = float(os.getenv("SEPSISCARE_AI_TIMEOUT_SECONDS", "20"))

        try:
            with urllib_request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
            if not isinstance(result, dict):
                raise ValueError("cloud response was not a JSON object")
        except (urllib_error.HTTPError, urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            fallback["cloud_error"] = str(exc)[:220]
            append_training_log("ai_chat", f"云端 AI 智能体连接失败：{fallback['cloud_error']}", level="error")
            return fallback

        answer = str(result.get("answer") or result.get("summary") or "").strip()
        if not answer:
            fallback["cloud_error"] = "cloud_response_missing_answer"
            return fallback
        result.setdefault("source", "remote-windows-model-server")
        result["answer"] = answer
        append_training_log("ai_chat", f"云端 AI 智能体已返回结果：{endpoint}")
        return result

    def action_from_command(self, command: str) -> str:
        lowered = command.lower()
        if "pause" in lowered or "暂停" in command:
            return "pause_training"
        if "download" in lowered or "artifact" in lowered or "下载" in command:
            return "download_artifacts"
        if "metric" in lowered or "loss" in lowered or "日志" in command:
            return "stream_metrics"
        if "train" in lowered or "resume" in lowered or "继续" in command:
            return "continue_training"
        return "status"

    def forward_training_command(self, status: dict[str, Any], action: str, command: str, body: dict[str, Any]) -> dict[str, Any]:
        if not str(status.get("cloud_base_url") or "").strip():
            cloud_base_url = ""
        else:
            cloud_base_url = effective_training_cloud_base_url(status.get("cloud_base_url"))
        if not cloud_base_url:
            next_status = update_training_state(last_action=action or "status", task_status="error")
            message = "生产模式未配置有效的云端模型服务地址。"
            append_training_log(action or "status", message, level="error")
            return {
                "ok": False,
                "mode": next_status["mode"],
                "action": action or None,
                "command": command or None,
                "output": [message, "请填写 http(s)://host:port，例如 http://目标电脑IP:8788。"],
                "status": next_status,
                "error": "cloud_base_url_not_configured",
                "cloud_response": None,
            }

        endpoint = f"{cloud_base_url}/api/training/command"
        request_payload: dict[str, Any] = {
            "client": "sepsiscare-macos-transfer-backend",
            "sent_at": now_text(),
            "mode": status.get("mode", "production"),
            "model_profile": status.get("model_profile", MODEL_ID),
            "params": sanitize_training_params(status.get("params")),
            "action": action or "status",
        }
        if command:
            request_payload["command"] = redact_sensitive_text(command)
        if isinstance(body.get("payload"), dict):
            request_payload["payload"] = sanitize_training_value(body["payload"])

        data = json.dumps(request_payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        request = urllib_request.Request(endpoint, data=data, headers=headers, method="POST")
        timeout = float(os.getenv("SEPSISCARE_TRAINING_TIMEOUT_SECONDS", "20"))

        try:
            with urllib_request.urlopen(request, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
            if not isinstance(result, dict):
                raise ValueError("cloud response was not a JSON object")
        except urllib_error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            return self.cloud_forward_error(status, action, command, endpoint, f"HTTP {exc.code}: {detail}")
        except (urllib_error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError) as exc:
            return self.cloud_forward_error(status, action, command, endpoint, str(exc))

        updates: dict[str, Any] = {
            "last_action": action or "status",
            "task_status": str(result.get("task_status") or result.get("status") or status.get("task_status", "idle")),
        }
        if isinstance(result.get("artifacts"), list):
            updates["artifacts"] = result["artifacts"]
        next_status = update_training_state(**updates)
        if isinstance(result.get("metrics"), dict):
            next_status["metrics"].update(result["metrics"])

        output = result.get("output") or result.get("logs") or []
        if isinstance(output, str):
            output = [output]
        if not isinstance(output, list):
            output = [json.dumps(result, ensure_ascii=False)]
        output = [f"已转发至云端模型服务：{endpoint}"] + [str(line) for line in output]
        append_training_log(action or "status", f"云端模型服务已返回结果：{endpoint}")
        ok = bool(result.get("ok", True))
        return {
            "ok": ok,
            "mode": next_status["mode"],
            "action": action or None,
            "command": command or None,
            "output": output,
            "status": next_status,
            "error": None if ok else str(result.get("error") or "cloud_response_not_ok"),
            "cloud_response": result,
        }

    def cloud_forward_error(self, status: dict[str, Any], action: str, command: str, endpoint: str, detail: str) -> dict[str, Any]:
        next_status = update_training_state(last_action=action or "status", task_status="error")
        message = f"云端模型服务连接失败：{detail[:220]}"
        append_training_log(action or "status", f"{message} endpoint={endpoint}", level="error")
        return {
            "ok": False,
            "mode": next_status["mode"],
            "action": action or None,
            "command": command or None,
            "output": [message, f"endpoint={endpoint}"],
            "status": next_status,
            "error": "cloud_forward_failed",
            "cloud_response": None,
        }

    def training_output(self, action: str, command: str) -> list[str]:
        metrics = metric_snapshot()
        if action == "continue_training":
            return ["已进入演示运行状态。迁移包不自动启动昂贵训练。", f"macro_f1={metrics['macro_f1']}"]
        if action == "pause_training":
            return ["训练终端状态已标记为 paused。"]
        if action == "download_artifacts":
            return [f"模型成果位于：{MODEL_ROOT}", f"报告目录：{DEPLOY_ROOT / 'reports'}"]
        if action == "stream_metrics":
            return [
                f"encoder_macro_f1={metrics['encoder_macro_f1']}",
                f"mortality_auroc={metrics['mortality_auroc']}",
                f"remaining_los_mae_hours={metrics['remaining_los_mae_hours']}",
            ]
        return [f"云端模型服务兼容层在线。command={command or 'status'}", f"model_id={MODEL_ID}"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Start the SepsisCare local transfer backend")
    parser.add_argument("--host", default=os.getenv("SEPSISCARE_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.getenv("SEPSISCARE_PORT", "8765")))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)
    append_training_log("startup", f"local transfer backend starting at http://{args.host}:{args.port}")
    try:
        httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as exc:
        if exc.errno == 48 and existing_server_is_healthy(args.host, args.port):
            print(
                f"SepsisCare local transfer backend already healthy at http://{args.host}:{args.port}; reusing it.",
                flush=True,
            )
            return
        raise
    print(f"SepsisCare local transfer backend listening on http://{args.host}:{args.port}", flush=True)
    httpd.serve_forever()


def existing_server_is_healthy(host: str, port: int) -> bool:
    request = (
        "GET /health HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8")
    try:
        with socket.create_connection((host, port), timeout=1.0) as sock:
            sock.sendall(request)
            response = sock.recv(4096)
    except OSError:
        return False
    return b"200" in response[:32] and b'"status": "ok"' in response and b'"service": "sepsis"' in response


if __name__ == "__main__":
    main()
