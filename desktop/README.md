# 逐字搞定 Desktop Workspace

這個資料夾是桌面版工作區，不取代現有 Web 測試版。
目前只支援 `macOS Apple Silicon`。

## 目標

- 使用 `Tauri` 建立真正桌面視窗
- 保留現有 `app.py` / `templates/index.html` 作為 Web 測試版
- 共用 `engine.py` 與 `transcribe_worker.py` 的轉譯核心
- 桌面版打包流程只針對 `.app` 產物優化

## 結構

- `frontend/`: 桌面版靜態前端
- `tauri/`: Tauri shell 與 Rust bridge
- `python_backend.py`: 桌面版專用 Python backend
- `ipc_protocol.py`: Rust <-> Python JSON IPC 協定
- `adapters/`: 轉譯任務與匯出封裝

## 開發前提

- macOS Apple Silicon
- 已安裝 Rust / Cargo
- 已安裝 Node.js
- Python 環境沿用 repo root 的 `venv`
- 不保證 Windows / Linux / Intel Mac 可用

## 預期資料流

1. Tauri 啟動桌面視窗
2. Rust 啟動 `python_backend.py`
3. 前端透過 Tauri command 呼叫 Rust
4. Rust 以 JSON line IPC 將命令送給 Python
5. Python backend 發出任務事件，Rust 轉發給前端

## IPC 形狀

- command: `{"kind":"command","id":"...","command":"...","payload":{...}}`
- response: `{"kind":"response","id":"...","request_id":"...","ok":true,"result":{...}}`
- event: `{"kind":"event","event":"...","data":{...},"payload":{...}}`

`id` 與 `request_id` 會同時存在，方便 Rust/Tauri 與舊的前端 mock 互通。

## 打包原則

- 桌面版 runtime 使用 mac 專用白名單複製，不再整包複製 `site-packages`
- release 前必跑 bundle smoke test，至少確認 `python_backend.py` 能回 `backend_ready`
- 若 smoke test 失敗，不能發佈新的 beta `.app`
