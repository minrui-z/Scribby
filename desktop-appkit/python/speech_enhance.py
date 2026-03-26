#!/usr/bin/env python3
import sys
import time


DEFAULT_MODEL = "starkdmi/MossFormer2_SE_48K_MLX"
DEFAULT_PRECISION = "fp16"


def _error(message: str, code: int = 1) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()
    raise SystemExit(code)


def _log(message: str) -> None:
    sys.stderr.write(message.strip() + "\n")
    sys.stderr.flush()


def _download_with_progress(repo_id: str, filename: str) -> str:
    """Download a file from HuggingFace with progress reporting to stderr."""
    from huggingface_hub import try_to_load_from_cache

    cached = try_to_load_from_cache(repo_id, filename)
    if cached is not None:
        _log(f"使用快取：{filename}")
        return cached

    _log(f"正在下載 {filename}...")

    # Monkey-patch tqdm to report progress via stderr
    import huggingface_hub.file_download as _hf_dl
    _original_tqdm = getattr(_hf_dl, "tqdm", None)

    _last_report = [0.0]

    class _ProgressTqdm:
        def __init__(self, *args, **kwargs):
            self.total = kwargs.get("total", 0)
            self.n = 0
            self.desc = kwargs.get("desc", filename)
            self.disable = kwargs.get("disable", False)

        def update(self, n=1):
            self.n += n
            now = time.time()
            if now - _last_report[0] >= 0.3 or self.n >= (self.total or 0):
                _log(f"[DOWNLOAD] {filename} {self.n} {self.total or 0}")
                _last_report[0] = now

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def close(self):
            pass

    _hf_dl.tqdm = _ProgressTqdm

    try:
        from huggingface_hub import hf_hub_download
        result = hf_hub_download(repo_id=repo_id, filename=filename)
    finally:
        if _original_tqdm is not None:
            _hf_dl.tqdm = _original_tqdm

    return result


def _load_model(model_name: str, precision: str = DEFAULT_PRECISION):
    """Load MossFormer2 SE model, working around missing config.json in the HF repo."""
    from pathlib import Path

    import mlx.core as mx
    import mlx.nn as nn
    from mlx.utils import tree_unflatten

    from mlx_audio.sts.models.mossformer2_se.model import (
        MossFormer2SE,
        MossFormer2SEConfig,
        MossFormer2SEModel,
    )

    config = MossFormer2SEConfig()

    # Enable fast LayerNorm
    nn.LayerNorm.__call__ = lambda self, x: mx.fast.layer_norm(
        x, self.weight, self.bias, self.eps
    )

    model = MossFormer2SE(config)

    quant_bits = {"fp32": None, "fp16": None, "int4": 4, "int6": 6, "int8": 8}
    bits = quant_bits.get(precision)
    if bits is not None:
        nn.quantize(model, group_size=64, bits=bits)

    weights_filename = f"model_{precision}.safetensors"

    if Path(model_name).exists():
        weights_path = str(Path(model_name) / weights_filename)
    else:
        weights_path = _download_with_progress(model_name, weights_filename)

    weights = mx.load(weights_path)
    model.update(tree_unflatten(list(weights.items())))

    total_params = sum(v.size for v in weights.values() if hasattr(v, "size"))
    _log(f"模型載入完成：{total_params:,} 參數（{precision}）")

    return MossFormer2SEModel(model=model.model, config=config)


def enhance(audio_in: str, audio_out: str, model_name: str = DEFAULT_MODEL, precision: str = DEFAULT_PRECISION) -> None:
    import os

    if not os.path.isfile(audio_in):
        _error(f"找不到輸入音訊檔：{audio_in}")

    _log(f"正在載入人聲加強模型（{precision}）...")
    start = time.time()

    from mlx_audio import audio_io

    model = _load_model(model_name, precision)
    _log("正在做人聲加強...")

    enhanced = model.enhance(audio_in)
    audio_io.write(audio_out, enhanced, model.config.sample_rate)

    elapsed = time.time() - start
    _log(f"人聲加強完成，耗時 {elapsed:.1f} 秒")


def main() -> None:
    if len(sys.argv) < 2:
        _error("用法：speech_enhance.py enhance <audio_in> [audio_out] [model] [precision]")

    command = sys.argv[1]

    if command == "enhance":
        if len(sys.argv) < 3:
            _error("用法：speech_enhance.py enhance <audio_in> [audio_out] [model] [precision]")

        audio_in = sys.argv[2]
        audio_out = sys.argv[3] if len(sys.argv) > 3 else None
        model_name = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_MODEL
        precision = sys.argv[5] if len(sys.argv) > 5 else DEFAULT_PRECISION

        if audio_out is None:
            import os
            base, _ = os.path.splitext(audio_in)
            audio_out = base + "_enhanced.wav"

        enhance(audio_in, audio_out, model_name, precision)
    else:
        _error(f"未知指令：{command}\n用法：speech_enhance.py enhance <audio_in> [audio_out] [model] [precision]")


if __name__ == "__main__":
    main()
