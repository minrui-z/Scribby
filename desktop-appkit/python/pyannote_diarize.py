#!/usr/bin/env python3
import io
import json
import numpy as np
import os
import subprocess
import sys
import wave


REQUIRED_MODELS = [
    "pyannote/segmentation-3.0",
    "pyannote/speaker-diarization-community-1",
]


def _error(message: str, code: int = 1) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()
    raise SystemExit(code)


def _log(message: str) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()


def verify_token(token: str) -> None:
    from huggingface_hub import HfApi

    token = (token or "").strip()
    if not token:
        _error("未提供 HuggingFace Token")

    api = HfApi(token=token)

    try:
        api.whoami()
    except Exception:
        _error("Token 無效，請確認是否正確")

    missing = []
    for model_id in REQUIRED_MODELS:
        try:
            api.model_info(model_id)
        except Exception:
            missing.append(model_id)

    if missing:
        _error(
            "Token 有效，但以下模型尚未授權：\n" +
            "\n".join(f"  - https://huggingface.co/{model}" for model in missing)
        )

    sys.stdout.write(json.dumps({
        "ok": True,
        "message": "Token 有效，所有 pyannote 模型授權已通過",
    }, ensure_ascii=False))
    sys.stdout.write("\n")


def diarize(audio_path: str, token: str, segments_path: str, speakers: int | None = None) -> None:
    import pandas as pd
    import torch
    from pyannote.audio import Pipeline

    token = (token or "").strip()
    if not token:
        _error("未提供 HuggingFace Token")

    try:
        with open(segments_path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        _error(f"無法讀取分段資料：{exc}")

    segments = payload.get("segments") or []
    if not isinstance(segments, list):
        _error("分段資料格式不正確")

    if torch.cuda.is_available():
        device = torch.device("cuda")
    elif getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")
    kwargs = {}
    if speakers and int(speakers) > 0:
        kwargs["num_speakers"] = int(speakers)

    try:
        ffmpeg_bin = (
            os.environ.get("FFMPEG_BINARY")
            or os.environ.get("IMAGEIO_FFMPEG_EXE")
            or "ffmpeg"
        )
        _log(f"語者辨識準備開始，目標裝置={device}")
        _log(f"正在用 {ffmpeg_bin} 透過 pipe 轉成 WAV 並直接載入記憶體...")
        ffmpeg = subprocess.run(
            [
                ffmpeg_bin,
                "-v",
                "error",
                "-i", audio_path,
                "-vn",
                "-f", "wav",
                "-acodec", "pcm_s16le",
                "pipe:1",
            ],
            check=True,
            capture_output=True,
        )
        waveform, sample_rate = _load_waveform_from_wav_bytes(ffmpeg.stdout)
        _log(f"音訊已載入：channels={waveform.shape[0]}, sample_rate={sample_rate}, frames={waveform.shape[1]}")

        _log("正在建立 pyannote pipeline...")
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-community-1",
            token=token,
        )
        _log("正在把 pyannote pipeline 移到目標裝置...")
        try:
            pipeline.to(device)
            active_device = device
        except Exception as exc:
            if device.type == "mps":
                _log(f"MPS 初始化失敗，回退 CPU：{exc}")
                pipeline.to(torch.device("cpu"))
                active_device = torch.device("cpu")
            else:
                raise
        _log(f"pyannote pipeline 已建立，裝置={active_device}")
        _log("正在執行 pyannote speaker diarization 推論...")
        try:
            output = pipeline(
                {"waveform": waveform, "sample_rate": sample_rate},
                num_speakers=kwargs.get("num_speakers"),
            )
        except Exception as exc:
            if active_device.type == "mps":
                _log(f"MPS 推論失敗，回退 CPU：{exc}")
                pipeline.to(torch.device("cpu"))
                active_device = torch.device("cpu")
                _log("正在以 CPU 重新執行 pyannote speaker diarization 推論...")
                output = pipeline(
                    {"waveform": waveform, "sample_rate": sample_rate},
                    num_speakers=kwargs.get("num_speakers"),
                )
            else:
                raise
        diarization = output.speaker_diarization
        diarize_segments = pd.DataFrame(
            diarization.itertracks(yield_label=True),
            columns=["segment", "label", "speaker"],
        )
        diarize_segments["start"] = diarize_segments["segment"].apply(lambda x: x.start)
        diarize_segments["end"] = diarize_segments["segment"].apply(lambda x: x.end)
        _log(f"pyannote diarization 完成，取得 {len(diarize_segments)} 個 diarization 片段，正在對齊逐字稿分段...")
    except Exception as exc:
        _error(f"pyannote diarization 失敗：{exc}")

    mapped = []
    for segment in segments:
        start = float(segment.get("start", 0))
        end = float(segment.get("end", 0))
        text = (segment.get("text") or "").strip()
        best_speaker = None
        best_overlap = 0.0
        for _, row in diarize_segments.iterrows():
            overlap_start = max(start, float(row["start"]))
            overlap_end = min(end, float(row["end"]))
            overlap = max(0.0, overlap_end - overlap_start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = row["speaker"]

        mapped.append({
            "startTimeMs": int(round(start * 1000)),
            "endTimeMs": int(round(end * 1000)),
            "text": text,
            "speakerLabel": _normalize_speaker(best_speaker),
        })

    _log(f"語者對齊完成，輸出 {len(mapped)} 個逐字稿片段")
    sys.stdout.write(json.dumps({"segments": mapped}, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _normalize_speaker(label: str | None) -> str | None:
    if not label:
        return None
    if "_" in label:
        try:
            number = int(label.split("_")[-1]) + 1
            return f"說話者 {number}"
        except ValueError:
            pass
    return label


def _load_waveform_from_wav_bytes(data: bytes):
    with wave.open(io.BytesIO(data), "rb") as handle:
        channels = handle.getnchannels()
        sample_rate = handle.getframerate()
        sample_width = handle.getsampwidth()
        frame_count = handle.getnframes()
        if sample_width != 2:
            _error(f"WAV sample width 不支援：{sample_width}")
        raw = handle.readframes(frame_count)

    data = np.frombuffer(raw, dtype=np.int16).astype("float32") / 32768.0
    data = data.reshape(-1, channels).T
    import torch
    return torch.from_numpy(data), sample_rate


def main() -> None:
    if len(sys.argv) < 2:
        _error("用法：pyannote_diarize.py verify-token <token> | diarize <audio> <token> <segments.json> [speakers]")

    command = sys.argv[1]
    if command == "verify-token":
        if len(sys.argv) < 3:
            _error("請提供 HuggingFace Token")
        verify_token(sys.argv[2])
        return

    if command == "diarize":
        if len(sys.argv) < 5:
            _error("用法：pyannote_diarize.py diarize <audio> <token> <segments.json> [speakers]")
        speakers = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].strip() else None
        diarize(sys.argv[2], sys.argv[3], sys.argv[4], speakers)
        return

    _error(f"未知命令：{command}")


if __name__ == "__main__":
    main()
