#!/usr/bin/env python3
"""Speech enhancement using mlx-audio MossFormer2 SE (public API).

Outputs 16 kHz mono 16-bit PCM WAV so the headless transcription binary
can consume it directly without resampling or ffmpeg.
"""
import sys
import time


DEFAULT_MODEL = "starkdmi/MossFormer2_SE_48K_MLX"
TARGET_SR = 16_000


def _error(message: str, code: int = 1) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()
    raise SystemExit(code)


def _log(message: str) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()


def _resample(audio, orig_sr: int, target_sr: int):
    """Resample 1-D numpy array using linear interpolation."""
    import numpy as np

    if orig_sr == target_sr:
        return audio
    target_len = max(1, int(len(audio) * target_sr / orig_sr))
    indices = np.linspace(0, len(audio) - 1, target_len)
    return np.interp(indices, np.arange(len(audio)), audio).astype(np.float32)


def _load_model(model_name: str):
    """Load MossFormer2 SE model via public API."""
    try:
        from mlx_audio.sts import MossFormer2SEModel
    except ImportError as exc:
        _error(f"無法載入 mlx-audio：{exc}\n請確認已安裝 mlx-audio 套件")

    # Redirect stdout prints from from_pretrained to stderr
    import io
    import contextlib

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        model = MossFormer2SEModel.from_pretrained(model_name)

    for line in buf.getvalue().strip().splitlines():
        if line.strip():
            _log(line.strip())

    return model


def enhance(
    audio_in: str,
    audio_out: str,
    model_name: str = DEFAULT_MODEL,
) -> None:
    import os

    if not os.path.isfile(audio_in):
        _error(f"找不到輸入音訊檔：{audio_in}")

    _log("正在載入人聲加強模型...")
    start = time.time()

    model = _load_model(model_name)
    _log("正在做人聲加強...")

    import numpy as np

    enhanced = model.enhance(audio_in)

    # Ensure 1-D mono
    if enhanced.ndim > 1:
        enhanced = enhanced.squeeze()
    if enhanced.ndim > 1:
        enhanced = enhanced.mean(axis=0)

    # Resample from model's native rate (48 kHz) to 16 kHz
    orig_sr = model.config.sample_rate
    resampled = _resample(enhanced, orig_sr, TARGET_SR)

    # Write 16 kHz mono WAV
    import soundfile as sf

    sf.write(audio_out, resampled, TARGET_SR, subtype="PCM_16")

    elapsed = time.time() - start
    _log(f"人聲加強完成，耗時 {elapsed:.1f} 秒（輸出 {TARGET_SR} Hz mono）")


def main() -> None:
    if len(sys.argv) < 2:
        _error("用法：speech_enhance.py enhance <audio_in> [audio_out] [model]")

    command = sys.argv[1]

    if command == "enhance":
        if len(sys.argv) < 3:
            _error("用法：speech_enhance.py enhance <audio_in> [audio_out] [model]")

        audio_in = sys.argv[2]
        audio_out = sys.argv[3] if len(sys.argv) > 3 else None
        model_name = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_MODEL

        if audio_out is None:
            import os

            base, _ = os.path.splitext(audio_in)
            audio_out = base + "_enhanced.wav"

        enhance(audio_in, audio_out, model_name)
    else:
        _error(
            f"未知指令：{command}\n用法：speech_enhance.py enhance <audio_in> [audio_out] [model]"
        )


if __name__ == "__main__":
    main()
