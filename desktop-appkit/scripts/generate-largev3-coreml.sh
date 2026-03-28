#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
COREMLTOOLS_VERSION="${SCRIBBY_COREMLTOOLS_VERSION:-8.3.0}"
TORCH_VERSION="${SCRIBBY_COREML_TORCH_VERSION:-2.5.0}"
WHISPER_VERSION="${SCRIBBY_COREML_WHISPER_VERSION:-20250625}"
ANE_TRANSFORMERS_VERSION="${SCRIBBY_COREML_ANE_TRANSFORMERS_VERSION:-0.1.1}"
NUMPY_VERSION="${SCRIBBY_COREML_NUMPY_VERSION:-}"
EXPORT_METHOD="${SCRIBBY_COREML_EXPORT_METHOD:-baseline}"
PYTHON_COMMAND="${SCRIBBY_COREML_PYTHON:-python3.11}"
VENV="${SCRIBBY_COREML_VENV:-$WORKSPACE/.venv-coreml311}"
OUTPUT_DIR="${SCRIBBY_COREML_OUTPUT_DIR:-$HOME/Library/Application Support/com.minrui.scribby/swiftwhisper-models}"
COREML_ENV_FINGERPRINT="python=${PYTHON_COMMAND};coremltools=${COREMLTOOLS_VERSION};torch=${TORCH_VERSION};openai-whisper=${WHISPER_VERSION};ane_transformers=${ANE_TRANSFORMERS_VERSION};numpy=${NUMPY_VERSION:-auto};method=${EXPORT_METHOD}"

MODEL_NAME="${1:-large-v3}"

case "$MODEL_NAME" in
  large-v3)
    OUTPUT_STEM="ggml-large-v3-encoder"
    ;;
  large-v3-turbo|turbo)
    MODEL_NAME="large-v3-turbo"
    OUTPUT_STEM="ggml-large-v3-turbo-encoder"
    ;;
  *)
    echo "Usage: $0 [large-v3|large-v3-turbo]"
    exit 1
    ;;
esac

