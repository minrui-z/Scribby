# Scribby

Scribby 是一個 `macOS Apple Silicon` 專用的桌面版語音轉譯專案。  
它使用 `Tauri + Python backend`，把本地語音轉文字流程包成真正的桌面 App，而不是依賴瀏覽器開啟 localhost。

這個 repo 只包含桌面版需要的原始碼，不包含舊的 Web 測試版，也不包含已打包的 `.app`、`node_modules`、Python runtime 或其他 build 產物。

## 目前狀態

- 平台：`macOS Apple Silicon only`
- 版本線：`beta`
- 桌面殼：`Tauri 2`
- 後端：`Python`
- 轉譯核心：`MLX Whisper`

## 功能

- 本機音訊檔案批次加入與排隊
- 即時轉譯進度與逐行漂浮字幕
- 可選語者分離
- 單檔 `.txt` 匯出與全部結果打包下載
- 桌面視窗執行，不需手動開瀏覽器

## 專案結構

- [desktop/](desktop): 桌面版工作區
- [desktop/frontend/](desktop/frontend): 桌面前端
- [desktop/tauri/](desktop/tauri): Tauri shell 與打包設定
- [desktop/python_backend.py](desktop/python_backend.py): 桌面版 Python backend
- [engine.py](engine.py): 轉譯核心
- [transcribe_worker.py](transcribe_worker.py): 任務 worker
- [runtime_paths.py](runtime_paths.py): runtime 路徑解析

## 開發需求

- macOS 13+
- Apple Silicon Mac
- Python 3.10+
- Node.js
- Rust / Cargo
- `ffmpeg`

## 快速開始

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

cd desktop/tauri
npm install
npm run dev
```

## 打包

```bash
cd desktop/tauri
npm run build
npm run release:bundle
```

打包完成後，release 產物會整理到專案根目錄的 `release/`。

## 設計方向

Scribby 的桌面版介面目前偏向：

- 淺色、高可讀性
- 接近 macOS 的玻璃材質感
- 保留少量動態效果，但不做過度花俏的 UI
- 轉譯中讓主要資訊優先，減少操作干擾

## 限制

- 目前不支援 Windows / Linux / Intel Mac
- `MLX` 路徑下無法安全硬停止當前任務
- 首次模型初始化可能需要較長時間

## 開發說明

桌面版的詳細工作區說明在 [desktop/README.md](desktop/README.md)。
