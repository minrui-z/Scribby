# Scribby 專案脈絡

這份文件是目前專案的架構真相來源。

若要修改功能，建議先讀這份，再讀對應模組原始碼。

## 1. 目前主線

- Repo 主線：`desktop-appkit/`
- 產品型態：macOS 原生語音轉寫 app
- 目前版本：`v0.8.0-beta`
- App 名稱：`逐字搞定 Beta`
- Bundle ID：`com.minrui.scribby`
- 平台限制：Apple Silicon、macOS 13+

## 2. 文件角色

- `README.md`
  - 對外說明、安裝、功能摘要
- `CLAUDE.md`
  - 長期 invariant、發版規則、工作原則
- `PROJECT_CONTEXT.md`
  - 架構真相、資料流、模型策略、路徑與已知設計
- `desktop-appkit/README.md`
  - 原生 workspace 的最短 build 入口
- `/Users/minrui/Developer/語音辨識/onboard.md`
  - 首次啟動 wizard 的目前規格與文案方向

## 3. 目錄結構

### Repo 根目錄

- `README.md`
- `CLAUDE.md`
- `PROJECT_CONTEXT.md`
- `desktop-appkit/`

### `desktop-appkit/`

- `build.sh`
  - 原生 app build 入口
- `Resources/`
  - `Info.plist`
  - `AppIcon.icns`
- `Sources/`
  - `App/`
  - `Bridge/`
  - `Support/`
  - `UI/`
- `python/`
  - `speech_enhance.py`
  - `pyannote_diarize.py`
  - `proofread.py`
- `swiftwhisper-core/`
  - headless ASR 核心與 Core ML 診斷工具
- `vendor/SwiftWhisper/`
  - vendored `SwiftWhisper` / `whisper.cpp`
- `scripts/`
  - Core ML package 產生與驗證工具

## 4. Source 分層

### `Sources/App`

負責 app 啟動、全域狀態、onboarding、結果操作與 UI façade。

主要檔案：

- `Sources/App/main.swift`
  - app 入口
- `Sources/App/NativeAppModel.swift`
  - 主 UI façade
  - 持有 onboarding wizard 狀態、結果操作、摘要預覽、首次轉譯提示
  - 負責模型切換與 pending queue 背景保留
- `Sources/App/AppStatusCenter.swift`
  - 集中管理：
    - `pickerStatus`
    - `actionStatus`
    - 轉譯內容流
    - AI 校稿內容流
    - 活動回饋卡片
- `Sources/App/SleepWakeCoordinator.swift`
  - 睡眠／喚醒協調

### `Sources/Bridge`

負責把 UI 狀態和底層 pipeline 接起來。

主要檔案：

- `Sources/Bridge/TranscriptionProvider.swift`
  - provider 介面
- `Sources/Bridge/SwiftWhisperProvider.swift`
  - provider façade
  - 協調 queue reducer、pipeline runner、subprocess
  - onboarding 安裝頁的「功能準備」也走這裡
- `Sources/Bridge/QueueStateReducer.swift`
  - `ProviderSnapshot` 狀態轉換
  - 完成態會清除 `phase / activePhases / downloadProgress`
- `Sources/Bridge/TranscriptionPipelineRunner.swift`
  - 單檔 pipeline engine
  - 串接：
    - 轉譯模型與 encoder 準備
    - 人聲增強
    - 標準化 WAV
    - chunked ASR
    - 多語者辨識
    - AI 校稿
    - AI metadata（title / summary）
- `Sources/Bridge/AudioChunking.swift`
  - chunk 切段、overlap 去重、合併

### `Sources/Support`

共用型別、路徑、環境管理與 debug logger。

主要檔案：

- `Sources/Support/AppModels.swift`
  - `TranscriptResult`
  - `ProviderSnapshot`
  - `ProviderEvent`
  - `ProcessingPhase`
  - `ActivityFeedbackState`
  - `AISummaryPreviewModel`
- `Sources/Support/PathResolver.swift`
  - App Support、下載路徑、ffmpeg、bundle helper script、模型快取位置
