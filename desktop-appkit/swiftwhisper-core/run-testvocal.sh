#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_DIR="$ROOT/desktop-appkit/swiftwhisper-core"
AUDIO_FILE="$ROOT/testvocal.m4a"
SDK_CXX_HEADERS="/Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk/usr/include/c++/v1"

cd "$PACKAGE_DIR"
CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" swift run -c release scribby-swiftwhisper-headless "$AUDIO_FILE"
