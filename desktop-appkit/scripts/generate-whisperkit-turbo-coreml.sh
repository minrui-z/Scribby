#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-coreml-load-matrix.py"
WHISPERKITTOOLS_DIR="${SCRIBBY_WHISPERKITTOOLS_DIR:-/tmp/whisperkittools}"
PYTHON_COMMAND="${SCRIBBY_WHISPERKIT_PYTHON:-python3.11}"
VENV="${SCRIBBY_WHISPERKIT_VENV:-$WORKSPACE/.venv-whisperkit-exp}"
PRESET="${1:-large-v3-turbo}"

case "$PRESET" in
  large-v3-turbo|turbo)
    PRESET="large-v3-turbo"
    MODEL_ID="${SCRIBBY_WHISPERKIT_MODEL_ID:-openai/whisper-large-v3-turbo}"
    PACKAGE_NAME="ggml-large-v3-turbo-encoder.mlpackage"
    ;;
  large-v3|v3)
    PRESET="large-v3"
    MODEL_ID="${SCRIBBY_WHISPERKIT_MODEL_ID:-openai/whisper-large-v3}"
    PACKAGE_NAME="ggml-large-v3-encoder.mlpackage"
    ;;
  *)
    echo "Usage: $0 [large-v3-turbo|large-v3]"
    exit 1
    ;;
esac

ZIP_NAME="${PACKAGE_NAME}.zip"
RESULT_DIR="${SCRIBBY_WHISPERKIT_RESULT_DIR:-$WORKSPACE/coreml-matrix-results/whisperkit-${PRESET}-$(date +%Y%m%d-%H%M%S)}"
PACKAGE_PATH="$RESULT_DIR/$PACKAGE_NAME"
ZIP_PATH="$RESULT_DIR/$ZIP_NAME"
LOAD_MATRIX_JSON="$RESULT_DIR/load-matrix.json"
GATE_JSON="$RESULT_DIR/gate.json"
FINGERPRINT_JSON="$RESULT_DIR/toolchain-fingerprint.json"
RUN_LOG="$RESULT_DIR/run.log"
LOAD_TIMEOUT="${SCRIBBY_WHISPERKIT_LOAD_TIMEOUT:-240}"
UPLOAD_ENABLED="${SCRIBBY_WHISPERKIT_UPLOAD:-0}"
HF_REPO_ID="${SCRIBBY_WHISPERKIT_HF_REPO_ID:-souminei/scribby-coreml-encoders}"
HF_PATH_IN_REPO="${SCRIBBY_WHISPERKIT_HF_PATH_IN_REPO:-$ZIP_NAME}"
SDPA_IMPL="${SCRIBBY_WHISPERKIT_SDPA_IMPL:-Cat}"

mkdir -p "$RESULT_DIR"
exec > >(tee -a "$RUN_LOG") 2>&1

