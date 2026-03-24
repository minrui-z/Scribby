from __future__ import annotations

import sys
import platform
import traceback
from pathlib import Path
from typing import Any


THIS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = THIS_DIR.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from desktop.adapters.transcription_service import TranscriptionService
from desktop.ipc_protocol import dumps_message, loads_message, make_event, make_response, validate_command


class IPCWriter:
    def __init__(self) -> None:
        self._stream = sys.stdout

    def write(self, message: dict[str, Any]) -> None:
        self._stream.write(dumps_message(message) + "\n")
        self._stream.flush()


def ensure_supported_platform() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("桌面版目前只支援 macOS Apple Silicon")


def normalize_item(item: dict[str, Any]) -> dict[str, Any]:
    result = item.get("result") or {}
    return {
        "id": item.get("id") or item.get("fileId") or item.get("file_id"),
        "file_id": item.get("file_id") or item.get("fileId") or item.get("id"),
        "fileId": item.get("fileId") or item.get("file_id") or item.get("id"),
        "name": item.get("filename") or item.get("name") or item.get("original_name"),
        "filename": item.get("filename") or item.get("name") or item.get("original_name"),
        "size": item.get("size", 0),
        "status": item.get("status", "pending"),
        "progress": item.get("progress", 0),
        "message": item.get("message", ""),
        "error": item.get("error"),
        "result": result if result else None,
    }


def normalize_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    items = [normalize_item(item) for item in snapshot.get("items", [])]
    counts = {
        "pending": sum(1 for item in items if item["status"] == "pending"),
        "processing": sum(1 for item in items if item["status"] == "processing"),
        "done": sum(1 for item in items if item["status"] == "done"),
        "error": sum(1 for item in items if item["status"] == "error"),
        "stopped": sum(1 for item in items if item["status"] == "stopped"),
    }
    return {
        "running": bool(snapshot.get("isProcessing")),
        "paused": bool(snapshot.get("isPaused")),
        "stop_requested": bool(snapshot.get("stopRequested")),
        "supports_hard_stop": bool(snapshot.get("supportsHardStop")),
        "current_file_id": snapshot.get("currentFileId"),
        "counts": counts,
        "queue": items,
        "items": items,
    }


