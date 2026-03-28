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
- 目前版本：`v0.7.0-beta`
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
  - `proofread.py`（AI 校稿，mlx-lm + Gemma 3 Text 4B）
- `scripts/`
  - `generate-largev3-coreml.sh`（CoreML encoder 轉換腳本）

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
  - 設定持久化：`UserDefaults`（語言、模型、開關）+ `Keychain`（HuggingFace Token）
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
    - 標準化 WAV
    - chunked headless ASR
    - pyannote diarization
    - Core ML encoder 準備
- `Sources/Bridge/AudioChunking.swift`
  - 固定長度切段
  - overlap 去重
  - chunk transcript 合併
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
  - `ProofreadingMode` enum（`off / conservative / standard / readable`）
  - `ProcessingPhase` enum（含 `.proofreading`）
- `Sources/Support/PathResolver.swift`
  - Application Support
  - Python（含 `systemPythonCandidates` 共用常數）
  - helper script（含 `proofreadingHelperScript()`）
  - ffmpeg
  - model cache（含 `proofreadingModelCacheDirectory()`）
- `Sources/Support/PythonEnvironmentManager.swift`
  - 就地重建 Python env
  - enhancement / diarization / proofreading 分段安裝
  - standalone Python 下載
- `Sources/Support/KeychainHelper.swift`
  - **已改為 file-based 儲存**（`{AppSupport}/.credentials`，JSON，mode 0600）
  - 原因：macOS Keychain ACL 與 code signature 綁定，每次 ad-hoc rebuild 後都要重新授權
  - 安全性等同 `~/.ssh/id_rsa`，不走 Keychain
- `Sources/Support/WhisperModelPreset.swift`
  - 模型 preset 定義
- `Sources/Support/DebugLogger.swift`
  - **新增**：crash-safe 檔案型 debug logger
  - singleton，寫入 `{AppSupport}/debug-logs/debug-yyyy-MM-dd_HH-mm-ss.log`
  - 每次寫入後呼叫 `synchronizeFile()`，crash 前資料不會遺失
  - 最多保留 5 個 log 檔，自動刪除最舊的
  - 所有 Python subprocess 的 log 都走 `DebugLogger`，不再推送到 UI

## 4. 處理鏈資料流

### 主流程

1. 使用者在 UI 加入檔案
2. `NativeAppModel` 呼叫 `TranscriptionProvider`
3. `SwiftWhisperProvider` 依設定決定是否：
   - 先做人聲加強
   - 再做 ASR
   - 最後做多語者辨識
   - 最後（若 proofreadingMode != .off）做 AI 校稿
4. provider 把狀態事件回推到 `NativeAppModel`
5. `RootView` 只吃 `NativeAppModel` 的 published state

### ASR 路線

1. `SwiftWhisperProvider` 先把輸入音檔標準化成 `16kHz mono WAV`
2. 長音檔會在 pipeline 層切成固定 chunks：
   - chunk 長度：`120 秒`
   - overlap：`1.5 秒`
3. 每個 chunk 個別啟動 `scribby-swiftwhisper-headless`
4. headless 來自 `swiftwhisper-core`
5. `swiftwhisper-core` 使用本地 vendored `SwiftWhisper`
6. vendored `SwiftWhisper` 底層是 vendored `whisper.cpp`
7. 支援多語言（auto / zh / en / ja / ko / es / fr / de 等 99+ 語言）
8. chunk 結果在 app 層做時間 offset 與 overlap 去重合併
9. headless 事件仍以 NDJSON stream 回傳：
   - `progress`
   - `partial_segments`
   - `completed`
   - `failed`

### 多語者辨識路線

1. `SwiftWhisperProvider` 完成全部 ASR chunks 合併後
2. 若開啟語者辨識，就呼叫 `python/pyannote_diarize.py`
3. diarization 對齊回 merged ASR segments
4. 最終結果仍回到同一份 `TranscriptResult`

### AI 校稿路線

