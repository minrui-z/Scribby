# Scribby v0.2.0-beta

Scribby 現在以 **macOS 原生 SwiftUI/AppKit 版本** 作為主線。

這一版的核心方向：
- `SwiftWhisper + Core ML` 做逐字稿轉寫
- `pyannote` 做真正的多語者 diarization
- Native UI/UX 取代舊的 Tauri 桌面版

## Repo 結構

- `desktop-appkit/`
  原生 macOS app 主線
- `desktop-appkit/Sources/`
  App、Bridge、UI、Support
- `desktop-appkit/swiftwhisper-core/`
  headless SwiftWhisper 核心
- `desktop-appkit/vendor/SwiftWhisper/`
  本地 fork 的 SwiftWhisper / whisper.cpp 相容層
- `desktop-appkit/python/pyannote_diarize.py`
  多語者辨識 helper

## 目前狀態

- 預設模型：`large-v3-turbo`
- 結果輸出：分時間分段稿
- 語者辨識：需 Hugging Face token
- 檔案加入：支援拖放與原生檔案選取

## 開發

```bash
cd desktop-appkit
./build.sh
```

編譯完成後，app 會在：

```bash
desktop-appkit/build/逐字搞定 Beta.app
```

## 備註

- 這個 repo 已不再以舊 `desktop/` Tauri 版本作為主線。
- 大型模型與 Core ML 資產不直接放進 Git；開發與執行時會優先使用本機快取與必要的下載流程。
