#!/usr/bin/env python3
"""Send controlled SepsisCare remote-ops commands to the ROG model service."""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import sys
import time
import zipfile
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request


DEFAULT_BASE_URL = "http://100.65.136.96:8788"
DEFAULT_TOKEN_ENV = "SEPSISCARE_SERVICE_TOKEN"
REMOTE_OPS_STATUS_PATH = "/api/admin/remote-ops/status"
REMOTE_OPS_COMMAND_PATH = "/api/admin/remote-ops/command"
UPDATE_FILES = [
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
]


class RemoteOpsCommandError(Exception):
    def __init__(self, status_code: int, error: str, detail: str):
        super().__init__(detail)
        self.status_code = status_code
        self.error = error
        self.detail = detail


def delivery_root_for_bundle(bundle_root: Path) -> Path:
    if bundle_root.name == "rog_actual_training_update" and bundle_root.parent.name == "06_scripts":
        return bundle_root.parent.parent
    return bundle_root


def source_for_update_entry(bundle_root: Path, entry: str) -> Path:
    delivery_root = delivery_root_for_bundle(bundle_root)
    candidates: list[Path] = [bundle_root / entry]
    if entry.startswith("deploy/"):
        candidates.append(
            delivery_root
            / "03_remote_server_model_package"
            / "02_model_deploy_package"
            / "deploy"
            / entry.removeprefix("deploy/")
        )
    elif entry.startswith("scripts/"):
        candidates.append(bundle_root / Path(entry).name)
    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate
    searched = ", ".join(str(candidate) for candidate in candidates)
    raise FileNotFoundError(f"Missing update source for {entry}. Searched: {searched}")


def build_update_zip(bundle_root: Path) -> tuple[bytes, str, list[str]]:
    bundle_root = bundle_root.resolve()
    entries: list[str] = []
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for entry in UPDATE_FILES:
            source = source_for_update_entry(bundle_root, entry)
            archive.writestr(entry, source.read_bytes())
            entries.append(entry)
    blob = buffer.getvalue()
    return blob, hashlib.sha256(blob).hexdigest(), entries


def decode_response_body(body: bytes) -> dict[str, Any]:
    text = body.decode("utf-8", errors="replace")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return {"error": "non_json_response", "detail": text[:1000]}
    if isinstance(payload, dict):
        return payload
    return {"error": "unexpected_json_response", "detail": text[:1000]}


def request_json(base_url: str, path: str, token: str, payload: dict[str, Any] | None, timeout: int) -> dict[str, Any]:
    url = base_url.rstrip("/") + path
    headers = {"Accept": "application/json"}
    data = None
    method = "GET"
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib_request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib_request.urlopen(req, timeout=timeout) as response:
            return decode_response_body(response.read())
    except urllib_error.HTTPError as exc:
        details = decode_response_body(exc.read())
        raise RemoteOpsCommandError(
            exc.code,
            str(details.get("error") or "http_error"),
            str(details.get("detail") or details.get("message") or details),
        ) from exc
    except urllib_error.URLError as exc:
        raise RemoteOpsCommandError(0, "connection_failed", str(exc.reason)) from exc


def get_status(base_url: str, token: str, timeout: int) -> dict[str, Any]:
    return request_json(base_url, REMOTE_OPS_STATUS_PATH, token, None, timeout)


def post_command(base_url: str, token: str, payload: dict[str, Any], timeout: int) -> dict[str, Any]:
    return request_json(base_url, REMOTE_OPS_COMMAND_PATH, token, payload, timeout)


def load_token(args: argparse.Namespace) -> str:
    if args.token:
        return args.token.strip()
    return os.getenv(args.token_env, "").strip()


def require_token(args: argparse.Namespace) -> str:
    token = load_token(args)
    if token or args.allow_no_token:
        return token
    raise SystemExit(f"Missing bearer token. Set {args.token_env} or pass --token.")


