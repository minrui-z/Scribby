import os
import gc
import io
import sys
import platform
import logging
import threading

logger = logging.getLogger("transcriber")

# ── 平台偵測 ──────────────────────────────────────────

def _detect_engine():
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        return "mlx"
    return "faster"

ENGINE = _detect_engine()


def get_engine_info():
    info = {"engine": ENGINE, "model": "large-v3"}
    if ENGINE == "mlx":
        import torch
        info["device"] = "mps" if torch.backends.mps.is_available() else "cpu"
    else:
        import torch
        if torch.cuda.is_available():
            info["device"] = "cuda"
        else:
            info["device"] = "cpu"
    return info


# ── Stdout 擷取器 ─────────────────────────────────────

class StdoutCapture(io.StringIO):
    def __init__(self, original_stdout):
        super().__init__()
        self.original = original_stdout
        self.captured_lines = []

    def write(self, text):
        if text.strip():
            self.captured_lines.append(text.strip())
        return len(text)

    def flush(self):
        if hasattr(self.original, "flush"):
            self.original.flush()


# ── MLX Whisper 轉譯 ─────────────────────────────────

def _transcribe_mlx(audio_path, language, on_progress):
    import mlx_whisper

    model_name = "mlx-community/whisper-large-v3-mlx"
    on_progress("status", "正在載入 MLX Whisper 模型並開始轉譯...")

    capture = StdoutCapture(sys.stdout)
    result_container = {}
    error_container = {}

    def run():
        old_stdout, old_stderr = sys.stdout, sys.stderr
        sys.stdout = capture
        sys.stderr = capture
        try:
            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=model_name,
                language=language,
                word_timestamps=True,
                verbose=True,
            )
            result_container["data"] = result
        except Exception as e:
            error_container["err"] = e
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr

    thread = threading.Thread(target=run)
    thread.start()

    import time
    last_count = 0
    while thread.is_alive():
        time.sleep(1)
        lines = list(capture.captured_lines)
        if len(lines) > last_count:
            last_count = len(lines)
            on_progress("progress", f"已處理 {last_count} 段...")
            on_progress("live_log", "\n".join(lines[-30:]))

    thread.join()

    if "err" in error_container:
        raise error_container["err"]

    return result_container["data"]


# ── Faster-Whisper 轉譯 ──────────────────────────────

def _transcribe_faster(audio_path, language, on_progress):
    from faster_whisper import WhisperModel
    import torch

    device = "cuda" if torch.cuda.is_available() else "cpu"
    compute_type = "float16" if device == "cuda" else "float32"

    on_progress("status", f"正在載入 Faster-Whisper 模型 (裝置: {device})...")
    model = WhisperModel("large-v3", device=device, compute_type=compute_type)

    on_progress("status", "轉譯中...")
    segments_iter, info = model.transcribe(
        audio_path,
        language=language,
        word_timestamps=True,
        vad_filter=True,
    )

    segments = []
    for i, seg in enumerate(segments_iter):
        segments.append({
            "start": seg.start,
            "end": seg.end,
            "text": seg.text,
        })
        if (i + 1) % 5 == 0:
            on_progress("progress", f"已處理 {i + 1} 段...")

    del model
    gc.collect()

    return {
        "language": info.language if hasattr(info, "language") else language,
        "segments": segments,
    }


# ── 統一轉譯介面 ─────────────────────────────────────

def transcribe(audio_path, language="zh", on_progress=None):
    if on_progress is None:
        on_progress = lambda t, m: None

    if ENGINE == "mlx":
        result = _transcribe_mlx(audio_path, language, on_progress)
    else:
        result = _transcribe_faster(audio_path, language, on_progress)

    return result


# ── 語者分離 ──────────────────────────────────────────

def diarize(audio_path, segments, hf_token, num_speakers=None):
    from whisperx.diarize import DiarizationPipeline
    import torch

    if ENGINE == "mlx":
        device = "mps" if torch.backends.mps.is_available() else "cpu"
    else:
        device = "cuda" if torch.cuda.is_available() else "cpu"

    diarize_model = DiarizationPipeline(token=hf_token, device=device)

    kwargs = {}
    if num_speakers and num_speakers > 0:
        kwargs["num_speakers"] = int(num_speakers)

    diarize_segments = diarize_model(audio_path, **kwargs)

    for seg in segments:
        best_speaker = None
        best_overlap = 0
        for _, row in diarize_segments.iterrows():
            overlap_start = max(seg["start"], row["start"])
            overlap_end = min(seg["end"], row["end"])
            overlap = max(0, overlap_end - overlap_start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = row["speaker"]
        if best_speaker:
            seg["speaker"] = best_speaker

    del diarize_model
    gc.collect()

    return segments


# ── Token 驗證 ────────────────────────────────────────

REQUIRED_MODELS = [
    "pyannote/segmentation-3.0",
    "pyannote/speaker-diarization-community-1",
]

def verify_hf_token(token):
    from huggingface_hub import HfApi

    if not token or not token.strip():
        return False, "未提供 Token"

    token = token.strip()
    api = HfApi(token=token)

    try:
        api.whoami()
    except Exception:
        return False, "Token 無效，請確認是否正確"

    missing = []
    for model_id in REQUIRED_MODELS:
        try:
            api.model_info(model_id)
        except Exception:
            missing.append(model_id)

    if missing:
        links = "\n".join(f"  - https://huggingface.co/{m}" for m in missing)
        return False, f"Token 有效，但以下模型尚未授權：\n{links}"

    return True, "Token 有效，所有模型授權已通過"


# ── 格式化 ────────────────────────────────────────────

def format_segment(segment, has_speakers):
    start = segment["start"]
    minutes = int(start // 60)
    seconds = start % 60
    timestamp = f"[{minutes:02d}:{seconds:05.2f}]"

    if has_speakers and "speaker" in segment:
        speaker_id = segment["speaker"]
        speaker_num = int(speaker_id.split("_")[-1]) + 1
        label = f"Speaker {speaker_num}"
    else:
        label = "Speaker"

    text = segment["text"].strip()
    return f"{timestamp} {label}: {text}"
