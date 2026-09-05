#!/usr/bin/env python3
import json
import os
import sys
import urllib.request
from pathlib import Path


def service_token():
    for name in ("SEPSISCARE_SERVICE_TOKEN", "SEPSISCARE_TRAINING_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    for name in ("SEPSISCARE_SERVICE_TOKEN_FILE", "SEPSISCARE_TRAINING_TOKEN_FILE"):
        raw_path = os.environ.get(name, "").strip()
        if not raw_path:
            continue
        try:
            value = Path(raw_path).expanduser().read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    app_support = Path.home() / "Library" / "Application Support" / "SepsisCare"
    for filename in ("sepsiscare_service_token.txt", "sepsiscare_training_token.txt"):
        try:
            value = (app_support / filename).read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if value:
            return value
    return ""


def request(base, method, path, payload=None):
    data = None
    headers = {}
    token = service_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    timeout = float(os.environ.get("SEPSISCARE_SMOKE_TIMEOUT_SECONDS", "30"))
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read()
        text = body.decode("utf-8")
        if response.headers.get_content_type() == "application/json":
            return response.status, json.loads(text)
        return response.status, text


def check_json(base, method, path, payload=None, required_keys=()):
    status, data = request(base, method, path, payload)
    if status != 200:
        raise AssertionError(f"{method} {path} returned HTTP {status}")
    if not isinstance(data, dict):
        raise AssertionError(f"{method} {path} did not return a JSON object")
    missing = [key for key in required_keys if key not in data]
    if missing:
        raise AssertionError(f"{method} {path} missing keys: {missing}")
    print(f"ok {method} {path}")
    return data


def check_text(base, path):
    status, text = request(base, "GET", path)
    if status != 200 or not text.strip():
        raise AssertionError(f"GET {path} returned empty text")
    print(f"ok GET {path}")
    return text


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: smoke_test.py <api-base-url> <model-base-url> <mode>")

    api_base, model_base, mode = sys.argv[1:4]
    require_model = mode in {"--require-model", "require-model", "full"}
    terminal_mode = "production" if require_model else "demo"
    patient_payload = {
        "age": 67,
        "sex": 1,
        "vitals": {
            "heart_rate": 108,
            "sbp": 96,
            "dbp": 55,
            "map": 69,
            "resp_rate": 24,
            "spo2": 93,
            "temperature": 38.2,
            "gcs": 13,
        },
        "labs": {
            "creatinine": 1.6,
            "bun": 32,
            "glucose": 155,
            "wbc": 15.2,
            "platelet": 148,
            "potassium": 4.3,
            "sodium": 136,
            "lactate": 3.1,
            "bilirubin": 1.4,
        },
    }
    realtime_payload = {
        "source": "smoke-icu-monitor",
        "events": [
            {
                "patient_ref": "SMOKE-ICU-001",
                "bed_no": "ICU-01",
                "timestamp": "2026-06-04T14:00:00+08:00",
                "ward": "综合 ICU",
                "vitals": {
                    "heart_rate": 112,
                    "map": 64,
                    "resp_rate": 26,
                    "spo2": 92,
                    "temperature": 38.4,
                    "gcs": 13,
                },
                "labs": {"lactate": 3.4, "wbc": 16.2, "creatinine": 1.4, "platelet": 142},
            }
        ],
    }

    checks = [
        ("GET", "/health", None, ("status", "service")),
        ("GET", "/api/deployment/config", None, ("backend_mode", "interfaces")),
        ("GET", "/api/model/metadata", None, ("app_model", "metrics")),
        ("GET", "/api/model/status", None, ("ok", "model_id")),
        ("GET", "/api/patients?page=1&per_page=3", None, ("patients", "total")),
        ("GET", "/api/patients/SC-12000", None, ("patient", "history")),
        ("GET", "/api/dashboard/stats", None, ("active_patients", "high_risk")),
        ("GET", "/api/filters/options", None, ("risk_levels", "icu_types")),
        ("GET", "/api/sepsis-subtypes/metadata", None, ("subtypes", "model_id")),
        ("GET", "/api/config/system", None, ("python", "platform")),
        ("GET", "/api/config/ai", None, ("provider", "configured")),
        ("GET", "/api/config/deepseek", None, ("provider", "configured")),
        ("GET", "/api/ai/analysis", None, ("summary", "model_id")),
        ("GET", "/api/monitor/report/SC-12000", None, ("ok", "patient_ref")),
        ("GET", "/api/bedside/beds?limit=2", None, ("beds",)),
        ("GET", "/api/bedside/snapshot/ICU-01", None, ("bed_no", "patient")),
        ("GET", "/api/admin/status", None, ("service", "backend", "device")),
        ("GET", "/api/admin/bindings", None, ("bindings", "storage")),
        ("GET", "/api/history/patients?page=1&per_page=3", None, ("patients", "total")),
        ("GET", "/api/history/stats", None, ("total", "sources")),
        ("GET", "/api/history/patients/HICU-700000", None, ("patient", "parameters")),
        ("GET", "/api/training-terminal/status", None, ("ok", "model_profile")),
        ("GET", "/api/training-terminal/logs?limit=5", None, ("ok", "logs")),
        ("GET", "/api/audit", None, ("ok", "events")),
        ("POST", "/api/model/predict", patient_payload, ("latest", "risk_level")),
        ("POST", "/api/diagnose", patient_payload, ("ok", "diagnosis")),
        ("POST", "/api/diagnose/batch", {"patients": [patient_payload]}, ("ok", "count")),
        ("POST", "/api/clinical/pipeline", patient_payload, ("ok", "diagnosis")),
        ("POST", "/api/clinical/scores", patient_payload, ("sofa", "qsofa")),
        ("POST", "/api/sepsis-subtypes/predict", {"time_series": []}, ("ok", "subtype")),
        ("POST", "/api/sepsis-subtypes/recommend", {"time_series": []}, ("ok", "recommendations")),
        ("POST", "/api/ai/llm-diagnose", patient_payload, ("ok", "summary")),
        ("POST", "/api/ai/explain", {"term": "SOFA评分", "context": "脓毒症"}, ("term", "explanation")),
        (
            "POST",
            "/api/training-terminal/config",
            {"mode": terminal_mode, "cloud_base_url": model_base, "params": {}},
            ("ok", "status"),
        ),
    ]

    for method, path, payload, keys in checks:
        check_json(api_base, method, path, payload, keys)

    family_reply = check_json(
        api_base,
        "POST",
        "/api/family/chat",
        {"patient_ref": "ICU-01", "question": "现在风险如何？"},
        ("answer", "source"),
    )
    family_answer = str(family_reply.get("answer") or "")
    family_context = family_reply.get("context") if isinstance(family_reply.get("context"), dict) else {}
    if (
        "已收到问题" in family_answer
        or "乳酸" not in family_answer
        or not family_context.get("patient_ref")
        or not family_context.get("model_id")
    ):
        raise AssertionError("family chat returned placeholder text instead of patient context")

    assistant_reply = check_json(
        api_base,
        "POST",
        "/api/ai/assistant-chat",
        {"patient_ref": "SC-12000", "question": "乳酸升高怎么看？"},
        ("answer", "source"),
    )
    assistant_answer = str(assistant_reply.get("answer") or "")
    assistant_context = assistant_reply.get("context") if isinstance(assistant_reply.get("context"), dict) else {}
    if (
        "已收到问题" in assistant_answer
        or "乳酸" not in assistant_answer
        or ("macro_f1" not in assistant_answer and "task_status" not in assistant_context)
        or not assistant_context.get("patient_ref")
        or not assistant_context.get("model_id")
    ):
        raise AssertionError("AI assistant chat did not pull remote model/training context")

    terminal_action = check_json(
        api_base,
        "POST",
        "/api/training-terminal/action",
        {"action": "stream_metrics"},
        ("ok", "output", "status"),
    )
    if require_model:
        cloud_response = terminal_action.get("cloud_response")
        if not isinstance(cloud_response, dict) or cloud_response.get("ok") is not True:
            raise AssertionError("training terminal did not receive an ok cloud_response")
        output = terminal_action.get("output")
        if not isinstance(output, list) or not output:
            raise AssertionError("training terminal action returned no output")
        proof_text = "\n".join(str(item) for item in output)
        if "已转发至云端模型服务" not in proof_text and "模型服务直接执行训练终端动作" not in proof_text:
            raise AssertionError("training terminal action did not prove API-to-model execution")

    check_text(api_base, "/api/history/export?scope=list")

    if require_model:
        ingest = check_json(api_base, "POST", "/api/icu/realtime/ingest", realtime_payload, ("ok", "accepted", "status"))
        if ingest.get("accepted") != 1:
            raise AssertionError("ICU realtime ingest did not accept the smoke event")
        upload = check_json(
            api_base,
            "POST",
            "/api/icu/realtime/upload",
            {"cloud_base_url": model_base, "limit": 5},
            ("ok", "cloud_response", "status"),
        )
        cloud_upload = upload.get("cloud_response")
        if not isinstance(cloud_upload, dict) or cloud_upload.get("accepted", 0) < 1:
            raise AssertionError("ICU realtime upload did not prove cloud ingestion")
        train = check_json(
            api_base,
            "POST",
            "/api/training-terminal/action",
            {"action": "continue_training"},
            ("ok", "cloud_response", "status"),
        )
        cloud_training = train.get("cloud_response")
        if not isinstance(cloud_training, dict) or cloud_training.get("task_status") != "trained":
            raise AssertionError("remote training did not consume newly uploaded ICU data")
        metrics = cloud_training.get("metrics") if isinstance(cloud_training.get("metrics"), dict) else {}
        if metrics.get("incremental_new_events", 0) < 1:
            raise AssertionError("remote training metrics did not report new ICU events")

        check_json(model_base, "GET", "/health", required_keys=("ok", "model_id", "missing"))
        check_json(model_base, "GET", "/api/model/status", required_keys=("ok", "model_id", "task_status"))
        check_json(model_base, "GET", "/api/icu/timeseries/status", required_keys=("ok", "total_events", "trained_event_count"))
        check_json(model_base, "POST", "/api/training/command", {"action": "stream_metrics"}, ("ok", "metrics", "output"))

    print("smoke test completed")


if __name__ == "__main__":
    main()