def print_json(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


def write_evidence(path: str, payload: dict[str, Any]) -> None:
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def bootstrap_required_message(base_url: str) -> str:
    return (
        f"{base_url.rstrip('/')}{REMOTE_OPS_STATUS_PATH} is not available. "
        "Bootstrap the ROG once by running install_and_verify_rog_actual_training.cmd on the ROG desktop, "
        "or use an authenticated OS channel to install the update bundle, then rerun this command."
    )


def run_status(args: argparse.Namespace, token: str) -> dict[str, Any]:
    return get_status(args.base_url, token, args.timeout)


def run_apply_update(args: argparse.Namespace, token: str) -> dict[str, Any]:
    blob, digest, entries = build_update_zip(Path(args.bundle_root))
    payload = {
        "action": "apply_update_zip",
        "zip_base64": base64.b64encode(blob).decode("ascii"),
        "sha256": digest,
    }
    result = post_command(args.base_url, token, payload, args.timeout)
    result["local_update_sha256"] = digest
    result["local_update_entries"] = entries
    return result


def run_restart(args: argparse.Namespace, token: str) -> dict[str, Any]:
    payload = {
        "action": "restart_service",
        "host_address": args.host_address,
        "port": args.port,
        "add_firewall_rule": bool(args.add_firewall_rule),
    }
    return post_command(args.base_url, token, payload, args.timeout)


def run_verify(args: argparse.Namespace, token: str) -> dict[str, Any]:
    return post_command(args.base_url, token, {"action": "verify_actual_training"}, args.timeout)


def wait_for_remote_ops(args: argparse.Namespace, token: str) -> dict[str, Any]:
    deadline = time.monotonic() + args.restart_wait_seconds
    last_error = ""
    while time.monotonic() < deadline:
        try:
            return run_status(args, token)
        except RemoteOpsCommandError as exc:
            last_error = f"{exc.status_code} {exc.error}: {exc.detail}"
            time.sleep(2)
    raise RemoteOpsCommandError(0, "restart_not_ready", f"Remote ops did not return before timeout. Last error: {last_error}")


def run_full(args: argparse.Namespace, token: str) -> dict[str, Any]:
    initial_status = run_status(args, token)
    apply_update = run_apply_update(args, token)
    restart = run_restart(args, token)
    ready_status = wait_for_remote_ops(args, token)
    verification = run_verify(args, token)
    return {
        "ok": True,
        "action": "full",
        "initial_status": initial_status,
        "apply_update": apply_update,
        "restart": restart,
        "ready_status": ready_status,
        "verification": verification,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send controlled SepsisCare remote-ops commands to ROG.")
    parser.add_argument(
        "action",
        choices=("status", "apply-update", "restart-service", "verify-actual-training", "full"),
        help="Remote operation to run.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help=f"ROG model-service URL. Default: {DEFAULT_BASE_URL}")
    parser.add_argument("--token-env", default=DEFAULT_TOKEN_ENV, help=f"Environment variable containing the bearer token. Default: {DEFAULT_TOKEN_ENV}")
    parser.add_argument("--token", default="", help="Bearer token. Prefer --token-env to avoid shell history.")
    parser.add_argument("--allow-no-token", action="store_true", help="Allow requests without Authorization for loopback-only checks.")
    parser.add_argument("--bundle-root", default=str(Path(__file__).resolve().parent), help="Path to rog_actual_training_update bundle root.")
    parser.add_argument("--host-address", default="0.0.0.0", help="HostAddress passed to remote restart_service.")
    parser.add_argument("--port", type=int, default=8788, help="Port passed to remote restart_service.")
    parser.add_argument("--add-firewall-rule", action="store_true", help="Ask ROG restart_service to refresh the Windows firewall rule.")
    parser.add_argument("--timeout", type=int, default=30, help="HTTP timeout in seconds.")
    parser.add_argument("--restart-wait-seconds", type=int, default=90, help="How long full mode waits for ROG to come back after restart.")
    parser.add_argument("--evidence-out", default="", help="Optional local JSON file for the command result.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    token = require_token(args)
    try:
        if args.action == "status":
            result = run_status(args, token)
        elif args.action == "apply-update":
            result = run_apply_update(args, token)
        elif args.action == "restart-service":
            result = run_restart(args, token)
        elif args.action == "verify-actual-training":
            result = run_verify(args, token)
        else:
            result = run_full(args, token)
    except RemoteOpsCommandError as exc:
        if exc.status_code == 404:
            print(bootstrap_required_message(args.base_url), file=sys.stderr)
            return 4
        if exc.status_code in {401, 403}:
            print(f"Remote ops authorization failed ({exc.status_code} {exc.error}): {exc.detail}", file=sys.stderr)
            return 3
        print(f"Remote ops failed ({exc.status_code} {exc.error}): {exc.detail}", file=sys.stderr)
        return 2
    write_evidence(args.evidence_out, result)
    print_json(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
