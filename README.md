# Scribby

Scribby 是 `macOS Apple Silicon` 專用的桌面版語音轉譯應用原始碼。

這個 repo 只包含桌面版需要的來源，不包含原本的 Web 測試版，也不包含已打包的 `.app`、Python runtime、`node_modules` 或 build 產物。

## 內容

- `desktop/`: 桌面版工作區
- `engine.py`: 轉譯核心
- `transcribe_worker.py`: 任務 worker
- `runtime_paths.py`: runtime 路徑解析

## 開發環境

- macOS Apple Silicon
- Python 3.10+
- Node.js
- Rust / Cargo

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
