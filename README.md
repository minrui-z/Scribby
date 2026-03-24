# Scribby / 逐字搞定

[![Download Beta](https://img.shields.io/badge/Download-Beta-1f1a17?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/minrui-z/Scribby/releases/tag/v0.1.0-beta.1)

**Scribby** is a desktop transcription project for `macOS Apple Silicon`.  
**逐字搞定** 是一個專為 `macOS Apple Silicon` 設計的桌面語音轉譯專案。

## Release

- Latest beta release: [`v0.1.0-beta.1`](https://github.com/minrui-z/Scribby/releases/tag/v0.1.0-beta.1)
- Download asset: [`Scribby-Beta-0.1.0-beta.1-macos-arm64.zip`](https://github.com/minrui-z/Scribby/releases/download/v0.1.0-beta.1/Scribby-Beta-0.1.0-beta.1-macos-arm64.zip)
- GitHub Releases: <https://github.com/minrui-z/Scribby/releases>
- Recommended distribution format: packaged `.app` delivered via the release zip
- Release line: `beta`

- 最新 beta 版本：[`v0.1.0-beta.1`](https://github.com/minrui-z/Scribby/releases/tag/v0.1.0-beta.1)
- 下載檔案：[`Scribby-Beta-0.1.0-beta.1-macos-arm64.zip`](https://github.com/minrui-z/Scribby/releases/download/v0.1.0-beta.1/Scribby-Beta-0.1.0-beta.1-macos-arm64.zip)
- GitHub 發佈頁：<https://github.com/minrui-z/Scribby/releases>
- 建議提供給使用者的格式：透過 release zip 發佈的已打包 `.app`
- 目前版本線：`beta`

## Status / 目前狀態

- Platform / 平台: `macOS Apple Silicon only`
- Shell / 桌面殼: `Tauri 2`
- Backend / 後端: `Python`
- Transcription engine / 轉譯核心: `MLX Whisper`
- App phase / 階段: `beta`

## Features / 功能

- Batch audio import and queue management
- Live progress updates with floating transcript lines
- Optional speaker diarization
- Single `.txt` export and zip export for all completed results
- Native desktop window without requiring users to open a browser

- 本機音訊檔案批次加入與序列管理
- 即時轉譯進度與逐行漂浮字幕
- 可選語者分離
- 單檔 `.txt` 匯出與全部結果壓縮下載
- 原生桌面視窗執行，不需手動開瀏覽器


## Requirements / 開發需求

- macOS 13+
- Apple Silicon Mac
- Python 3.10+
- Node.js
- Rust / Cargo
- `ffmpeg`

## Quick Start / 快速開始

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

cd desktop/tauri
npm install
npm run dev
```


## Design Direction / 設計方向

- Light UI with strong readability
- macOS-inspired glass surface treatment
- Subtle motion instead of flashy UI
- Focus on transcription progress and minimal distraction during processing

- 淺色介面與高可讀性
- 接近 macOS 的玻璃材質感
- 保留細微動態效果，不追求花俏 UI
- 轉譯中以內容與進度為主，減少干擾

## Limitations / 限制

- Not supported on Windows, Linux, or Intel Mac
- `MLX` mode cannot safely hard-stop the current task
- First-time model initialization can take longer

- 目前不支援 Windows、Linux 或 Intel Mac
- `MLX` 模式下無法安全硬停止目前任務
- 首次模型初始化可能需要較長時間

## Workspace Notes / 工作區說明

See [desktop/README.md](desktop/README.md) for desktop workspace details.  
桌面版工作區的詳細說明請見 [desktop/README.md](desktop/README.md)。