resolve_coremlc() {
    if /usr/bin/xcrun --find coremlc >/dev/null 2>&1; then
        /usr/bin/xcrun --find coremlc
        return 0
    fi

    for candidate in \
        "/Applications/Xcode.app/Contents/Developer/usr/bin/coremlc" \
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/coremlc"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

resolve_python311() {
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

ensure_coreml_env() {
    local python311
    python311="$(resolve_python311 || true)"
    if [ -z "$python311" ]; then
        echo "ERROR: 找不到 ${PYTHON_COMMAND}，請先安裝對應版本的 Python。"
        exit 1
    fi

    if [ ! -x "$VENV/bin/python" ]; then
        echo "=== Preparing Core ML export environment ==="
        "$python311" -m venv "$VENV"
    fi

    local fingerprint_file="$VENV/.scribby-coreml-fingerprint"
    local current_fingerprint=""
    if [ -f "$fingerprint_file" ]; then
        current_fingerprint="$(cat "$fingerprint_file")"
    fi

    if [ "$current_fingerprint" != "$COREML_ENV_FINGERPRINT" ]; then
        echo "=== Syncing Core ML export toolchain ==="
        "$VENV/bin/python" -m pip install --upgrade pip setuptools wheel

        local major_version="${COREMLTOOLS_VERSION%%.*}"
        local inferred_numpy="$NUMPY_VERSION"
        if [ -z "$inferred_numpy" ] && [ "${major_version:-0}" -lt 8 ]; then
            inferred_numpy="<2"
        fi

        local packages=(
            "coremltools==${COREMLTOOLS_VERSION}"
            "torch==${TORCH_VERSION}"
            "openai-whisper==${WHISPER_VERSION}"
            "ane_transformers==${ANE_TRANSFORMERS_VERSION}"
        )
        if [ -n "$inferred_numpy" ]; then
            packages+=("numpy${inferred_numpy}")
        fi

        "$VENV/bin/python" -m pip install \
            "${packages[@]}"
        printf '%s\n' "$COREML_ENV_FINGERPRINT" > "$fingerprint_file"
    fi

    echo "Using Core ML export Python: $("$VENV/bin/python" --version)"
    "$VENV/bin/python" - <<'PY'
import coremltools as ct
import torch
import whisper
print(f"coremltools={ct.__version__}")
print(f"torch={torch.__version__}")
print(f"whisper={getattr(whisper, '__version__', 'n/a')}")
PY
}

echo "=== Step 1: Convert $MODEL_NAME encoder to CoreML mlpackage ==="
echo "Output directory: $OUTPUT_DIR"
echo "Export method: $EXPORT_METHOD"

mkdir -p "$OUTPUT_DIR"
ensure_coreml_env

TEMP_MLPACKAGE="$OUTPUT_DIR/coreml-encoder-$MODEL_NAME.mlpackage"

"$VENV/bin/python3" - <<PY
import coremltools as ct
import torch
import whisper.model as whisper_model_module
from whisper import load_model

model_name = "$MODEL_NAME"
output_path = "$TEMP_MLPACKAGE"
export_method = "$EXPORT_METHOD"

if export_method == "upstream_compat":
    whisper_model_module.MultiHeadAttention.use_sdpa = False
    print("Using upstream-compatible export mode: SDPA disabled")
elif export_method == "baseline":
    print("Using baseline export mode")
else:
    raise ValueError(f"Unsupported export method: {export_method}")

def convert_encoder(hparams, encoder):
    encoder.eval()
    n_mels = hparams.n_mels
    input_shape = (1, n_mels, 3000)
    print(f'Encoder input shape: {input_shape} (n_mels={n_mels})')
    input_data = torch.randn(input_shape)
    with torch.no_grad():
        traced_model = torch.jit.trace(encoder, input_data)
    model = ct.convert(
        traced_model,
        convert_to='mlprogram',
        inputs=[ct.TensorType(name='logmel_data', shape=input_shape)],
        outputs=[ct.TensorType(name='output')],
        compute_units=ct.ComputeUnit.ALL
    )
    return model

print(f'Loading {model_name} model...')
if export_method == "upstream_compat":
    whisper_model = load_model(model_name).cpu()
else:
    whisper_model = load_model(model_name, device='cpu', in_memory=True)
hparams = whisper_model.dims
print(f'Model dims: n_mels={hparams.n_mels}, n_audio_state={hparams.n_audio_state}, n_audio_layer={hparams.n_audio_layer}')

print('Converting encoder to CoreML...')
coreml_encoder = convert_encoder(hparams, whisper_model.encoder)

print(f'Saving to {output_path}')
coreml_encoder.save(output_path)
print('Done converting encoder to mlpackage')
PY

echo ""
echo "=== Step 2: Compile mlpackage to mlmodelc ==="
if [ ! -d "$TEMP_MLPACKAGE" ]; then
    echo "ERROR: mlpackage not found at $TEMP_MLPACKAGE"
    exit 1
fi

COREMLC="$(resolve_coremlc || true)"
if [ -z "$COREMLC" ]; then
    echo "ERROR: 找不到 coremlc，請安裝 Xcode，或將 xcode-select 指到 Xcode.app"
    exit 1
fi

"$COREMLC" compile "$TEMP_MLPACKAGE" "$OUTPUT_DIR/"
rm -rf "$OUTPUT_DIR/$OUTPUT_STEM.mlmodelc"
mv -v "$OUTPUT_DIR/coreml-encoder-$MODEL_NAME.mlmodelc" "$OUTPUT_DIR/$OUTPUT_STEM.mlmodelc"

echo ""
echo "=== Step 3: Rename mlpackage ==="
rm -rf "$OUTPUT_DIR/$OUTPUT_STEM.mlpackage"
mv -v "$TEMP_MLPACKAGE" "$OUTPUT_DIR/$OUTPUT_STEM.mlpackage"

echo ""
echo "=== Done ==="
du -sh "$OUTPUT_DIR/$OUTPUT_STEM.mlmodelc"
du -sh "$OUTPUT_DIR/$OUTPUT_STEM.mlpackage"
