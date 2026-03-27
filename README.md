# Scribby v0.6.1-beta

macOS 原生語音轉文字工具，支援多語者辨識、人聲加強與 AI 校稿。

## 功能

- **SwiftWhisper + Core ML** 轉寫，支援 Apple Neural Engine 加速，99+ 語言自動偵測
- **AI 校稿**（本地 LLM，Gemma 3 Text 4B，三種模式）：保守校正、一般校正、可讀版整理
  - 模型本地推理，不需網路（首次下載後離線可用）
- **pyannote 多語者辨識**（需 HuggingFace token）
- **MossFormer2 人聲加強**（MLX 加速）
- 分段彩色進度條，即時顯示各處理階段
- 下載資訊卡片，顯示模型下載進度與速度
- 首次使用自動安裝 Python 環境與依賴套件
- CoreML encoder 自動從 HuggingFace 下載

## 安裝

從 [Releases](https://github.com/minrui-z/Scribby/releases) 下載最新版本，解壓後拖入 Applications。

## Repo 結構

- `desktop-appkit/` — 原生 macOS app 主線
- `desktop-appkit/Sources/` — App、Bridge、UI、Support
- `desktop-appkit/swiftwhisper-core/` — headless SwiftWhisper 核心
- `desktop-appkit/vendor/SwiftWhisper/` — 本地 fork 的 SwiftWhisper / whisper.cpp
- `desktop-appkit/python/` — pyannote 語者辨識、speech enhancement、AI 校稿 helper

## 開發

```bash
cd desktop-appkit
./build.sh
```

編譯完成後 app 在 `desktop-appkit/build/逐字搞定 Beta.app`。

## 系統需求

- macOS 13 (Ventura) 以上
- Apple Silicon（M1 以上）— Intel Mac 不支援
- 首次使用需要網路連線（自動下載 Whisper 模型，約 1.5~2.9 GB）

## 首次開啟

App 目前未經 Apple 公證，首次開啟時 macOS 會阻擋。請使用以下方式開啟：

1. 在 Finder 中對 app 按右鍵（或 Control + 點擊）→ 選擇「打開」→ 再點「打開」
2. 或在終端機執行：`xattr -cr /path/to/逐字搞定\ Beta.app`

之後就可以正常雙擊開啟。

## 注意事項

- 語者辨識功能需要 [HuggingFace Token](https://huggingface.co/settings/tokens)，並在 pyannote 模型頁面完成授權
- 人聲加強功能使用 MLX，僅支援 Apple Silicon
- Python 環境會在首次使用語者辨識或人聲加強時自動建立（找不到系統 Python 時會自動下載獨立版本）
- 部分少見音檔格式可能需要安裝 [ffmpeg](https://formulae.brew.sh/formula/ffmpeg)（`brew install ffmpeg`）
- AI 校稿使用 `mlx-community/gemma-3-text-4b-it-4bit`（約 2.6 GB），首次使用時自動下載至 App Support
