# Scribby v0.3.0-beta

macOS 原生語音轉文字工具，支援多語者辨識與人聲加強。

## 功能

- **SwiftWhisper + Core ML** 轉寫，支援 Apple Neural Engine 加速
- **pyannote 多語者辨識**（需 HuggingFace token）
- **MossFormer2 人聲加強**（MLX 加速）
- 分段彩色進度條，即時顯示各處理階段
- 下載資訊卡片，顯示模型下載進度與速度
- 首次使用自動安裝 Python 環境與依賴套件
- CoreML encoder 自動從 HuggingFace 下載

## 安裝

從 [Releases](https://github.com/minrui-z/Scribby/releases) 下載最新版本，解壓後拖入 Applications。

首次開啟可能需要到「系統設定 → 隱私權與安全性」允許執行。

## Repo 結構

- `desktop-appkit/` — 原生 macOS app 主線
- `desktop-appkit/Sources/` — App、Bridge、UI、Support
- `desktop-appkit/swiftwhisper-core/` — headless SwiftWhisper 核心
- `desktop-appkit/vendor/SwiftWhisper/` — 本地 fork 的 SwiftWhisper / whisper.cpp
- `desktop-appkit/python/` — pyannote 語者辨識、speech enhancement helper

## 開發

```bash
cd desktop-appkit
./build.sh
```

編譯完成後 app 在 `desktop-appkit/build/逐字搞定 Beta.app`。

## 系統需求

- macOS 13+
- Apple Silicon（M1 以上，Core ML / MLX 加速）
- Python 3（首次使用時自動安裝）
