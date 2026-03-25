# Scribby SwiftWhisper Core

這是 `desktop-appkit/` 內獨立的 headless SwiftWhisper 核心驗證區。

目前目標：
- 預設使用 `ggml-tiny.bin`
- 固定語言 `zh`
- 不做 UI
- 不做 diarization
- 不做 HuggingFace token
- 只驗證「純 Swift transcription 可行」

主要結構：
- `Package.swift`：獨立 SwiftPM package
- `Sources/SwiftWhisperCore`：核心型別、模型快取、音訊解碼
- `Sources/SwiftWhisperHeadless`：CLI 入口
- `run-testvocal.sh`：直接用 repo root 的 `testvocal.m4a` 驗證

預期使用方式：

```bash
cd desktop-appkit/swiftwhisper-core
swift build -c release
./run-testvocal.sh
```

目前已完成：
- `SwiftWhisperCore`
- `SwiftWhisperRequest`
- `SwiftWhisperResult`
- `ModelStore`
- `AudioDecoder`
- headless CLI 入口
- `SwiftWhisper` 依賴已鎖定固定 revision
- 模型配置已抽成 preset，可切換 `tiny / large-v3-turbo / large-v3`
- `large-v3-turbo` / `large-v3` 已完成第一輪實測，但目前這版 `SwiftWhisper` 依賴鏈會在 128-mel 模型上失敗，尚不能直接升級為預設

目前阻塞：
- 這台機器的 Command Line Tools 缺少完整 libc++ headers
- `swift build` 在編譯 `SwiftWhisper` 依賴的 `whisper.cpp` 時會卡在：

```text
fatal error: 'algorithm' file not found
```

這不是 `swiftwhisper-core` 本身的 Swift 程式碼錯誤，而是本機 C++ toolchain 不完整。
