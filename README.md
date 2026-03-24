# Scribby / 逐字搞定

**Scribby** is a desktop transcription project for `macOS Apple Silicon`.  
**逐字搞定** 是一個專為 `macOS Apple Silicon` 設計的桌面語音轉譯專案。

It uses `Tauri + Python backend` to package local speech-to-text workflows into a real desktop app instead of exposing a browser-based localhost app.  
它使用 `Tauri + Python backend`，把本地語音轉文字流程包成真正的桌面 App，而不是讓使用者面對瀏覽器中的 localhost 網頁。

This repository contains the desktop app source only. It does not include the old web test version, bundled Python runtime, `node_modules`, or built `.app` artifacts.  
這個 repository 只包含桌面版原始碼，不包含舊的 Web 測試版、內嵌 Python runtime、`node_modules` 或已打包的 `.app` 產物。

## Release

- GitHub Releases: <https://github.com/minrui-z/Scribby/releases>
- Recommended distribution format: packaged `.app` from the Releases page
- Release line: `beta`

- GitHub 發佈頁：<https://github.com/minrui-z/Scribby/releases>
- 建議提供給使用者的版本：Releases 頁面中的已打包 `.app`
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

## Project Structure / 專案結構

- [desktop/](desktop): desktop workspace / 桌面版工作區
- [desktop/frontend/](desktop/frontend): desktop frontend / 桌面前端
- [desktop/tauri/](desktop/tauri): Tauri shell and packaging / Tauri shell 與打包設定
- [desktop/python_backend.py](desktop/python_backend.py): desktop Python backend / 桌面版 Python backend
- [engine.py](engine.py): transcription core / 轉譯核心
- [transcribe_worker.py](transcribe_worker.py): task worker / 任務 worker
- [runtime_paths.py](runtime_paths.py): runtime path resolution / runtime 路徑解析

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

## Build / 打包

```bash
cd desktop/tauri
npm run build
npm run release:bundle
```

Release artifacts are collected into the root `release/` folder after bundling.  
打包完成後，release 產物會整理到專案根目錄的 `release/`。

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
