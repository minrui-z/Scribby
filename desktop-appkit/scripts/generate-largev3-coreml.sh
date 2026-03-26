#!/bin/zsh
set -euo pipefail

# Generate CoreML encoder for large-v3
# Based on whisper.cpp legacy convert-whisper-to-coreml.py
# Modified for large-v3 (128 mel bins, standard encoder, no ANE transforms)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV="$WORKSPACE/.venv-coreml"
OUTPUT_DIR="$HOME/Library/Application Support/com.minrui.scribby/swiftwhisper-models"

echo "=== Step 1: Convert large-v3 encoder to CoreML mlpackage ==="
echo "Output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

"$VENV/bin/python3" -c "
import torch
import coremltools as ct
from whisper import load_model

def convert_encoder(hparams, encoder):
    encoder.eval()
    n_mels = hparams.n_mels  # 128 for large-v3
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

print('Loading large-v3 model...')
whisper_model = load_model('large-v3', device='cpu', in_memory=True)
hparams = whisper_model.dims
print(f'Model dims: n_mels={hparams.n_mels}, n_audio_state={hparams.n_audio_state}, n_audio_layer={hparams.n_audio_layer}')

print('Converting encoder to CoreML...')
coreml_encoder = convert_encoder(hparams, whisper_model.encoder)

output_path = '$OUTPUT_DIR/coreml-encoder-large-v3.mlpackage'
print(f'Saving to {output_path}')
coreml_encoder.save(output_path)
print('Done converting encoder to mlpackage')
"

echo ""
echo "=== Step 2: Compile mlpackage to mlmodelc ==="
MLPACKAGE="$OUTPUT_DIR/coreml-encoder-large-v3.mlpackage"
if [ ! -d "$MLPACKAGE" ]; then
    echo "ERROR: mlpackage not found at $MLPACKAGE"
    exit 1
fi

xcrun coremlc compile "$MLPACKAGE" "$OUTPUT_DIR/"
rm -rf "$OUTPUT_DIR/ggml-large-v3-encoder.mlmodelc"
mv -v "$OUTPUT_DIR/coreml-encoder-large-v3.mlmodelc" "$OUTPUT_DIR/ggml-large-v3-encoder.mlmodelc"

echo ""
echo "=== Step 3: Rename mlpackage ==="
rm -rf "$OUTPUT_DIR/ggml-large-v3-encoder.mlpackage"
mv -v "$MLPACKAGE" "$OUTPUT_DIR/ggml-large-v3-encoder.mlpackage"

echo ""
echo "=== Done ==="
echo "Generated:"
du -sh "$OUTPUT_DIR/ggml-large-v3-encoder.mlmodelc"
du -sh "$OUTPUT_DIR/ggml-large-v3-encoder.mlpackage"