1. ASR（+ 可選 diarization）完成後
2. 若 `proofreadingMode != .off`，呼叫 `TranscriptionPipelineRunner.runProofreading()`
3. `PythonEnvironmentManager.ensureReady(.proofreading)` 確保 `mlx-lm` 已安裝
4. 啟動 `python/proofread.py`，stdin 傳入 JSON（segments + mode + language）
5. 腳本使用 `mlx-community/gemma-3-text-4b-it-4bit`（HF_HOME = `{AppSupport}/mlx-models/`）
6. sliding window 批次推理（BATCH_SIZE=5，前後各 2 段做 context）
7. stdout 回傳 JSON，Swift 解析後覆蓋 segments 的 text
8. **失敗時 fallback 原始轉寫**，不影響轉寫結果
9. 所有 log 寫入 `DebugLogger`

#### 三種校稿模式

| 模式 | 說明 |
|------|------|
| `conservative` 保守校正 | 只修明顯同音字錯誤，補缺失標點，其餘不動 |
| `standard` 一般校正 | 修錯別字、補標點、小幅改寫語境不通順短句 |
| `readable` 可讀版整理 | 刪口語冗詞（嗯啊那個）、合併重複語句、適度重組 |

#### 語言規則

- 輸入語言 = 輸出語言（最高優先）
- 例外：輸入為簡體中文 → 自動轉繁體中文輸出
- 簡體中文偵測：SwiftWhisper 回傳的語言碼統一是 `zh`，不分簡繁，所以改用文字內容啟發式偵測（取樣前 20 段，高頻簡體字比例 > 1% 即判定為簡體）

#### mlx_lm API 注意事項

安裝版本的 `generate()` 已移除 `temperature=` 參數，溫度設定改由 `sampler` 物件傳入：

```python
from mlx_lm.sample_utils import make_sampler
sampler = make_sampler(temp=TEMPERATURE)
generate(model, tokenizer, prompt=..., max_tokens=..., sampler=sampler, verbose=False)
```

### 人聲加強路線

1. 若開啟人聲加強，provider 先呼叫 `python/speech_enhance.py`
2. 產生 enhancement 後的暫存音檔
3. provider 再標準化成 `16kHz mono WAV`
4. 長音檔會再切成 chunks
5. 把這份標準化後音檔 / chunks 交給 headless ASR

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

### AI 校稿

- helper：`desktop-appkit/python/proofread.py`
- 第一次用到才補裝 `mlx-lm`
- 模型：`mlx-community/gemma-3-text-4b-it-4bit`（約 2.6 GB）
- 模型快取放在 `{AppSupport}/mlx-models/`（透過 `HF_HOME` env 控制）
- `build.sh` 在編譯後自動把 `proofread.py` 複製進 app bundle 的 `Resources/python/`

### Python 版本策略

- enhancement / proofreading / diarization 共同使用單一 `python-env`
- Python 主線固定收斂到 `3.12.x`
- `PythonEnvironmentManager` 會先找合格 Python 3.12
- 找不到時，自動下載 standalone CPython `3.12.8` 到：
  - `~/Library/Application Support/com.minrui.scribby/python-standalone/`

### 目前 App Support 相關路徑

- `~/Library/Application Support/com.minrui.scribby/`
  - `python-env/`
  - `python-standalone/`
  - `swiftwhisper-models/`（Whisper .bin + CoreML encoder 資產；`large-v3` 可能含本機編譯出的 `.mlmodelc` 與手動放入的 `.mlpackage`）
  - `mlx-models/`（AI 校稿 LLM，由 HuggingFace snapshot_download 下載）
  - `.credentials`（file-based 憑證儲存，mode 0600，取代 Keychain）
  - `env-manifest.json`（Python 環境版本指紋）
  - `debug-logs/`（crash-safe debug log，最多 5 個，自動輪替）

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

目前 Core ML 策略已統一為 `mlpackage-first`：

- `large-v3-turbo`
- `large-v3`
  - 都不再依賴遠端預編譯 `.mlmodelc.zip`
  - 會優先使用本機現有 `.mlmodelc`
  - 若只有 `.mlpackage`，就先在本機編譯成 `.mlmodelc`
  - 若本機沒有 package，會下載對應的 `mlpackage.zip`
  - 若本機編譯或載入逾時失敗，會刪除 `.mlmodelc` 並在本次任務改走 CPU-only

相關責任：

- `PathResolver`
  - 找 bundle seed / App Support cache / remote URL
