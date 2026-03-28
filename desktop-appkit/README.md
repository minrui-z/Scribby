# 逐字搞定 Native Workspace

這裡是 Scribby 的原生 macOS 主線。

## Build

```bash
cd desktop-appkit
./build.sh
```

產物位置：

- `desktop-appkit/build/逐字搞定 Beta.app`

## 這裡包含什麼

- `Sources/`
  - App、Bridge、Support、UI
- `swiftwhisper-core/`
  - headless ASR 核心與 Core ML 診斷工具
- `python/`
  - 人聲增強、語者辨識、AI 校稿 helper
- `vendor/SwiftWhisper/`
  - vendored `SwiftWhisper / whisper.cpp`

## 文件入口

- 專案架構與資料流：
  - [../PROJECT_CONTEXT.md](../PROJECT_CONTEXT.md)
- 長期規則與發版原則：
  - [../CLAUDE.md](../CLAUDE.md)
