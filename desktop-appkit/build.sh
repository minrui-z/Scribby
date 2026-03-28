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
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")"
SDK_CXX_HEADERS="$SDK_PATH/usr/include/c++/v1"

mkdir -p "$BUILD_DIR"
mkdir -p "$WORKSPACE/.build/swift-module-cache"

SWIFT_SOURCES=(
  "$WORKSPACE"/Sources/App/*.swift
  "$WORKSPACE"/Sources/Bridge/*.swift
  "$WORKSPACE"/Sources/UI/*.swift
  "$WORKSPACE"/Sources/Support/*.swift
)

MACOSX_DEPLOYMENT_TARGET=13.0
export MACOSX_DEPLOYMENT_TARGET

CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
/usr/bin/xcrun swift build \
  -c release \
  --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
  --product scribby-swiftwhisper-headless \
  --product scribby-coreml-diagnose

SWIFTWHISPER_BIN_DIR="$(
  CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
  /usr/bin/xcrun swift build \
    -c release \
    --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
    --product scribby-swiftwhisper-headless \
    --product scribby-coreml-diagnose \
    --show-bin-path
)"
HEADLESS_BIN="$SWIFTWHISPER_BIN_DIR/scribby-swiftwhisper-headless"
DIAGNOSE_BIN="$SWIFTWHISPER_BIN_DIR/scribby-coreml-diagnose"

if [[ ! -x "$HEADLESS_BIN" ]]; then
  CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
  /usr/bin/xcrun swift build \
    -c release \
    --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
    --product scribby-swiftwhisper-headless
fi

if [[ ! -x "$DIAGNOSE_BIN" ]]; then
  CPLUS_INCLUDE_PATH="$SDK_CXX_HEADERS" \
  /usr/bin/xcrun swift build \
    -c release \
    --package-path "$SWIFTWHISPER_PACKAGE_DIR" \
    --product scribby-coreml-diagnose
fi

/usr/bin/xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$WORKSPACE/.build/swift-module-cache" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Foundation \
  -framework UniformTypeIdentifiers \
  "${SWIFT_SOURCES[@]}" \
  -o "$BUILD_DIR/ScribbyNative"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR/bin"
mkdir -p "$RES_DIR/python"
cp "$BUILD_DIR/ScribbyNative" "$BIN_DIR/"
cp "$HEADLESS_BIN" "$RES_DIR/bin/"
cp "$DIAGNOSE_BIN" "$RES_DIR/bin/"
cp "$WORKSPACE/python/pyannote_diarize.py" "$RES_DIR/python/"
cp "$WORKSPACE/python/speech_enhance.py" "$RES_DIR/python/"
cp "$WORKSPACE/python/proofread.py" "$RES_DIR/python/"
cp "$WORKSPACE/Resources/Info.plist" "$APP_DIR/Contents/"
if [[ -f "$WORKSPACE/Resources/AppIcon.icns" ]]; then
  cp "$WORKSPACE/Resources/AppIcon.icns" "$RES_DIR/"
fi
if [[ -f "$WORKSPACE/Resources/AppIconSource.png" ]]; then
  cp "$WORKSPACE/Resources/AppIconSource.png" "$RES_DIR/"
fi

# Models and CoreML encoders are downloaded/prepared at runtime on first launch.
# App bundle ships without model assets to stay minimal.

xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR" || echo "codesign skipped: bundle contains metadata that still needs cleanup"
echo "Built native shell app at: $APP_DIR"
