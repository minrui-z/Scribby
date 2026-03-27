#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_DIR="$ROOT/desktop-appkit/swiftwhisper-core"
SDK_CXX_HEADERS="/Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk/usr/include/c++/v1"

if [[ -n "${1:-}" ]]; then
  AUDIO_FILE="$1"
elif [[ -f "$ROOT/testvocal.m4a" ]]; then
  AUDIO_FILE="$ROOT/testvocal.m4a"
elif [[ -f "$ROOT/../testvocal.m4a" ]]; then
  AUDIO_FILE="$ROOT/../testvocal.m4a"
else
  echo "找不到 testvocal.m4a，請把音檔路徑當成第一個參數傳入。" >&2
  exit 1
fi

cd "$PACKAGE_DIR"
CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" swift run -c release scribby-swiftwhisper-headless "$AUDIO_FILE"
