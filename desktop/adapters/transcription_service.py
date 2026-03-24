from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import gc
from pathlib import Path
from typing import Any, Callable

import engine

from desktop.adapters import mlx_runtime
from desktop.adapters.file_export import transcript_filename, write_transcript, write_zip


EVENT_PREFIX = "__EVENT__:"
IGNORED_STDERR_SNIPPETS = (
    "resource_tracker: There appear to be",
    "warnings.warn('resource_tracker:",
)


class TaskStopped(RuntimeError):
    pass


class TranscriptionService:
    def __init__(self, emit_event: Callable[[str, dict[str, Any]], None], project_root: Path):
        self.emit_event = emit_event
        self.project_root = project_root
        self.output_dir = Path(tempfile.gettempdir()) / "desktop_transcriber_outputs"
        self.output_dir.mkdir(exist_ok=True)

        self._lock = threading.RLock()
        self._items: list[dict[str, Any]] = []
        self._processing_thread: threading.Thread | None = None
        self._is_processing = False
        self._is_paused = False
        self._stop_requested = False
        self._current_file_id: str | None = None
        self._current_mode: str | None = None
        self._current_process: subprocess.Popen[str] | None = None
        self._current_stop_kind: str | None = None
        self._last_options: dict[str, Any] = {
            "language": "zh",
            "diarize": False,
            "speakers": 0,
            "token": "",
        }
        self._mlx_policy: dict[str, Any] | None = None

    def get_info(self) -> dict[str, Any]:
        info = engine.get_engine_info()
        info["supports_hard_stop"] = info["engine"] != "mlx"
        if self._mlx_policy:
            info["mlx_memory_policy"] = self._mlx_policy
        return info

    def verify_token(self, token: str) -> dict[str, Any]:
        ok, message = engine.verify_hf_token(token)
        return {"ok": ok, "message": message}

    def enqueue_files(self, paths: list[str]) -> dict[str, Any]:
        added = []
        with self._lock:
            for raw_path in paths:
                path = Path(raw_path).expanduser().resolve()
                if not path.exists() or not path.is_file():
                    continue

                item = {
                    "id": str(uuid.uuid4()),
                    "fileId": str(uuid.uuid4()),
                    "path": str(path),
                    "filename": path.name,
                    "size": path.stat().st_size,
                    "status": "pending",
                    "progress": 0,
                    "message": "",
                    "result": None,
                    "error": None,
                }
                self._items.append(item)
                added.append(self._serialize_item(item))

            snapshot = self._snapshot_locked()

        self.emit_event("queue_updated", snapshot)
        return {"added": added, "state": snapshot}

    def start_transcription(self, options: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self._last_options = {
                "language": options.get("language", "zh") or "zh",
                "diarize": bool(options.get("diarize", False)),
                "speakers": int(options.get("speakers", 0) or 0),
                "token": (options.get("token", "") or "").strip(),
            }

            if self._is_processing:
                return {"started": False, "state": self._snapshot_locked()}

            pending_exists = any(item["status"] == "pending" for item in self._items)
            if not pending_exists:
                return {"started": False, "state": self._snapshot_locked()}

            self._is_processing = True
            self._is_paused = False
            self._stop_requested = False
            self._processing_thread = threading.Thread(target=self._run_queue, daemon=True)
            self._processing_thread.start()
            snapshot = self._snapshot_locked()

        self.emit_event("queue_updated", snapshot)
        return {"started": True, "state": snapshot}

    def pause_queue(self, paused: bool) -> dict[str, Any]:
        with self._lock:
            self._is_paused = bool(paused)
            snapshot = self._snapshot_locked()
        self.emit_event("queue_updated", snapshot)
        return {"state": snapshot}

    def stop_current(self) -> dict[str, Any]:
        process = None
        with self._lock:
            if not self._is_processing:
                return {"accepted": False, "message": "目前沒有執行中的任務"}

            if self._current_mode == "mlx":
                self._stop_requested = True
                self._is_paused = False
                snapshot = self._snapshot_locked()
                self.emit_event("queue_updated", snapshot)
                return {
                    "accepted": True,
                    "hard_stop": False,
                    "message": "MLX 模式目前不支援硬停止，會在這一份完成後停止剩餘批次。",
                    "state": snapshot,
                }

            process = self._current_process
            self._stop_requested = True
            self._is_paused = False
            self._current_stop_kind = "hard"
            snapshot = self._snapshot_locked()

        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

        self.emit_event("queue_updated", snapshot)
        return {
            "accepted": True,
            "hard_stop": True,
            "message": "已停止目前任務",
            "state": snapshot,
        }

    def save_result(self, file_id: str, destination_path: str) -> dict[str, Any]:
        item = self._find_item(file_id)
        if not item or not item.get("result"):
            raise ValueError("找不到可匯出的結果")

        written = write_transcript(destination_path, item["result"]["text"])
        return {"path": written}

    def clear_queue(self) -> dict[str, Any]:
        with self._lock:
            if self._is_processing:
                raise ValueError("轉譯進行中無法清除序列")
            self._items = []
            snapshot = self._snapshot_locked()
        self.emit_event("queue_updated", snapshot)
        return {"state": snapshot}

    def save_all_results(self, file_ids: list[str] | None, destination_path: str) -> dict[str, Any]:
        entries: list[tuple[str, str]] = []
        target_ids = file_ids or []
        if not target_ids:
            with self._lock:
                target_ids = [item["fileId"] for item in self._items if item.get("result")]

        for file_id in target_ids:
            item = self._find_item(file_id)
            if item and item.get("result"):
                entries.append((item["result"]["suggestedFilename"], item["result"]["text"]))

        if not entries:
            raise ValueError("沒有可匯出的結果")

        written = write_zip(destination_path, entries)
        return {"path": written}

    def _find_item(self, file_id: str) -> dict[str, Any] | None:
        with self._lock:
            for item in self._items:
                if item["fileId"] == file_id:
                    return item
        return None

    def _run_queue(self) -> None:
        try:
            while True:
                while True:
                    with self._lock:
                        paused = self._is_paused
                        stop_requested = self._stop_requested
                    if not paused:
                        break
                    if stop_requested:
                        break
                    time.sleep(0.15)

                item = self._next_pending_item()
                if item is None:
                    break

                with self._lock:
                    item["status"] = "processing"
                    item["progress"] = 5
                    item["message"] = "準備中..."
                    snapshot = self._snapshot_locked()
                self.emit_event("queue_updated", snapshot)
                self.emit_event("task_started", {"fileId": item["fileId"], "filename": item["filename"]})

                try:
                    self._process_item(item)
                except TaskStopped as exc:
                    with self._lock:
                        item["status"] = "stopped"
                        item["error"] = str(exc)
                        item["message"] = str(exc)
                        snapshot = self._snapshot_locked()
                    self.emit_event("task_stopped", {"fileId": item["fileId"], "message": str(exc)})
                    self.emit_event("queue_updated", snapshot)
                    break
                except Exception as exc:  # pragma: no cover - runtime-facing fallback
                    with self._lock:
                        item["status"] = "error"
                        item["error"] = str(exc)
                        item["message"] = str(exc)
                        snapshot = self._snapshot_locked()
                    self.emit_event("task_failed", {"fileId": item["fileId"], "message": str(exc)})
                    self.emit_event("queue_updated", snapshot)

                with self._lock:
                    if self._stop_requested:
                        break
        finally:
            with self._lock:
                self._is_processing = False
                self._is_paused = False
                self._stop_requested = False
                self._current_file_id = None
                self._current_mode = None
                self._current_process = None
                self._current_stop_kind = None
                snapshot = self._snapshot_locked()
            self.emit_event("queue_updated", snapshot)

    def _next_pending_item(self) -> dict[str, Any] | None:
        with self._lock:
            if self._stop_requested:
                return None
            for item in self._items:
                if item["status"] == "pending":
                    return item
        return None

    def _process_item(self, item: dict[str, Any]) -> None:
        with self._lock:
            self._current_file_id = item["fileId"]
            self._current_mode = engine.ENGINE
            self._current_stop_kind = None

        if engine.ENGINE == "mlx":
            self._process_item_mlx(item)
        else:
            self._process_item_subprocess(item)

    def _process_item_mlx(self, item: dict[str, Any]) -> None:
        options = self._last_options.copy()
        self._ensure_mlx_policy()

        def on_progress(event_type: str, message: str) -> None:
            self._handle_progress_event(item, event_type, {"message": message, "type": event_type})

        try:
            result = self._run_mlx_transcription(item, options, on_progress)
            self._finalize_item(item, result, options)
        finally:
            self._reclaim_mlx_memory(reset_peak=True)

    def _process_item_subprocess(self, item: dict[str, Any]) -> None:
        options = self._last_options.copy()
        output_path = self.output_dir / f"{item['fileId']}.txt"
        command = [
            sys.executable,
            str(self.project_root / "transcribe_worker.py"),
            "--audio-path",
            item["path"],
            "--language",
            options["language"],
            "--speakers",
            str(options["speakers"]),
            "--token",
            options["token"],
            "--output-path",
            str(output_path),
            "--download-url",
            item["fileId"],
        ]
        if options["diarize"]:
            command.append("--diarize")

        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        stderr_lines: list[str] = []
        done_emitted = False
        error_message = None

        def drain_stderr() -> None:
            assert process.stderr is not None
            for raw in process.stderr:
                text = raw.strip()
                if not text:
                    continue
                if any(snippet in text for snippet in IGNORED_STDERR_SNIPPETS):
                    continue
                stderr_lines.append(text)
                del stderr_lines[:-20]

        stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
        stderr_thread.start()

        with self._lock:
            self._current_process = process
            self._current_mode = "subprocess"

        try:
            assert process.stdout is not None
            for raw in process.stdout:
                line = raw.strip()
                if not line.startswith(EVENT_PREFIX):
                    continue

                payload = json.loads(line[len(EVENT_PREFIX):])
                event_name = payload.get("event")
                data = payload.get("data", {})
                if not event_name:
                    continue

                if event_name == "done":
                    done_emitted = True
                    self._apply_done(item, data)
                elif event_name == "error":
                    error_message = data.get("message") or "轉譯失敗"
                else:
                    self._handle_progress_event(item, event_name, data)

            return_code = process.wait()
            stderr_thread.join(timeout=1)

            if self._current_stop_kind == "hard":
                raise TaskStopped("已停止")

            if return_code != 0:
                raise RuntimeError(error_message or (stderr_lines[-1] if stderr_lines else "轉譯程序異常結束"))

            if not done_emitted:
                raise RuntimeError("轉譯程序未回傳完成事件")
        finally:
            with self._lock:
                self._current_process = None
                self._current_file_id = None
                self._current_mode = None
                self._current_stop_kind = None

    def _handle_progress_event(self, item: dict[str, Any], event_name: str, data: dict[str, Any]) -> None:
        message = data.get("message", "")
        with self._lock:
            if event_name in {"status", "progress"}:
                item["message"] = message
                item["progress"] = min(int(item.get("progress", 5)) + (10 if event_name == "status" else 3), 92)
                snapshot = self._snapshot_locked()
            else:
                snapshot = None

        if event_name in {"status", "progress"}:
            self.emit_event(
                "task_progress",
                {
                    "fileId": item["fileId"],
                    "message": message,
                    "progress": item["progress"],
                    "phase": event_name,
                },
            )
            self.emit_event("queue_updated", snapshot)
        elif event_name in {"live_log", "transcript"}:
            text = data.get("text") if event_name == "transcript" else message
            self.emit_event("task_partial_text", {"fileId": item["fileId"], "text": text or ""})

    def _finalize_item(self, item: dict[str, Any], result: dict[str, Any], options: dict[str, Any]) -> None:
        segments = result.get("segments", [])
        detected_language = result.get("language", options["language"])
        transcript = "\n".join(engine.format_segment(seg, False) for seg in segments)
        self.emit_event(
            "task_partial_text",
            {"fileId": item["fileId"], "text": transcript},
        )

        has_speakers = False
        if options["diarize"] and options["token"]:
            self._handle_progress_event(
                item,
                "status",
                {"message": "正在進行語者分離...", "type": "status"},
            )
            num_speakers = options["speakers"] if options["speakers"] > 0 else None
            segments = engine.diarize(item["path"], segments, options["token"], num_speakers)
            has_speakers = True

        final_transcript = "\n".join(engine.format_segment(seg, has_speakers) for seg in segments)
        payload = {
            "text": final_transcript,
            "language": detected_language,
            "count": len(segments),
            "has_speakers": has_speakers,
            "suggestedFilename": transcript_filename(item["filename"]),
        }
        self._apply_done(item, payload)
        with self._lock:
            self._current_file_id = None
            self._current_mode = None

    def _apply_done(self, item: dict[str, Any], payload: dict[str, Any]) -> None:
        with self._lock:
            item["status"] = "done"
            item["progress"] = 100
            item["message"] = "完成"
            item["result"] = {
                "text": payload.get("text", ""),
                "language": payload.get("language", self._last_options["language"]),
                "count": payload.get("count", 0),
                "has_speakers": bool(payload.get("has_speakers", False)),
                "suggestedFilename": payload.get("suggestedFilename") or transcript_filename(item["filename"]),
            }
            item["error"] = None
            snapshot = self._snapshot_locked()

        self.emit_event(
            "task_completed",
            {"fileId": item["fileId"], "result": item["result"]},
        )
        self.emit_event("queue_updated", snapshot)

    def _ensure_mlx_policy(self) -> None:
        if engine.ENGINE != "mlx" or self._mlx_policy is not None:
            return
        self._mlx_policy = mlx_runtime.configure_memory_policy()

    def _reclaim_mlx_memory(self, reset_peak: bool = False) -> dict[str, Any] | None:
        if engine.ENGINE != "mlx":
            return None
        stats = mlx_runtime.reclaim_memory(reset_peak=reset_peak)
        gc.collect()
        if self._mlx_policy is not None:
            self._mlx_policy["last_memory_stats"] = stats
        return stats

    def _memory_limit_error(self, exc: BaseException) -> RuntimeError:
        stats = self._reclaim_mlx_memory(reset_peak=False) or {}
        peak = int(stats.get("peak_memory_bytes", 0) / (1024**3) * 10) / 10 if stats else 0
        message = "桌面版記憶體上限已觸發，已嘗試回收記憶體並重試一次仍失敗。"
        if peak:
            message += f" 本次峰值約 {peak:.1f} GB。"
        message += " 請改成分批處理較長音檔。"
        return RuntimeError(message)

    def _run_mlx_transcription(
        self,
        item: dict[str, Any],
        options: dict[str, Any],
        on_progress: Callable[[str, str], None],
    ) -> dict[str, Any]:
        try:
            return engine.transcribe(item["path"], language=options["language"], on_progress=on_progress)
        except Exception as exc:
            if not mlx_runtime.is_memory_pressure_error(exc):
                raise

            on_progress("status", "正在回收 MLX 記憶體並重新嘗試...")
            self._reclaim_mlx_memory(reset_peak=False)

            try:
                return engine.transcribe(item["path"], language=options["language"], on_progress=on_progress)
            except Exception as retry_exc:
                if mlx_runtime.is_memory_pressure_error(retry_exc):
                    raise self._memory_limit_error(retry_exc) from retry_exc
                raise

    def _snapshot_locked(self) -> dict[str, Any]:
        return {
            "items": [self._serialize_item(item) for item in self._items],
            "isProcessing": self._is_processing,
            "isPaused": self._is_paused,
            "stopRequested": self._stop_requested,
            "currentFileId": self._current_file_id,
            "supportsHardStop": engine.ENGINE != "mlx",
        }

    def _serialize_item(self, item: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": item["id"],
            "fileId": item["fileId"],
            "filename": item["filename"],
            "size": item["size"],
            "status": item["status"],
            "progress": item.get("progress", 0),
            "message": item.get("message", ""),
            "result": item.get("result"),
            "error": item.get("error"),
        }