- `SwiftWhisperProvider`
  - 啟動前同步／準備模型
- `swiftwhisper-core`
  - 真正載入模型與 encoder

## 8. 設定持久化

### 持久化的設定項

| 設定 | 儲存位置 | key |
|------|----------|-----|
| `selectedLanguage` | UserDefaults | `selectedLanguage` |
| `selectedModelPreset` | UserDefaults | `selectedModelPreset` |
| `diarizeEnabled` | UserDefaults | `diarizeEnabled` |
| `enhancementEnabled` | UserDefaults | `enhancementEnabled` |
| `speakers` | UserDefaults | `speakers` |
| `proofreadingMode` | UserDefaults | `proofreadingMode` |
| `proofreadingIntroductionAcknowledged` | UserDefaults | `proofreadingIntroductionAcknowledged` |
| HuggingFace Token | `KeychainHelper`（file-based） | `huggingface-token` |

- 各 `@Published` 屬性透過 `didSet` 自動寫入
- `bootstrap()` 時由 `loadPersistedSettings()` 一次性讀回
- Token 儲存在 `{AppSupport}/.credentials`（JSON，mode 0600），而非 macOS Keychain
  - 原因：Keychain ACL 與 code signature 綁定，ad-hoc rebuild 後需重新授權，開發不便
  - 安全性等同 `~/.ssh/id_rsa`

## 9. 分發注意事項

### 簽名與公證

- `build.sh` 目前只做 ad-hoc 簽名（`codesign --force --sign -`）
- 未經 Apple 公證，其他使用者首次開啟需要右鍵 → 打開，或 `xattr -cr`
- 完整解法：用 Developer ID 簽名 + `xcrun notarytool submit`

### 平台限制

- 只編譯 arm64（`build.sh` 寫死 `-target arm64-apple-macosx13.0`）
- Intel Mac 完全不支援，會直接 crash
- 人聲加強（MLX）也只支援 Apple Silicon

### 首次使用依賴

- Whisper 模型需網路下載（1.5~2.9 GB）
- `large-v3-turbo` / `large-v3` 的 Core ML encoder package 可能需網路下載，並在本機編譯
- Python 環境首次用到語者辨識/人聲加強/AI 校稿時自動建立
- AI 校稿模型（Gemma 3 Text 4B）第一次啟用時會先提示，之後首次使用自動下載（約 2.6 GB）至 `{AppSupport}/mlx-models/`
- 找不到系統 Python 3.12.x 時會自動下載 standalone CPython 3.12.8

### 網路連線

- 所有外部連線都走 HTTPS（HuggingFace、GitHub）
- 沒有設定 `NSAppTransportSecurity`（預設 ATS 即可）

## 10. 版本與發版邏輯

### 版本字串目前在哪裡

至少要同步這兩處：

1. `README.md`
   - 標題目前是 `# Scribby v0.7.0-beta`
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

- `v0.5.1-beta`
  - native 主線
  - menu bar、icon、standalone Python、自動環境建置
  - 多語言支援（auto + 99 語言）
  - QueueItemStatus enum 取代裸字串
  - 設定持久化（UserDefaults + Keychain）
  - 模型下載完整性驗證
  - DownloadDelegate 全面加鎖
- `v0.5.2-beta`
  - 長音檔 chunked ASR（`120s + 1.5s overlap`）
  - chunk-level resume 語意
  - `PROJECT_CONTEXT.md` 對齊目前架構真相
  - 補上 Keychain / 設定持久化 / 分發注意事項
- `v0.6.0-beta`
  - **AI 校稿**（本地 Gemma 3 Text 4B，三種模式，mlx-lm 推理）
  - 自動偵測簡體中文並轉換為繁體中文
  - `DebugLogger`：crash-safe 檔案型 log，取代 UI log 輸出，自動輪替（最多 5 個）
  - `KeychainHelper`：改用 file-based 儲存（`{AppSupport}/.credentials`，mode 0600）
  - 新增 `proofreadingMode` 設定（UserDefaults）
  - `ProcessingPhase` 補上 `.proofreading`
  - 模型管理頁與管理模型下載 UI
