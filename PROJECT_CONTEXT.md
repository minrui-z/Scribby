# Scribby 專案脈絡

這份文件是目前專案的架構真相來源。

建議之後每次開始修改前，先讀這份，再讀對應模組的原始碼。

文件角色固定如下：

- `CLAUDE.md`
  - 長期 invariant、工作規則、版本命名與發版原則
- `PROJECT_CONTEXT.md`
  - 真實架構、資料流、路徑、模型、已知坑
- `desktop-appkit/README.md`
  - 最短 build 入口與指路

## 1. 目前主線

- Repo 主線：`desktop-appkit/`
- 目前產品：macOS 原生 App
- 目前版本：`v0.5.0-beta`
- App 名稱：`逐字搞定 Beta`
- Bundle ID：`com.minrui.scribby`

目前已不再以舊 Tauri `desktop/` 為主線；真正要維護的是 `desktop-appkit/`。

## 2. 目錄結構

### Repo 根目錄

- `README.md`
  - 對外說明、安裝方式、功能摘要
- `PROJECT_CONTEXT.md`
  - 這份文件，專案脈絡與版本／架構提醒
- `desktop-appkit/`
  - 原生 app 主線

### `desktop-appkit/`

- `build.sh`
  - 原生 app build 入口
- `README.md`
  - workspace 簡述
- `Resources/`
  - `Info.plist`
  - `AppIcon.icns`
- `Sources/`
  - `App/`
  - `Bridge/`
  - `UI/`
  - `Support/`
- `swiftwhisper-core/`
  - headless ASR 核心
- `vendor/SwiftWhisper/`
  - 本地 fork 的 SwiftWhisper + whisper.cpp
- `python/`
  - `pyannote_diarize.py`
  - `speech_enhance.py`
- `scripts/`
  - 額外工具腳本

## 3. Source 分層

### `Sources/App`

負責 app 啟動、視窗、菜單列、整體狀態控制。

主要檔案：

- `Sources/App/main.swift`
  - app 入口
  - 建立原生 menu bar
  - 建立 `NativeWindowController`
  - 建立 `NativeAppModel`
- `Sources/App/NativeWindowController.swift`
  - 視窗尺寸、背景、宿主 window
- `Sources/App/NativeAppModel.swift`
  - UI façade
  - 套用 provider snapshot
  - 提供 view 需要的 published state
  - 只透過 `TranscriptionProvider` 操作底層
- `Sources/App/AppStatusCenter.swift`
  - 集中管理 `pickerStatus` / `actionStatus`
  - 管理 diagnostics 與浮字
  - 封裝 idle / error / paused 類型的短訊息策略
- `Sources/App/SleepWakeCoordinator.swift`
  - 掛 `NSWorkspace.willSleepNotification`
  - 掛 `NSWorkspace.didWakeNotification`
  - 對 `NativeAppModel` 回呼安全暫停與喚醒提示

### `Sources/Bridge`

負責把 UI 狀態和底層處理鏈接起來。

主要檔案：

- `Sources/Bridge/TranscriptionProvider.swift`
  - provider 介面定義
- `Sources/Bridge/SwiftWhisperProvider.swift`
  - provider façade
  - 協調 queue reducer、process supervisor 與 pipeline runner
- `Sources/Bridge/QueueStateReducer.swift`
  - 集中所有 `ProviderSnapshot` 狀態轉換
  - 包含 enqueue / start / pause / resume / stop / clear / remove
- `Sources/Bridge/ProcessSupervisor.swift`
  - 持有 enhancement / headless / pyannote subprocess
  - 統一 terminate 與 temp file 清理
- `Sources/Bridge/TranscriptionPipelineRunner.swift`
  - 單檔 pipeline engine
  - 串：
    - 人聲加強
    - headless ASR
    - pyannote diarization
    - Core ML encoder 準備
- `Sources/Bridge/DialogService.swift`
  - 檔案對話框與相關原生互動

### `Sources/UI`

負責所有 SwiftUI / AppKit bridge 的畫面。

主要檔案：

- `Sources/UI/RootView.swift`
  - 主畫面、完成態版面、設定抽屜、按鈕、結果卡
- `Sources/UI/GlassChrome.swift`
  - 共用按鈕與 glass / chrome 樣式
- `Sources/UI/NativeFields.swift`
  - 原生輸入欄位 bridge

### `Sources/Support`

負責共用資料型別、路徑、log、環境管理。

主要檔案：

