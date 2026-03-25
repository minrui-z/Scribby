# 逐字搞定 Native Workspace

這是獨立於現有 `desktop/` 的原生重構工作區。

目標：
- 不影響目前的 Tauri 桌面版
- 用 SwiftUI + AppKit bridge 建立 macOS 原生主線
- 沿用既有 `desktop/python_backend.py`、`desktop/adapters/`、`engine.py` 等轉譯核心

目前結構：
- `Sources/App`：App 啟動、視窗、狀態模型
- `Sources/Bridge`：Python backend 與原生對話框橋接
- `Sources/UI`：原生畫面與 glass chrome
- `Sources/Support`：logger、路徑解析
- `swiftwhisper-core/`：獨立 headless SwiftWhisper 核心驗證區
- `build.sh`：編譯與組裝獨立 `.app`

注意：
- 這是隔離重構工作區，尚未取代現有桌面版
- 原生版已不再依賴 `desktop/frontend/dist`
- 真正的大體積仍主要來自 `desktop/runtime`