resolve_python() {
    for candidate in \
        "$(command -v "$PYTHON_COMMAND" 2>/dev/null || true)" \
        "/opt/homebrew/bin/$PYTHON_COMMAND" \
        "/usr/local/bin/$PYTHON_COMMAND"; do
        if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

ensure_whisperkittools() {
    if [ -d "$WHISPERKITTOOLS_DIR/.git" ]; then
        echo "Using whisperkittools checkout: $WHISPERKITTOOLS_DIR"
        return 0
    fi

    echo "Cloning whisperkittools into $WHISPERKITTOOLS_DIR"
    rm -rf "$WHISPERKITTOOLS_DIR"
    git clone https://github.com/argmaxinc/whisperkittools.git "$WHISPERKITTOOLS_DIR"
}

ensure_env() {
    local python_bin
    python_bin="$(resolve_python || true)"
    if [ -z "$python_bin" ]; then
        echo "ERROR: 找不到 $PYTHON_COMMAND"
        exit 1
    fi

    if [ ! -x "$VENV/bin/python" ]; then
        echo "Preparing WhisperKit export environment"
        "$python_bin" -m venv "$VENV"
    fi

    local fingerprint="python=$PYTHON_COMMAND;argmaxtools=0.1.23;transformers=4.53;torch=2.5.0;coremltools=8.3.0;numpy<2.4.0;sdpa=$SDPA_IMPL"
    local fingerprint_file="$VENV/.scribby-whisperkit-fingerprint"
    local current_fingerprint=""
    if [ -f "$fingerprint_file" ]; then
        current_fingerprint="$(cat "$fingerprint_file")"
    fi

    if [ "$current_fingerprint" != "$fingerprint" ]; then
        echo "Syncing WhisperKit export dependencies"
        "$VENV/bin/python" -m pip install --upgrade pip setuptools wheel
        "$VENV/bin/python" -m pip install \
            "argmaxtools==0.1.23" \
            "transformers==4.53" \
            "torch==2.5.0" \
            "coremltools==8.3.0" \
            "numpy<2.4.0" \
            "huggingface-hub"
        "$VENV/bin/python" -m pip install -e "$WHISPERKITTOOLS_DIR"
        printf '%s\n' "$fingerprint" > "$fingerprint_file"
    fi
}

write_fingerprint() {
    local repo_hash="unknown"
    if [ -d "$WHISPERKITTOOLS_DIR/.git" ]; then
        repo_hash="$(git -C "$WHISPERKITTOOLS_DIR" rev-parse HEAD)"
    fi

    "$VENV/bin/python" - <<PY
import json
import coremltools as ct
import numpy as np
import torch
import transformers
import argmaxtools
from pathlib import Path

payload = {
    "python": "${PYTHON_COMMAND}",
    "model_id": "${MODEL_ID}",
    "sdpa_impl": "${SDPA_IMPL}",
    "versions": {
        "coremltools": ct.__version__,
        "torch": torch.__version__,
        "numpy": np.__version__,
        "transformers": transformers.__version__,
        "argmaxtools": getattr(argmaxtools, "__version__", "unknown"),
    },
    "whisperkittools_commit": "${repo_hash}",
}
Path("${FINGERPRINT_JSON}").write_text(json.dumps(payload, ensure_ascii=False, indent=2))
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

generate_package() {
    rm -rf "$PACKAGE_PATH"
    "$VENV/bin/python" -u - <<PY
import json
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from argmaxtools import _sdpa
from transformers.models.whisper import modeling_whisper
from whisperkit import audio_encoder

model_id = "${MODEL_ID}"
output_path = Path("${PACKAGE_PATH}")
sdpa_name = "${SDPA_IMPL}"

sdpa_impl = getattr(_sdpa, sdpa_name)
audio_encoder.SDPA_IMPL = sdpa_impl

print(f"Loading Hugging Face Whisper model: {model_id}")
source = modeling_whisper.WhisperForConditionalGeneration.from_pretrained(
    model_id,
    torch_dtype=torch.float32,
)
source_encoder = source.model.encoder.cpu().eval()
config = source_encoder.config
print(
    "Encoder config: "
    f"n_mels={config.num_mel_bins}, d_model={config.d_model}, "
    f"layers={config.encoder_layers}, seq_len={config.max_source_positions}"
)

encoder = audio_encoder.WhisperAudioEncoder(config)
encoder.load_state_dict(source_encoder.state_dict())
encoder = encoder.cpu().eval()

sample = torch.randn(
    1,
    config.num_mel_bins,
    1,
    config.max_source_positions * 2,
    dtype=torch.float32,
)

with torch.no_grad():
    traced = torch.jit.trace(
        encoder,
        example_kwarg_inputs={"melspectrogram_features": sample},
    )

print("Converting WhisperKit-style audio encoder to mlpackage")
start = time.time()
model = ct.convert(
    traced,
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    inputs=[
        ct.TensorType(
            name="melspectrogram_features",
            shape=sample.shape,
            dtype=np.float32,
        )
    ],
    outputs=[
        ct.TensorType(
            name="encoder_output_embeds",
            dtype=np.float16,
        )
    ],
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    compute_precision=ct.precision.FLOAT16,
    skip_model_load=True,
)
print(f"Conversion finished in {time.time() - start:.2f}s")

print(f"Saving mlpackage to {output_path}")
start = time.time()
model.save(output_path)
print(f"Save finished in {time.time() - start:.2f}s")
PY
}

run_gate() {
    "$VENV/bin/python" "$CHECK_SCRIPT" "$PACKAGE_PATH" \
        --timeout "$LOAD_TIMEOUT" \
        --units "CPU_ONLY,CPU_AND_GPU,CPU_AND_NE" \
        --json-out "$LOAD_MATRIX_JSON"

    "$VENV/bin/python" - <<PY
import json
from pathlib import Path

payload = json.loads(Path("${LOAD_MATRIX_JSON}").read_text())
required_units = ("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE")
status_by_unit = {
    result["unit"]: result["status"]
    for result in payload["results"]
}
passed = all(status_by_unit.get(unit) == "ok" for unit in required_units)
gate = {
    "passed": passed,
    "required_units": list(required_units),
    "status_by_unit": status_by_unit,
}
Path("${GATE_JSON}").write_text(json.dumps(gate, ensure_ascii=False, indent=2))
print(json.dumps(gate, ensure_ascii=False, indent=2))
if not passed:
    raise SystemExit(2)
PY
}

zip_package() {
    rm -f "$ZIP_PATH"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_PATH" "$ZIP_PATH"
    ls -lh "$ZIP_PATH"
}

upload_if_requested() {
    if [ "$UPLOAD_ENABLED" != "1" ]; then
        echo "Upload skipped (SCRIBBY_WHISPERKIT_UPLOAD=$UPLOAD_ENABLED)"
        return 0
    fi

    local token="${SCRIBBY_HF_TOKEN:-${HF_TOKEN:-}}"
    if [ -z "$token" ]; then
        echo "ERROR: upload requested but no SCRIBBY_HF_TOKEN/HF_TOKEN provided"
        exit 1
    fi

    "$VENV/bin/python" - <<PY
from huggingface_hub import HfApi

api = HfApi(token="${token}")
api.upload_file(
    path_or_fileobj="${ZIP_PATH}",
    path_in_repo="${HF_PATH_IN_REPO}",
    repo_id="${HF_REPO_ID}",
    repo_type="model",
)
print("Uploaded ${ZIP_PATH} -> ${HF_REPO_ID}:${HF_PATH_IN_REPO}")
PY
}

echo "=== WhisperKit-style ${PRESET} export ==="
echo "Result dir: $RESULT_DIR"
echo "Model id: $MODEL_ID"
echo "NE gate timeout: ${LOAD_TIMEOUT}s"

ensure_whisperkittools
ensure_env
write_fingerprint
generate_package
run_gate
zip_package
upload_if_requested

echo "Done. Gate passed; package is ready at $PACKAGE_PATH"