- `Sources/Support/AppModels.swift`
  - `QueueItemStatus` enum（`pending / processing / done / error / stopped`）
  - `QueueItemModel`（status 用 enum，非裸字串）
  - `TranscriptResult`
  - `ProviderSnapshot`
  - `ProviderEvent`
- `Sources/Support/PathResolver.swift`
  - Application Support
  - Python（含 `systemPythonCandidates` 共用常數）
  - helper script
  - ffmpeg
  - model cache
- `Sources/Support/PythonEnvironmentManager.swift`
  - 就地重建 Python env
  - enhancement / diarization 分段安裝
  - standalone Python 下載
- `Sources/Support/WhisperModelPreset.swift`
  - 模型 preset 定義
- `Sources/Support/NativeLogger.swift`
  - log 寫入 App Support

## 4. 處理鏈資料流

### 主流程

1. 使用者在 UI 加入檔案
2. `NativeAppModel` 呼叫 `TranscriptionProvider`
3. `SwiftWhisperProvider` 依設定決定是否：
   - 先做人聲加強
   - 再做 ASR
   - 最後做多語者辨識
4. provider 把狀態事件回推到 `NativeAppModel`
5. `RootView` 只吃 `NativeAppModel` 的 published state

### ASR 路線

1. `SwiftWhisperProvider` 啟動 `scribby-swiftwhisper-headless`
2. headless 來自 `swiftwhisper-core`
3. `swiftwhisper-core` 使用本地 vendored `SwiftWhisper`
4. vendored `SwiftWhisper` 底層是 vendored `whisper.cpp`
5. 支援多語言（auto / zh / en / ja / ko / es / fr / de 等 99+ 語言）
6. 結果以 NDJSON event stream 回傳：
   - `progress`
   - `partial_segments`
   - `completed`
   - `failed`

### 多語者辨識路線

1. `SwiftWhisperProvider` 完成 ASR 後
2. 若開啟語者辨識，就呼叫 `python/pyannote_diarize.py`
3. diarization 對齊回 ASR segments
4. 最終結果仍回到同一份 `TranscriptResult`

### 人聲加強路線

1. 若開啟人聲加強，provider 先呼叫 `python/speech_enhance.py`
2. 產生 enhancement 後的暫存音檔
3. provider 再標準化成 `16kHz mono WAV`
4. 把這份標準化後音檔交給 headless ASR

## 5. 轉碼／解碼邏輯

這塊之前踩過坑，後面改時要小心。

### 核心檔案

- `desktop-appkit/swiftwhisper-core/Sources/SwiftWhisperCore/AudioDecoding.swift`

### 現在的解碼順序

1. `AVFoundation`
2. 若本來就是 WAV，走 direct WAV parse
3. 再不行才走 `ffmpeg` fallback

### 已修掉的重要問題

以前 enhancement 輸出的 `48kHz mono WAV` 曾被 direct WAV parse 直接當成 `16kHz` 餵給 Whisper，導致：

- 時間尺度錯三倍
- 字幕完全跑偏

現在 direct WAV parse 會：

- 讀 WAV header
- 取得：
  - `sampleRate`
  - `channelCount`
  - `bitsPerSample`
- 再重採樣到 `16k`
- 再生成最終 `monoFrames`

### 另一層保護

provider 現在也會在人聲加強後，先把音檔統一轉成標準 `16kHz mono WAV` 再交給 headless。

也就是說，現在有兩層保護：

- provider 標準化
- core 端 WAV 正確解碼與重採樣

## 6. Python / helper 邏輯

### 原則

- app 本體盡量保持小
- 不 bundle 大模型與完整 Python runtime
- 採「首次用到功能時就地重建」策略

### Enhancement

- helper：`desktop-appkit/python/speech_enhance.py`
- Python 依賴由 `PythonEnvironmentManager` 依需求安裝
- 目前 enhancement 用 MLX / `mlx-audio`

### Diarization

- helper：`desktop-appkit/python/pyannote_diarize.py`
- 第一次用到才補裝 `torch / pyannote.audio / pandas`

### Python 版本策略

- enhancement 需要 Python `>= 3.10`
- `PythonEnvironmentManager` 會先找合格 Python
- 找不到時，可下載 standalone CPython 到：
  - `~/Library/Application Support/com.minrui.scribby/python-standalone/`

### 目前 App Support 相關路徑

- `~/Library/Application Support/com.minrui.scribby/`
  - `python-env/`
  - `python-standalone/`
  - `swiftwhisper-models/`
  - logger 輸出

