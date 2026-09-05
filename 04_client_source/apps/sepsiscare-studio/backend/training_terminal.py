#!/usr/bin/env python3
"""Training terminal service for SepsisCare.

This module is intentionally separated from patient/history/LLM routes.  Demo
mode simulates model operations without executing shell commands.  Production
mode forwards commands to a configured cloud training service.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request
from urllib.parse import urlparse


TZ = timezone(timedelta(hours=8))
STATE_VERSION = "training-terminal-v1"
MODES = {"demo", "production"}
AUTH_ENV_NAMES = ("SEPSISCARE_TRAINING_TOKEN", "SEPSISCARE_SERVICE_TOKEN")
AUTH_TOKEN_FILE_ENV_NAMES = ("SEPSISCARE_TRAINING_TOKEN_FILE", "SEPSISCARE_SERVICE_TOKEN_FILE")
AUTH_TOKEN_FILE_NAMES = ("sepsiscare_training_token.txt", "sepsiscare_service_token.txt")


def now_text() -> str:
    return datetime.now(TZ).strftime("%Y-%m-%dT%H:%M:%S%z")


def default_params() -> dict[str, Any]:
    return {
        "epochs": 20,
        "batch_size": 64,
        "learning_rate": 0.0008,
        "dataset_version": "packaged-history-20260518",
        "model_version": "S7-contrastive-20260516",
        "checkpoint": "local-demo",
    }


def default_metrics() -> dict[str, Any]:
    return {
        "epoch": 0,
        "progress": 0,
        "loss": 0.436,
        "accuracy": 0.842,
        "macro_f1": 0.817,
    }


def action_catalog() -> list[dict[str, str]]:
    return [
        {"action": "update_database", "title": "更新业务数据库", "shortcut": "Ctrl/Command+1"},
        {"action": "continue_training", "title": "继续训练", "shortcut": "Ctrl/Command+2"},
        {"action": "pause_training", "title": "暂停训练", "shortcut": "Ctrl/Command+3"},
        {"action": "download_artifacts", "title": "下载权重/数据/日志", "shortcut": "Ctrl/Command+4"},
        {"action": "stream_metrics", "title": "查看实时日志与指标", "shortcut": "Ctrl/Command+5"},
        {"action": "switch_mode", "title": "切换演示/生产模式", "shortcut": "Ctrl/Command+6"},
        {"action": "reset_params", "title": "重置训练参数", "shortcut": "Ctrl/Command+7"},
        {"action": "sync_config", "title": "同步配置至云端", "shortcut": "Ctrl/Command+8"},
    ]


class TrainingTerminal:
    def __init__(self, storage_dir: Path, packaged_data_dir: Path | None = None) -> None:
        self.storage_dir = Path(storage_dir)
        self.packaged_data_dir = Path(packaged_data_dir) if packaged_data_dir else None
        self.state_path = self.storage_dir / "training_terminal_state.json"
        self.log_path = self.storage_dir / "training_terminal.log.jsonl"

    def config(self) -> dict[str, Any]:
        return self.status()

    def status(self) -> dict[str, Any]:
        return self._public_status(self._load_state())

    def logs(self, limit: int = 80) -> dict[str, Any]:
        return {
            "ok": True,
            "storage": str(self.log_path),
            "logs": self._read_logs(limit),
        }

    def artifacts(self) -> dict[str, Any]:
        state = self._load_state()
        return {
            "ok": True,
            "mode": state["mode"],
            "artifacts": state.get("artifacts", []),
            "expected_deliverables": [
                "软件一体式安装包",
                "模型本体文件：local_demo 与 cloud_production 分开交付",
                "完整使用说明书与部署对接教程",
            ],
        }

    def update_config(self, payload: dict[str, Any]) -> dict[str, Any]:
        state = self._load_state()
        mode = self._sanitize_mode(payload.get("mode"), state["mode"])
        cloud_url = payload.get("cloud_base_url", payload.get("cloudBaseURL"))
        if cloud_url is not None:
            state["cloud_base_url"] = self._sanitize_cloud_url(str(cloud_url))
        params = payload.get("params")
        if isinstance(params, dict):
            state["params"] = self._merge_params(state.get("params", {}), params)
        state["mode"] = mode
        state["model_profile"] = self._model_profile(mode)
        state["last_action"] = "config_updated"
        state["updated_at"] = now_text()
        self._save_state(state)
        self._append_log("info", "config_updated", "训练终端配置已保存。")
        return self._public_status(state)

    def run_action(self, action: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = payload or {}
        action = str(action or "").strip()
        known_actions = {item["action"] for item in action_catalog()}
        if action not in known_actions:
            return self._error_response("unknown_action", f"未知训练终端动作：{action or '空'}")

        state = self._load_state()
        if action == "switch_mode":
            target_mode = self._sanitize_mode(payload.get("mode") or payload.get("target_mode"), "")
            state["mode"] = target_mode if target_mode else ("production" if state["mode"] == "demo" else "demo")
            state["model_profile"] = self._model_profile(state["mode"])
            state["last_action"] = action
            state["updated_at"] = now_text()
            self._save_state(state)
            output = [
                f"[{now_text()}] 已切换至 {self._mode_label(state['mode'])}。",
                "演示模式使用本地模型占位与内置数据；生产模式仅向云端训练服务下发指令。",
            ]
            self._append_log("info", action, output[-1])
            return self._action_response(True, state, action, output)

        if action == "reset_params":
            state["params"] = default_params()
            state["metrics"] = default_metrics()
            state["task_status"] = "idle"
            state["last_action"] = action
            state["updated_at"] = now_text()
            self._save_state(state)
            output = [
                f"[{now_text()}] 训练参数已重置为课程演示默认值。",
                "epochs=20, batch_size=64, learning_rate=0.0008。",
            ]
            self._append_log("info", action, "训练参数已重置。")
            return self._action_response(True, state, action, output)

        if state["mode"] == "production":
            return self._forward_to_cloud(state, {"type": "action", "action": action, "payload": payload})

        return self._run_demo_action(state, action)

    def run_command(self, command: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = payload or {}
        command = str(command or "").strip()
        if not command:
            return self._error_response("empty_command", "请输入训练终端指令。")
        if len(command) > 300:
            return self._error_response("command_too_long", "单条指令最多 300 个字符。")

        state = self._load_state()
        if state["mode"] == "production":
            return self._forward_to_cloud(state, {"type": "command", "command": command, "payload": payload})

        lowered = command.lower()
        if "status" in lowered or "状态" in lowered:
            return self._action_response(True, state, "custom_command", self._status_lines(state, "手动状态查询"))
        if "metric" in lowered or "loss" in lowered or "日志" in lowered:
            return self._run_demo_action(state, "stream_metrics", command=command)
        if "resume" in lowered or "train" in lowered or "继续" in lowered:
            return self._run_demo_action(state, "continue_training", command=command)
        if "pause" in lowered or "暂停" in lowered:
            return self._run_demo_action(state, "pause_training", command=command)
        if "download" in lowered or "artifact" in lowered or "下载" in lowered:
            return self._run_demo_action(state, "download_artifacts", command=command)

        state["last_action"] = "custom_command"
        state["updated_at"] = now_text()
        self._save_state(state)
        output = [
            f"[{now_text()}] demo 模式已记录自定义指令：{command}",
            "本地演示终端不会执行任意 shell；生产模式配置云端地址后将转发到云端训练服务。",
        ]
        self._append_log("info", "custom_command", output[-1], {"command": command})
        return self._action_response(True, state, "custom_command", output, command=command)

    def _run_demo_action(self, state: dict[str, Any], action: str, command: str | None = None) -> dict[str, Any]:
        metrics = dict(default_metrics())
        metrics.update(state.get("metrics", {}))
        params = dict(default_params())
        params.update(state.get("params", {}))
        output: list[str]

        if action == "update_database":
            state["task_status"] = "idle"
            params["dataset_version"] = "packaged-history-20260518-synced"
            params["last_database_sync"] = now_text()
            output = [
                f"[{now_text()}] 已完成业务数据库更新演示。",
                "历史 ICU 脱敏数据来自安装包 runtime_data；正式投产需由云端训练服务同步真实业务库。",
            ]
        elif action == "continue_training":
            metrics["epoch"] = min(int(metrics.get("epoch", 0)) + 1, int(params.get("epochs", 20)))
            metrics["progress"] = min(100, round(float(metrics["epoch"]) / max(float(params.get("epochs", 20)), 1.0) * 100, 1))
            metrics["loss"] = round(max(0.18, float(metrics.get("loss", 0.436)) * 0.94), 4)
            metrics["accuracy"] = round(min(0.93, float(metrics.get("accuracy", 0.842)) + 0.008), 4)
            metrics["macro_f1"] = round(min(0.91, float(metrics.get("macro_f1", 0.817)) + 0.006), 4)
            state["task_status"] = "running"
            output = [
                f"[{now_text()}] demo 继续训练任务已进入 running。",
                f"epoch={metrics['epoch']}/{params.get('epochs', 20)} loss={metrics['loss']} accuracy={metrics['accuracy']} macro_f1={metrics['macro_f1']}",
            ]
        elif action == "pause_training":
            state["task_status"] = "paused"
            output = [
                f"[{now_text()}] demo 训练任务已暂停。",
                "恢复训练请点击继续训练；正式云端模式会向训练服务发送 pause 指令。",
            ]
        elif action == "download_artifacts":
            state["task_status"] = "idle"
            artifact = {
                "name": "sepsiscare_s7_local_demo_weights.pt",
                "kind": "local_demo_model",
                "size": "课程演示占位",
                "created_at": now_text(),
                "path_hint": "交付物 2 / models/local_demo/",
            }
            artifacts = [artifact] + [item for item in state.get("artifacts", []) if item.get("name") != artifact["name"]]
            state["artifacts"] = artifacts[:8]
            output = [
                f"[{now_text()}] 已生成本地演示权重成果记录。",
                "正式生产模式会从云端下载权重、数据集快照和训练日志到交付目录。",
            ]
        elif action == "stream_metrics":
            if state.get("task_status") == "running":
                metrics["loss"] = round(max(0.18, float(metrics.get("loss", 0.436)) * 0.985), 4)
                metrics["accuracy"] = round(min(0.93, float(metrics.get("accuracy", 0.842)) + 0.001), 4)
            state["params"] = params
            state["metrics"] = metrics
            output = self._status_lines(state, "实时日志与指标")
        elif action == "sync_config":
            state["task_status"] = "synced"
            output = [
                f"[{now_text()}] 本地配置同步演示完成。",
                "生产模式下该动作会把参数、模型版本和数据版本发送至云端训练服务。",
            ]
        else:
            output = [f"[{now_text()}] demo 动作 {action} 已记录。"]

        state["params"] = params
        state["metrics"] = metrics
        state["last_action"] = action
        state["updated_at"] = now_text()
        self._save_state(state)
        self._append_log("info", action, output[-1], {"metrics": metrics, "command": command})
        return self._action_response(True, state, action, output, command=command)

    def _forward_to_cloud(self, state: dict[str, Any], command_payload: dict[str, Any]) -> dict[str, Any]:
        cloud_base_url = self._sanitize_cloud_url(state.get("cloud_base_url", ""))
        if not cloud_base_url:
            return self._action_response(
                False,
                state,
                str(command_payload.get("action") or "custom_command"),
                [
                    f"[{now_text()}] 生产模式未配置云端训练服务地址。",
                    "请在训练终端填写 http(s)://host:port 后再下发云端训练指令。",
                ],
                error="cloud_base_url_not_configured",
                command=command_payload.get("command"),
            )

        endpoint = f"{cloud_base_url.rstrip('/')}/api/training/command"
        request_payload = {
            "client": "sepsiscare-training-terminal",
            "state_version": STATE_VERSION,
            "sent_at": now_text(),
            "mode": state["mode"],
            "model_profile": state["model_profile"],
            "params": state.get("params", {}),
            **command_payload,
        }
        data = json.dumps(request_payload, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        token = self._configured_service_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib_request.Request(endpoint, data=data, headers=headers, method="POST")
        timeout = float(os.getenv("SEPSISCARE_TRAINING_TIMEOUT_SECONDS", "20"))
        try:
            with urllib_request.urlopen(req, timeout=timeout) as response:
                result = json.loads(response.read().decode("utf-8") or "{}")
        except urllib_error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            return self._cloud_error(state, endpoint, command_payload, f"HTTP {exc.code}: {detail}")
        except (urllib_error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            return self._cloud_error(state, endpoint, command_payload, str(exc))

        state["last_action"] = str(command_payload.get("action") or "custom_command")
        state["task_status"] = str(result.get("task_status") or result.get("status") or state.get("task_status", "idle"))
        if isinstance(result.get("metrics"), dict):
            metrics = dict(state.get("metrics", {}))
            metrics.update(result["metrics"])
            state["metrics"] = metrics
        if isinstance(result.get("artifacts"), list):
            state["artifacts"] = result["artifacts"]
        state["updated_at"] = now_text()
        self._save_state(state)

        output = result.get("output") or result.get("logs") or []
        if isinstance(output, str):
            output = [output]
        if not isinstance(output, list):
            output = [json.dumps(result, ensure_ascii=False)]
        output = [f"[{now_text()}] 已转发至云端训练服务：{endpoint}"] + [str(line) for line in output]
        self._append_log("info", state["last_action"], "云端训练服务已返回结果。", {"endpoint": endpoint})
        return self._action_response(
            True,
            state,
            state["last_action"],
            output,
            command=command_payload.get("command"),
            cloud_response=result,
        )

    def _cloud_error(self, state: dict[str, Any], endpoint: str, payload: dict[str, Any], detail: str) -> dict[str, Any]:
        state["task_status"] = "error"
        state["last_action"] = str(payload.get("action") or "custom_command")
        state["updated_at"] = now_text()
        self._save_state(state)
        message = f"云端训练服务连接失败：{detail[:220]}"
        self._append_log("error", state["last_action"], message, {"endpoint": endpoint})
        return self._action_response(
            False,
            state,
            state["last_action"],
            [f"[{now_text()}] {message}", f"endpoint={endpoint}"],
            error="cloud_forward_failed",
            command=payload.get("command"),
        )

    def _configured_service_token(self) -> str:
        for name in AUTH_ENV_NAMES:
            value = os.getenv(name, "").strip()
            if value:
                return value
        if os.getenv("SEPSISCARE_DISABLE_TOKEN_FILE_LOOKUP", "").strip().lower() in {"1", "true", "yes"}:
            return ""
        for path in self._service_token_file_candidates():
            try:
                value = path.read_text(encoding="utf-8").strip()
            except OSError:
                continue
            if value:
                return value
        return ""

    def _service_token_file_candidates(self) -> list[Path]:
        candidates: list[Path] = []
        for name in AUTH_TOKEN_FILE_ENV_NAMES:
            raw_path = os.getenv(name, "").strip()
            if raw_path:
                candidates.append(Path(raw_path).expanduser())
        for filename in AUTH_TOKEN_FILE_NAMES:
            candidates.append(self.storage_dir / filename)
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

    def _load_state(self) -> dict[str, Any]:
        state = self._default_state()
        if self.state_path.exists():
            try:
                loaded = json.loads(self.state_path.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    state.update({key: value for key, value in loaded.items() if value is not None})
            except (OSError, json.JSONDecodeError):
                pass
        state["mode"] = self._sanitize_mode(state.get("mode"), "demo")
        if not state.get("cloud_base_url"):
            state["cloud_base_url"] = self._env_cloud_base_url()
        state["cloud_base_url"] = self._sanitize_cloud_url(state.get("cloud_base_url", ""))
        state["model_profile"] = self._model_profile(state["mode"])
        state["params"] = self._merge_params(default_params(), state.get("params", {}))
        metrics = default_metrics()
        if isinstance(state.get("metrics"), dict):
            metrics.update(state["metrics"])
        state["metrics"] = metrics
        if not isinstance(state.get("artifacts"), list):
            state["artifacts"] = []
        return state

    def _save_state(self, state: dict[str, Any]) -> None:
        self.storage_dir.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")

    def _append_log(self, level: str, action: str, message: str, extra: dict[str, Any] | None = None) -> None:
        self.storage_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "ts": now_text(),
            "level": level,
            "source": "training_terminal",
            "action": action,
            "message": message,
        }
        if extra:
            record.update({key: value for key, value in extra.items() if value is not None})
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")

    def _read_logs(self, limit: int) -> list[dict[str, Any]]:
        if not self.log_path.exists():
            return []
        try:
            limit = max(1, min(int(limit), 300))
        except (TypeError, ValueError):
            limit = 80
        rows: list[dict[str, Any]] = []
        for line in self.log_path.read_text(encoding="utf-8").splitlines()[-limit:]:
            try:
                record = json.loads(line)
                if isinstance(record, dict):
                    rows.append(record)
            except json.JSONDecodeError:
                pass
        return rows

    def _default_state(self) -> dict[str, Any]:
        mode = self._sanitize_mode(os.getenv("SEPSISCARE_TRAINING_MODE", "demo"), "demo")
        return {
            "version": STATE_VERSION,
            "mode": mode,
            "cloud_base_url": self._env_cloud_base_url(),
            "model_profile": self._model_profile(mode),
            "task_status": "idle",
            "last_action": "initialized",
            "updated_at": now_text(),
            "params": default_params(),
            "metrics": default_metrics(),
            "artifacts": [],
        }

    def _public_status(self, state: dict[str, Any]) -> dict[str, Any]:
        return {
            "ok": True,
            "version": STATE_VERSION,
            "mode": state["mode"],
            "mode_label": self._mode_label(state["mode"]),
            "model_profile": state["model_profile"],
            "task_status": state.get("task_status", "idle"),
            "cloud_base_url": state.get("cloud_base_url", ""),
            "cloud_ready": bool(state.get("cloud_base_url")),
            "last_action": state.get("last_action", "initialized"),
            "updated_at": state.get("updated_at", now_text()),
            "params": state.get("params", default_params()),
            "metrics": state.get("metrics", default_metrics()),
            "artifacts": state.get("artifacts", []),
            "actions": action_catalog(),
            "shortcuts": {item["action"]: item["shortcut"] for item in action_catalog()},
            "delivery_contract": {
                "installer": "软件一体式安装包",
                "models": ["local_demo", "cloud_production"],
                "docs": "完整使用说明书、云端部署对接流程、快捷键释义",
            },
            "notice": self._mode_notice(state["mode"], bool(state.get("cloud_base_url"))),
        }

    def _action_response(
        self,
        ok: bool,
        state: dict[str, Any],
        action: str,
        output: list[str],
        error: str | None = None,
        command: Any = None,
        cloud_response: Any = None,
    ) -> dict[str, Any]:
        response = {
            "ok": ok,
            "mode": state["mode"],
            "action": action,
            "command": command,
            "output": output,
            "status": self._public_status(state),
        }
        if error:
            response["error"] = error
        if cloud_response is not None:
            response["cloud_response"] = cloud_response
        return response

    def _error_response(self, code: str, message: str) -> dict[str, Any]:
        return {
            "ok": False,
            "error": code,
            "output": [f"[{now_text()}] {message}"],
            "status": self.status(),
        }

    def _status_lines(self, state: dict[str, Any], title: str) -> list[str]:
        metrics = dict(default_metrics())
        metrics.update(state.get("metrics", {}))
        params = dict(default_params())
        params.update(state.get("params", {}))
        return [
            f"[{now_text()}] {title}",
            f"mode={state['mode']} profile={state['model_profile']} status={state.get('task_status', 'idle')}",
            f"dataset={params.get('dataset_version')} checkpoint={params.get('checkpoint')}",
            f"epoch={metrics.get('epoch')}/{params.get('epochs')} progress={metrics.get('progress')}% loss={metrics.get('loss')} accuracy={metrics.get('accuracy')} macro_f1={metrics.get('macro_f1')}",
        ]

    def _merge_params(self, base: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
        merged = dict(base)
        for key, value in incoming.items():
            if key in {"epochs", "batch_size"}:
                try:
                    merged[key] = max(1, int(value))
                except (TypeError, ValueError):
                    continue
            elif key == "learning_rate":
                try:
                    merged[key] = max(0.000001, float(value))
                except (TypeError, ValueError):
                    continue
            elif isinstance(value, (str, int, float, bool)):
                merged[key] = value
        return merged

    def _sanitize_mode(self, value: Any, fallback: str) -> str:
        mode = str(value or "").strip().lower()
        if mode in MODES:
            return mode
        fallback = str(fallback or "demo").strip().lower()
        return fallback if fallback in MODES else "demo"

    def _sanitize_cloud_url(self, value: Any) -> str:
        text = str(value or "").strip().rstrip("/")
        if not text:
            return ""
        parsed = urlparse(text)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return ""
        return text

    def _env_cloud_base_url(self) -> str:
        return self._sanitize_cloud_url(os.getenv("SEPSISCARE_TRAINING_CLOUD_URL", ""))

    def _model_profile(self, mode: str) -> str:
        return "cloud_production" if mode == "production" else "local_demo"

    def _mode_label(self, mode: str) -> str:
        return "云端生产模式" if mode == "production" else "本地演示模式"

    def _mode_notice(self, mode: str, cloud_ready: bool) -> str:
        if mode == "production":
            if cloud_ready:
                return "生产模式会将训练指令转发到云端算力服务器；请确认云端模型服务已部署。"
            return "生产模式尚未配置云端训练服务地址，训练指令不会被执行。"
        return "演示模式仅使用本地安装包数据和模型占位，不消耗云端算力，适合课程答辩展示。"