def normalize_event(event: str, payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    if event == "queue_updated":
        return event, normalize_snapshot(payload)

    if event == "task_started":
        file_id = payload.get("fileId") or payload.get("file_id") or payload.get("task_id")
        return event, {
            "task_id": file_id,
            "file_id": file_id,
            "fileId": file_id,
            "filename": payload.get("filename") or payload.get("name"),
            "file_count": payload.get("file_count") or payload.get("total"),
            "index": payload.get("index"),
            "total": payload.get("total"),
        }

    if event == "task_progress":
        file_id = payload.get("fileId") or payload.get("file_id") or payload.get("task_id")
        return event, {
            "task_id": file_id,
            "file_id": file_id,
            "fileId": file_id,
            "event": payload.get("phase") or payload.get("event"),
            "message": payload.get("message", ""),
            "progress": payload.get("progress"),
        }

    if event == "task_partial_text":
        file_id = payload.get("fileId") or payload.get("file_id") or payload.get("task_id")
        return event, {
            "task_id": file_id,
            "file_id": file_id,
            "fileId": file_id,
            "text": payload.get("text", ""),
        }

    if event == "task_completed":
        file_id = payload.get("fileId") or payload.get("file_id") or payload.get("task_id")
        result = payload.get("result") or {}
        return event, {
            "task_id": file_id,
            "file_id": file_id,
            "fileId": file_id,
            "text": result.get("text", ""),
            "language": result.get("language"),
            "count": result.get("count", 0),
            "has_speakers": bool(result.get("has_speakers", False)),
            "download": result.get("download"),
            "filename": payload.get("filename") or result.get("suggestedFilename"),
            "result": result,
        }

    if event in {"task_failed", "task_stopped"}:
        file_id = payload.get("fileId") or payload.get("file_id") or payload.get("task_id")
        normalized = {
            "task_id": file_id,
            "file_id": file_id,
            "fileId": file_id,
            "message": payload.get("message", ""),
        }
        if "traceback" in payload:
            normalized["traceback"] = payload["traceback"]
        return event, normalized

    if event == "backend_ready":
        info = payload.get("info") if isinstance(payload.get("info"), dict) else payload
        return event, {"info": info}

    return event, payload


def main() -> int:
    ensure_supported_platform()
    writer = IPCWriter()
    root = PROJECT_ROOT

    def emit(event: str, payload: dict[str, Any]) -> None:
        normalized_event, normalized_payload = normalize_event(event, payload)
        writer.write(make_event(normalized_event, normalized_payload))

    service = TranscriptionService(emit_event=emit, project_root=root)

    def snapshot() -> dict[str, Any]:
        return normalize_snapshot(service._snapshot_locked())  # noqa: SLF001

    def handle_get_info(_: dict[str, Any]) -> dict[str, Any]:
        info = service.get_info()
        info["desktop_backend"] = True
        info["state"] = snapshot()
        return info

    def handle_verify_token(payload: dict[str, Any]) -> dict[str, Any]:
        return service.verify_token(str(payload.get("token") or ""))

    def handle_enqueue_files(payload: dict[str, Any]) -> dict[str, Any]:
        result = service.enqueue_files(payload.get("files") or payload.get("paths") or [])
        return {
            "queued": [normalize_item(item) for item in result.get("added", [])],
            "queue": normalize_snapshot(result.get("state", {})),
        }

    def handle_start_transcription(payload: dict[str, Any]) -> dict[str, Any]:
        result = service.start_transcription(payload)
        return {
            "started": bool(result.get("started")),
            "queue": normalize_snapshot(result.get("state", {})),
        }

    def handle_pause_queue(payload: dict[str, Any]) -> dict[str, Any]:
        paused = payload.get("paused")
        if isinstance(paused, str):
            paused = paused.lower() not in {"false", "0", "off", "no"}
        if paused is None:
            paused = not snapshot()["paused"]
        result = service.pause_queue(bool(paused))
        paused_state = bool(result.get("state", {}).get("isPaused"))
        if paused_state:
            emit("queue_paused", {"message": "佇列已暫停", "paused": True})
        else:
            emit("queue_resumed", {"message": "佇列已恢復", "paused": False})
        return {"paused": paused_state, "queue": normalize_snapshot(result.get("state", {}))}

    def handle_stop_current(_: dict[str, Any]) -> dict[str, Any]:
        result = service.stop_current()
        return {
            "stopping": bool(result.get("accepted")),
            "hard_stopped": bool(result.get("hard_stop")),
            "supports_hard_stop": bool(result.get("state", {}).get("supportsHardStop", False)),
            "message": result.get("message", ""),
            "current_file_id": result.get("state", {}).get("currentFileId"),
            "queue": normalize_snapshot(result.get("state", {})),
        }

    def handle_clear_queue(_: dict[str, Any]) -> dict[str, Any]:
        result = service.clear_queue()
        return {"queue": normalize_snapshot(result.get("state", {}))}

    def handle_subscribe_events(_: dict[str, Any]) -> dict[str, Any]:
        return {"subscribed": True}

    def handle_save_result(payload: dict[str, Any]) -> dict[str, Any]:
        file_id = str(payload.get("file_id") or payload.get("id") or "")
        destination = str(
            payload.get("destination_path")
            or payload.get("path")
            or payload.get("destination")
            or payload.get("filePath")
            or ""
        )
        return service.save_result(file_id, destination)

    def handle_save_all_results(payload: dict[str, Any]) -> dict[str, Any]:
        raw_ids = payload.get("file_ids") or payload.get("fileIds") or payload.get("ids")
        if isinstance(raw_ids, str):
            file_ids = [item.strip() for item in raw_ids.split(",") if item.strip()]
        elif isinstance(raw_ids, list):
            file_ids = [str(item) for item in raw_ids if str(item).strip()]
        else:
            file_ids = None
        destination = str(
            payload.get("destination_path")
            or payload.get("path")
            or payload.get("destination")
            or payload.get("filePath")
            or ""
        )
        result = service.save_all_results(file_ids, destination)
        return {"path": result.get("path"), "count": len(file_ids or []) or snapshot()["counts"]["done"]}

    handlers = {
        "get_info": handle_get_info,
        "verify_token": handle_verify_token,
        "enqueue_files": handle_enqueue_files,
        "start_transcription": handle_start_transcription,
        "pause_queue": handle_pause_queue,
        "stop_current": handle_stop_current,
        "clear_queue": handle_clear_queue,
        "subscribe_events": handle_subscribe_events,
        "save_result": handle_save_result,
        "save_all_results": handle_save_all_results,
        "shutdown": lambda payload: {"shutdown": True},
    }

    writer.write(make_event("backend_ready", {"info": handle_get_info({})}))

    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue

            command_id = ""
            try:
                message = validate_command(loads_message(line))
                command_id = message["id"]
                result = handlers[message["command"]](message["payload"])
                writer.write(make_response(message["id"], True, result=result))
                if message["command"] == "shutdown":
                    return 0
            except Exception as exc:  # pragma: no cover - bridge-level fallback
                error_payload = {"message": str(exc)}
                if command_id:
                    writer.write(make_response(command_id, False, error=error_payload))
                writer.write(
                    make_event(
                        "backend_error",
                        {
                            "message": str(exc),
                            "traceback": traceback.format_exc(),
                        },
                    )
                )
    except KeyboardInterrupt:
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