## 7. 模型邏輯

### 目前模型 preset

位置：

- `desktop-appkit/Sources/Support/WhisperModelPreset.swift`

目前定義：

- `tiny`
- `large-v3-turbo`
- `large-v3`

目前預設：

- `WhisperModelPreset.default = .largeV3`

### 模型資產

Whisper 模型與 Core ML encoder 現在不跟 app bundle 一起肥打包，而是 runtime 下載／準備。下載完成後會驗證檔案大小（< 1MB 視為損壞）並比對 HTTP Content-Length。

相關責任：

- `PathResolver`
  - 找 bundle seed / App Support cache / remote URL
- `SwiftWhisperProvider`
  - 啟動前同步／準備模型
- `swiftwhisper-core`
  - 真正載入模型與 encoder

## 8. 版本與發版邏輯

### 版本字串目前在哪裡

至少要同步這兩處：

1. `README.md`
   - 標題目前是 `# Scribby v0.5.0-beta`
2. `desktop-appkit/Resources/Info.plist`
   - `CFBundleShortVersionString`
   - `CFBundleVersion`

### App 名稱相關

- `Info.plist`
  - `CFBundleDisplayName`
  - `CFBundleName`
- build 產物名稱目前是：
  - `desktop-appkit/build/逐字搞定 Beta.app`

### icon

- 檔案：
  - `desktop-appkit/Resources/AppIcon.icns`
- `Info.plist` 要有：
  - `CFBundleIconFile = AppIcon`
- `build.sh` 會把它複製進 bundle

### 發版基本流程

1. 調整版本字串
2. `cd desktop-appkit && ./build.sh`
3. 確認 build 成功
4. 在 repo commit
5. tag 版本
6. push branch + tag
7. 建 GitHub release

### 已知版本節點

- `v0.5.0-beta`
  - native 主線
  - menu bar、icon、standalone Python、自動環境建置等都已進來

## 9. UI / 互動邏輯提醒

### 目前主畫面分層

- 初始態：標題、加入區、佇列、設定
- 轉譯中：
  - top chrome：`正在聆聽…`、`+`、`設定`
  - 中間佇列
  - 底部浮字
- 完成態：
  - 左上加入區
  - 左下佇列
  - 右側結果卡區

### 結果卡

- 每張結果卡是固定模板：
  - header
  - 內容預覽框
  - 底部 `複製 / 下載`
- 這裡之前調過很多次比例，改動時要小心不要再把按鈕擠出卡片

### pause / stop 的產品語意

- `暫停`
  - 安全暫停
  - 當前檔案回 `pending`
  - 恢復後從頭重跑
- `停止`
  - 當前檔案標成 `stopped`
  - 不自動繼續

這不是「真 resume」。

## 10. 已知技術債／注意事項

### AVFoundation warnings

主要在 `SwiftWhisperProvider` 的 `convertToWAV(...)`：

- deprecated API
- Swift 6 sendable warnings

目前不是 runtime blocker，但之後值得收。

### enhancement / diarization env

跨電腦時最容易炸的是：

- Python minor 不合
- enhancement env 漂版本
- helper import path 與套件版本不相容

所以如果別台電腦出問題，先查：

- `PythonEnvironmentManager.swift`
- `speech_enhance.py`
- `pyannote_diarize.py`
- App Support 裡的 `python-env`

### `long audio` 尾端 completed event

之前修過 headless 最終事件 flush 問題。
如果未來又看到：

- `SwiftWhisper 沒有回傳最終結果`

優先查：

- `swiftwhisper-core/Sources/SwiftWhisperHeadless/main.swift`
- `SwiftWhisperProvider.runHeadless(...)`

## 11. 建議每次開工前先確認

1. 現在主線是不是 `desktop-appkit/`
2. 版本號是否要同步改：
   - `README.md`
   - `Info.plist`
3. 這次是改：
   - UI
   - provider
   - core
   - Python helper
   哪一層
4. 是否會影響：
   - App Support 路徑
   - Python env
   - model cache
   - 結果卡版面
5. 改完要不要重新：
   - `./build.sh`
   - 測 enhancement
   - 測 diarization
   - 測 pause / stop / clear queue

## 12. 如果之後要叫我先看這份

可以直接講：

- `先讀 PROJECT_CONTEXT.md 再開始`
- `先依照 PROJECT_CONTEXT.md 理解目前架構`
- `請先用 PROJECT_CONTEXT.md 對齊版本邏輯和資料流`
