#!/bin/zsh
set -euo pipefail
setopt null_glob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$ROOT/desktop-appkit"
BUILD_DIR="$WORKSPACE/build"
APP_NAME="逐字搞定 Beta.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SWIFTWHISPER_PACKAGE_DIR="$WORKSPACE/swiftwhisper-core"
SDK_CXX_HEADERS="/Library/Developer/CommandLineTools/SDKs/MacOSX26.0.sdk/usr/include/c++/v1"

mkdir -p "$BUILD_DIR"
mkdir -p "$WORKSPACE/.build/swift-module-cache"

SWIFT_SOURCES=(
  "$WORKSPACE"/Sources/App/*.swift
  "$WORKSPACE"/Sources/Bridge/*.swift
  "$WORKSPACE"/Sources/UI/*.swift
  "$WORKSPACE"/Sources/Support/*.swift
)

CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
/usr/bin/xcrun swift build \
  -c release \
  --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
  --product scribby-swiftwhisper-headless

HEADLESS_BIN="$(
  CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
  /usr/bin/xcrun swift build \
    -c release \
    --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
    --product scribby-swiftwhisper-headless \
    --show-bin-path
)/scribby-swiftwhisper-headless"

/usr/bin/xcrun swiftc \
  -O \
  -parse-as-library \
  -module-cache-path "$WORKSPACE/.build/swift-module-cache" \
  -framework AppKit \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  "${SWIFT_SOURCES[@]}" \
  -o "$BUILD_DIR/ScribbyNative"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR/bin"
mkdir -p "$RES_DIR/python"
mkdir -p "$RES_DIR/swiftwhisper-models"

cp "$BUILD_DIR/ScribbyNative" "$BIN_DIR/"
cp "$HEADLESS_BIN" "$RES_DIR/bin/"
cp "$WORKSPACE/python/pyannote_diarize.py" "$RES_DIR/python/"
cp "$WORKSPACE/Resources/Info.plist" "$APP_DIR/Contents/"

for coreml_asset in \
  "$WORKSPACE"/vendor/SwiftWhisper/whisper.cpp/models/ggml-*-encoder.mlpackage \
  "$WORKSPACE"/vendor/SwiftWhisper/whisper.cpp/models/ggml-*-encoder.mlmodelc \
  "$HOME"/Library/Application\ Support/com.minrui.scribby/swiftwhisper-models/ggml-*-encoder.mlpackage \
  "$HOME"/Library/Application\ Support/com.minrui.scribby/swiftwhisper-models/ggml-*-encoder.mlmodelc \
  "$HOME"/Library/Application\ Support/com.minrui.scribby.native/swiftwhisper-models/ggml-*-encoder.mlpackage \
  "$HOME"/Library/Application\ Support/com.minrui.scribby.native/swiftwhisper-models/ggml-*-encoder.mlmodelc; do
  if [ -e "$coreml_asset" ]; then
    asset_name="$(basename "$coreml_asset")"
    if [ ! -e "$RES_DIR/swiftwhisper-models/$asset_name" ]; then
      cp -R "$coreml_asset" "$RES_DIR/swiftwhisper-models/"
    fi
  fi
done

xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR" || echo "codesign skipped: bundle contains metadata that still needs cleanup"
echo "Built native shell app at: $APP_DIR"
