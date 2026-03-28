#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATE_SCRIPT="$SCRIPT_DIR/generate-largev3-coreml.sh"
DIAGNOSE_BIN="$WORKSPACE/swiftwhisper-core/.build/arm64-apple-macosx/release/scribby-coreml-diagnose"

if [ ! -x "$GENERATE_SCRIPT" ]; then
    echo "ERROR: 找不到 generate-largev3-coreml.sh"
    exit 1
fi

if [ ! -x "$DIAGNOSE_BIN" ]; then
    echo "ERROR: 找不到 scribby-coreml-diagnose，請先在 desktop-appkit 跑 ./build.sh"
    exit 1
fi

LOAD_TIMEOUT="${SCRIBBY_COREML_LOAD_TIMEOUT:-120}"
GENERATE_TIMEOUT="${SCRIBBY_COREML_GENERATE_TIMEOUT:-900}"
MATRIX_COREMLTOOLS="${SCRIBBY_COREMLTOOLS_MATRIX:-8.3.0 9.0}"
MATRIX_TORCH="${SCRIBBY_COREML_TORCH_VERSION:-2.7.0}"
MATRIX_WHISPER="${SCRIBBY_COREML_WHISPER_VERSION:-20250625}"
MATRIX_ANE="${SCRIBBY_COREML_ANE_TRANSFORMERS_VERSION:-0.1.1}"
MATRIX_PYTHON="${SCRIBBY_COREML_PYTHON:-python3.11}"
MATRIX_NUMPY="${SCRIBBY_COREML_NUMPY_VERSION:-}"
MATRIX_METHODS="${SCRIBBY_COREML_METHOD_MATRIX:-baseline}"

if [ "$#" -gt 0 ]; then
    MODELS=("$@")
else
    MODELS=("large-v3-turbo" "large-v3")
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_ROOT="$WORKSPACE/coreml-matrix-results/$TIMESTAMP"
mkdir -p "$RESULT_ROOT"
SUMMARY_CSV="$RESULT_ROOT/summary.csv"
printf "model,coremltools,method,generate_status,load_status,diagnose_json\n" > "$SUMMARY_CSV"

sanitize() {
    echo "$1" | tr '.-' '__'
}

for model in "${MODELS[@]}"; do
    for coremltools_version in ${(z)MATRIX_COREMLTOOLS}; do
        for export_method in ${(z)MATRIX_METHODS}; do
            case_name="${model}-ct${coremltools_version}-${export_method}"
            case_dir="$RESULT_ROOT/$case_name"
            model_dir="$case_dir/model-dir"
            log_file="$case_dir/generate.log"
            diagnose_file="$case_dir/diagnose.json"
            venv_dir="$WORKSPACE/.venv-coreml-matrix-ct$(sanitize "$coremltools_version")-torch$(sanitize "$MATRIX_TORCH")"
            if [ -n "$MATRIX_NUMPY" ]; then
                venv_dir="${venv_dir}-numpy$(sanitize "$MATRIX_NUMPY")"
            fi

            mkdir -p "$case_dir"
            rm -rf "$model_dir"

            echo ""
            echo "=== [$case_name] generate ==="
            set +e
            python3 - <<PY >"$log_file" 2>&1
import os
import signal
import subprocess
import sys

env = os.environ.copy()
env.update({
    "SCRIBBY_COREMLTOOLS_VERSION": "${coremltools_version}",
    "SCRIBBY_COREML_TORCH_VERSION": "${MATRIX_TORCH}",
    "SCRIBBY_COREML_WHISPER_VERSION": "${MATRIX_WHISPER}",
    "SCRIBBY_COREML_ANE_TRANSFORMERS_VERSION": "${MATRIX_ANE}",
    "SCRIBBY_COREML_PYTHON": "${MATRIX_PYTHON}",
    "SCRIBBY_COREML_VENV": "${venv_dir}",
    "SCRIBBY_COREML_OUTPUT_DIR": "${model_dir}",
    "SCRIBBY_COREML_NUMPY_VERSION": "${MATRIX_NUMPY}",
    "SCRIBBY_COREML_EXPORT_METHOD": "${export_method}",
})

process = subprocess.Popen(
    ["zsh", "${GENERATE_SCRIPT}", "${model}"],
    env=env,
)

try:
    sys.exit(process.wait(timeout=${GENERATE_TIMEOUT}))
except subprocess.TimeoutExpired:
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    print("ERROR: generate timeout after ${GENERATE_TIMEOUT}s", file=sys.stderr)
    sys.exit(124)
PY
            generate_status=$?
            set -e

            if [ "$generate_status" -ne 0 ]; then
                echo "[$case_name] generate failed"
                printf "%s,%s,%s,failed,skipped,%s\n" "$model" "$coremltools_version" "$export_method" "$diagnose_file" >> "$SUMMARY_CSV"
                continue
            fi

            echo "=== [$case_name] diagnose ==="
            set +e
            "$DIAGNOSE_BIN" "$model" --model-dir "$model_dir" --timeout "$LOAD_TIMEOUT" >"$diagnose_file"
            diagnose_status=$?
            set -e

            if [ "$diagnose_status" -eq 0 ]; then
                load_status="ok"
            else
                load_status="failed"
            fi

            printf "%s,%s,%s,ok,%s,%s\n" "$model" "$coremltools_version" "$export_method" "$load_status" "$diagnose_file" >> "$SUMMARY_CSV"
            echo "[$case_name] load_status=$load_status"
        done
    done
done

echo ""
echo "Matrix results saved to: $RESULT_ROOT"
echo "Summary: $SUMMARY_CSV"