- `Sources/Support/PythonEnvironmentManager.swift`
  - enhancement / diarization / proofreading 共用 `python-env`
  - 找不到系統 Python 3.12 時，自動下載 standalone Python 3.12.8
- `Sources/Support/WhisperModelPreset.swift`
  - `tiny`
  - `large-v3-turbo`
  - `large-v3`
  - 預設：`.largeV3Turbo`
- `Sources/Support/DebugLogger.swift`
  - 檔案型 debug logger
  - UI 不直接顯示 raw log
- `Sources/Support/KeychainHelper.swift`
  - 實際上是 file-based credentials（`{AppSupport}/.credentials`）

### `Sources/UI`

所有 SwiftUI 與 overlay 呈現。

主要檔案：

- `Sources/UI/RootView.swift`
  - 主畫面
  - onboarding wizard
  - 轉譯內容流卡片
  - AI 校稿打字卡片
  - 活動回饋卡片（下載 / 人聲加強 / 語者辨識 / 切換模型）
  - 結果卡
  - 摘要預覽 overlay
- `Sources/UI/ModelManagerSheet.swift`
  - 資料管理頁

## 5. 首次啟動與 onboarding

目前 onboarding 是逐題 wizard，不是單頁勾選。

順序固定：

1. 是否開啟人聲增強
2. 選擇轉譯模型
3. 是否開啟語者辨識，可選擇當場填入 Hugging Face token
4. 是否開啟 AI 校稿，以及選擇 mode
5. 安裝頁依選擇集中準備資產

安裝頁目前會準備：

- 轉譯模型
- Core ML encoder
- enhancement env
- diarization env（有 token 才實際準備）
- proofreading env
- AI 校稿模型

主要持久化鍵：

- `firstRunWizardCompleted`
- `firstTranscriptionWarmupNoticeShown.{preset}`

## 6. 主要處理鏈

### 主流程

1. 使用者加入音訊檔
2. `NativeAppModel` 呼叫 `TranscriptionProvider`
3. `SwiftWhisperProvider` 依設定決定是否先做人聲增強
4. 音訊先標準化成 `16kHz mono WAV`
5. 長音檔切成 chunks
6. 進入 `scribby-swiftwhisper-headless`
7. 若有開啟語者辨識，ASR 完成後跑 pyannote
8. 若 `proofreadingMode != .off`，最後跑 AI 校稿
9. `readable` 模式下會先產生 `aiSuggestedTitle`
10. `aiSummary` 則由結果卡的 `摘要` 按鈕按需生成

### Audio decoding 順序

`desktop-appkit/swiftwhisper-core/Sources/SwiftWhisperCore/AudioDecoding.swift`

目前順序是：

1. 若輸入本來就是 `.wav`，直接走 direct WAV parse
2. 非 WAV 先嘗試 `AVFoundation`
3. `AVFoundation` 失敗才 fallback 到 `ffmpeg`

這是為了避免已標準化的 WAV 再繞 `AVFoundation`，造成多餘 fallback。

### Chunked ASR

- chunk 長度：`120 秒`
- overlap：`1.5 秒`
- 每個 chunk 都個別跑 headless
- app 層負責時間 offset 和 overlap 去重

## 7. 模型與 Core ML 策略

### 模型 preset

定義在：

- `desktop-appkit/Sources/Support/WhisperModelPreset.swift`

目前：

- `tiny`
- `large-v3-turbo`
- `large-v3`

預設：

- `WhisperModelPreset.default = .largeV3Turbo`

### Core ML 策略

- `tiny`
  - 不走 Core ML encoder
- `large-v3-turbo`
  - `mlpackage-first`
- `large-v3`
  - `mlpackage-first`

兩個大模型都會：

1. 先找本機 `.mlmodelc`
2. 沒有就找本機 `.mlpackage`
3. 再沒有就下載 `mlpackage.zip`
4. 在本機 compile 成 `.mlmodelc`
5. 載入驗證順序：
   - 先 `CPU_AND_NE`
   - 再 `CPU_AND_GPU`
   - 最後才 CPU-only

目前遠端 encoder package 來自：

- `https://huggingface.co/souminei/scribby-coreml-encoders`

### 已修掉的重要 Core ML 問題

vendored `whisper.cpp` Core ML bridge 已修正：

