from __future__ import annotations

import json
import uuid
from typing import Any, Iterable


RESPONSE_KIND = "response"
EVENT_KIND = "event"
COMMAND_KIND = "command"

COMMANDS = {
    "get_info",
    "verify_token",
    "enqueue_files",
    "start_transcription",
    "pause_queue",
    "stop_current",
    "clear_queue",
    "save_result",
    "save_all_results",
    "shutdown",
}


def encode_message(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def decode_message(line: str) -> dict[str, Any]:
    data = json.loads(line)
    if not isinstance(data, dict):
        raise ValueError("IPC payload 必須為 JSON 物件")
    return data


def response(request_id: str, ok: bool, result: Any = None, error: str | None = None) -> dict[str, Any]:
    payload = {
        "kind": RESPONSE_KIND,
        "id": request_id,
        "request_id": request_id,
        "ok": ok,
    }
    if ok:
        payload["result"] = result
    else:
        payload["error"] = error or "未知錯誤"
    return payload


def event(name: str, data: Any) -> dict[str, Any]:
    return {
        "kind": EVENT_KIND,
        "event": name,
        "data": data,
        "payload": data,
    }


def new_id() -> str:
    return uuid.uuid4().hex


def make_command(command: str, payload: dict[str, Any] | None = None, id: str | None = None) -> dict[str, Any]:
    return {
        "kind": COMMAND_KIND,
        "id": id or new_id(),
        "command": command,
        "payload": payload or {},
    }


def make_response(
    id: str,
    ok: bool,
    result: dict[str, Any] | None = None,
    error: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = {
        "kind": RESPONSE_KIND,
        "id": id,
        "request_id": id,
        "ok": ok,
    }
    if ok and result is not None:
        payload["result"] = result
    if not ok:
        payload["error"] = error or {"message": "未知錯誤"}
    return payload


def make_event(name: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    data = payload or {}
    return {"kind": EVENT_KIND, "event": name, "data": data, "payload": data}


def dumps_message(message: dict[str, Any]) -> str:
    return encode_message(message)


def loads_message(line: str) -> dict[str, Any]:
    return decode_message(line)


def validate_command(message: dict[str, Any]) -> dict[str, Any]:
    kind = message.get("kind") or COMMAND_KIND
    if kind != COMMAND_KIND:
        raise ValueError("Unsupported message kind")
    command = message.get("command")
    if command not in COMMANDS:
        raise ValueError(f"Unsupported command: {command}")
    request_id = message.get("id") or message.get("request_id")
    if not isinstance(request_id, str) or not request_id.strip():
        raise ValueError("Command id is required")
    payload = message.get("payload")
    if payload is None:
        payload = message.get("args")
    payload = payload or {}
    if not isinstance(payload, dict):
        raise ValueError("Command payload must be an object")
    return {
        "id": request_id,
        "command": command,
        "payload": payload,
    }


def ensure_string_list(value: Any) -> list[str]:
    if not value:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, Iterable):
        return [str(item) for item in value if isinstance(item, str)]
    return []
