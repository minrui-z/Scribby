# Scribby SwiftWhisper Core

這個資料夾不是單純的實驗區，而是 Scribby 目前實際使用的 headless ASR 核心。

它負責：

- `scribby-swiftwhisper-headless`
  - 供 app 在 chunked ASR 時呼叫
- `scribby-coreml-diagnose`
  - Core ML package / compile / load 的獨立診斷工具

## 主要結構

- `Package.swift`
  - SwiftPM package 定義
- `Sources/SwiftWhisperCore`
  - 核心型別、模型快取、音訊解碼
- `Sources/SwiftWhisperHeadless`
  - NDJSON headless CLI
- `Sources/SwiftWhisperCoreMLDiagnose`
  - Core ML load 診斷入口

## 目前角色

- app 端的 chunked ASR 會啟動 `scribby-swiftwhisper-headless`
- `large-v3-turbo` / `large-v3` 的 Core ML encoder 驗證、fallback 與診斷都會經過這裡
- `.wav` 輸入會優先走 direct WAV parse；非 WAV 才先試 `AVFoundation`，再 fallback 到 `ffmpeg`

## 常見用途

```bash
cd desktop-appkit/swiftwhisper-core
swift build -c release
```

建出來的 binary 會放在：

- `.build/apple/Products/Release/scribby-swiftwhisper-headless`
- `.build/apple/Products/Release/scribby-coreml-diagnose`

## 注意

- 這裡和 `desktop-appkit/` 主線是同一套產品的一部分，不要再把它當成舊的驗證沙盒
- 若修改音訊解碼、模型載入、Core ML bridge 或 headless event 格式，必須同步更新：
  - [../PROJECT_CONTEXT.md](../PROJECT_CONTEXT.md)