- `v0.6.1-beta`
  - Python / proofreading env 收斂為單一版本矩陣，主線固定 Python `3.12.x`
  - proofreading `mlx-lm` 固定為 `0.31.1`
  - 長音檔 chunked ASR 補上 chunk 層級 diagnostics
  - log 會記錄 chunk 總數、起訖範圍、start / done / fail、merge 結果與 diarization 對齊結果
- `v0.6.2-beta`
  - `large-v3-turbo` 與 `large-v3` 都改成 `mlpackage-first`
  - Core ML encoder 下載來源統一為 `mlpackage.zip`，在本機編譯為 `.mlmodelc`
  - AI 校稿改為第一次啟用時先提示，再下載本地模型
  - 軟體資訊、資料管理、README 文案同步到目前的分發與本地執行策略
- `v0.7.0-beta`
  - 首次 onboarding 改為逐題 wizard，並在安裝頁一次準備模型、encoder 與功能環境
  - Core ML / Whisper 路線修正 stride 與輸出讀取錯誤，恢復正確轉譯內容
  - AI 校稿過程可視化改成固定卡片，並顯示同步校正後的文字片段
  - 資料管理頁補強快取與模型偵測，包含 AI 校稿模型快取

## 11. UI / 互動邏輯提醒

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
  - chunk-level resume
  - enhancement / normalize 不重跑
  - 已完成 chunks 保留
  - 若在 ASR chunk 中暫停，恢復後從該 chunk 繼續
  - 若在 diarization 階段暫停，恢復後重跑 diarization 階段
- `停止`
  - 當前檔案標成 `stopped`
  - 清掉該檔案的 chunk state / temp
  - 不自動繼續

這不是 `whisper.cpp` decoder checkpoint resume，而是 **chunk-level resume**。

## 12. 已知技術債／注意事項

### AVFoundation warnings

主要在 `TranscriptionPipelineRunner.convertToWAV(...)`：

- deprecated API
- Swift 6 sendable warnings

目前不是 runtime blocker，但之後值得收。

### enhancement / diarization / proofreading env

跨電腦時最容易炸的是：

- Python minor 不合
- enhancement / proofreading env 漂版本
- helper import path 與套件版本不相容

所以如果別台電腦出問題，先查：

- `PythonEnvironmentManager.swift`
- `speech_enhance.py`
- `pyannote_diarize.py`
- `proofread.py`
- App Support 裡的 `python-env`

### mlx_lm API 版本陷阱

`mlx_lm.generate()` 在較新版本移除了 `temperature=` / `temp=` 直接參數，
改用 `sampler` 物件（`mlx_lm.sample_utils.make_sampler`）傳入溫度設定。

如果看到：`TypeError: generate_step() got an unexpected keyword argument 'temperature'`
→ 確認 `proofread.py` 使用 `make_sampler(temp=...)` 並把 `sampler=` 傳給 `generate()`

### `long audio` 尾端 completed event

之前修過 headless 最終事件 flush 問題。
如果未來又看到：

- `SwiftWhisper 沒有回傳最終結果`

優先查：

- `swiftwhisper-core/Sources/SwiftWhisperHeadless/main.swift`
- `TranscriptionPipelineRunner.runHeadless(...)`

### 長音檔穩定性

目前長音檔穩定性主修法已改成 pipeline 層 chunking，而不是整支音檔一次丟進單次 ASR。

- `AudioChunking.swift`
  - 固定 `120s + 1.5s overlap`
  - 產生 chunk 清單
  - 做 overlap 去重與合併
- `SwiftWhisperProvider`
  - 會保留單檔的 chunk progress state
  - pause/resume 依賴這份狀態，不再整檔重跑

若之後還要再提升長音檔品質，下一步才是評估：

- silence-aware chunking
- VAD-aware chunking
- chunk 級 diarization 策略

## 13. 建議每次開工前先確認

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
   - 測 AI 校稿（各模式、簡繁轉換）
   - 測 pause / stop / clear queue

## 14. 如果之後要叫我先看這份

可以直接講：

- `先讀 PROJECT_CONTEXT.md 再開始`
- `先依照 PROJECT_CONTEXT.md 理解目前架構`
- `請先用 PROJECT_CONTEXT.md 對齊版本邏輯和資料流`