- 動態 input / output 名稱解析
- `float16 / float32` 正確轉換
- 依 `MLMultiArray.strides` 正確讀取 output

這些修正讓 `WhisperKit-style` package 能重新回到可用主線。

## 8. AI 校稿與 `readable` 延伸能力

`desktop-appkit/python/proofread.py`

目前支援兩類輸出：

1. 一般逐段 AI 校稿
2. `metadata` 模式下的：
   - `title`
   - `summary`

### 三種校稿模式

| 模式 | 說明 |
|------|------|
| `conservative` | 只修明顯錯字和缺失標點 |
| `standard` | 修錯字、補標點、小幅整理語句 |
| `readable` | 清理口語冗詞、重複語句，並可生成主旨檔名與摘要 |

### `readable` 額外能力

- `TranscriptResult.aiSuggestedTitle`
  - 完成後同步改結果卡標題
  - 也同步更新 `suggestedFilename`
- `TranscriptResult.aiSummary`
  - 透過結果卡的 `摘要` 按鈕按需生成
  - 完成後開摘要預覽，可複製與下載

摘要生成不應觸發 AI 校稿卡片；目前 UI 已改成只走按鈕 loading 和高層狀態。

## 9. UI 回饋系統

### 原則

- 使用者可見層不直接顯示 raw log
- 每個操作都要有立即回饋
- 需要等待時，用動畫、卡片、按鈕狀態與進度條表達

### 目前底部卡片

- `TranscriptionStreamOverlay`
  - 固定卡片
  - partial text 以「逐句由混亂收束成整齊文字」呈現
- `ProofreadingStreamOverlay`
  - 固定卡片
  - 逐字 reveal
  - 游標跟著打字位置移動
- `ActivityFeedbackOverlay`
  - 下載
  - 人聲加強
  - 語者辨識
  - 切換模型

### 模型切換

`NativeAppModel.switchModel(to:)`

目前規則：

- 正在轉譯時禁止切換
- queue 若混有非 `pending` 項目，禁止切換
- 只有空佇列或純 `pending` 佇列時，才允許切換
- 切換時會背景保留並重新 enqueue `pending` 項目
- UI 只顯示高層狀態，不顯示 provider 重建細節

### 結果卡

結果卡目前支援：

- 複製
- 下載
- `readable` 模式下的 `摘要`

內層結果視窗已限制高度與 clip，避免底部圓角被內容區吃掉。

### 資料管理頁

`Sources/UI/ModelManagerSheet.swift`

目前資料管理頁負責顯示與清理：

- Whisper 模型
- Core ML encoder 資產
- Python 環境
- standalone Python
- AI 校稿模型
- debug logs

這個頁面應反映實際本地快取，而不是只顯示理論上應該存在的資產。

## 10. 持久化與本地資料

### UserDefaults

- `selectedLanguage`
- `selectedModelPreset`
- `diarizeEnabled`
- `enhancementEnabled`
- `speakers`
- `proofreadingMode`
- `firstRunWizardCompleted`
- `firstTranscriptionWarmupNoticeShown.{preset}`

### App Support

- `~/Library/Application Support/com.minrui.scribby/`
  - `swiftwhisper-models/`
  - `python-env/`
  - `python-standalone/`
  - `mlx-models/`
  - `.credentials`
  - `env-manifest.json`
  - `debug-logs/`

### 憑證

Hugging Face token 目前存在：

- `{AppSupport}/.credentials`

原因：

- Keychain ACL 綁 code signature
- ad-hoc rebuild 後開發時會反覆要求授權

## 11. 分發與發版

### Build

```bash
cd desktop-appkit
./build.sh
```

產物：

- `desktop-appkit/build/逐字搞定 Beta.app`

### 目前分發注意事項

- 只支援 Apple Silicon
- 目前仍為 beta
- 尚未完成 Apple 公證
- 首次使用需要網路下載模型與建立環境

### 版本同步

至少同步兩處：

1. `README.md`
2. `desktop-appkit/Resources/Info.plist`

### 發版流程

1. 同步版本字串
2. `./build.sh`
3. commit
4. tag
5. push branch + tag
6. 建 GitHub release
