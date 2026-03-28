# Scribby 規則摘要

這份文件只保留長期不太變的 invariant。

架構真相、資料流、模型策略與目前版本細節，請看：

- [PROJECT_CONTEXT.md](./PROJECT_CONTEXT.md)

## 文件角色

- `README.md`
  - 對外說明、安裝方式、功能摘要
- `CLAUDE.md`
  - 長期規則、產品 invariant、發版原則
- `PROJECT_CONTEXT.md`
  - 目前架構真相、資料流、路徑與模型策略
- `desktop-appkit/README.md`
  - 原生 workspace 的最短入口

## 產品定位

- 專案名稱：Scribby / 逐字搞定
- 主線產品：macOS 原生語音轉寫 app
- 主線目錄：`desktop-appkit/`
- 舊 `desktop/` 不再是維護主線

## 平台與硬限制

- Bundle ID：`com.minrui.scribby`
- App 名稱：`逐字搞定 Beta`
- 最低系統：macOS 13
- 目標架構：Apple Silicon（arm64）
- 人聲增強依賴 MLX，因此 enhancement 僅支援 Apple Silicon

## 長期技術決策

- ASR 主線：`SwiftWhisper + whisper.cpp + Core ML`
- 多語者辨識：`pyannote.audio`
- 人聲增強：`mlx-audio`
- AI 校稿：本地 LLM（目前為 Gemma 3 Text 4B）
- Python 功能採「首次使用時就地重建環境」策略
- 大模型與 Python 套件不預設打進 `.app`
- 使用者可見層不直接顯示 raw log

## 產品層 invariant

- 音訊資料以本地處理為原則，不主動離開電腦
- onboarding 與設定必須維持同一套語意，不可互相矛盾
- `readable` 視為 AI 校稿最高等級；AI 主旨改名與摘要只在這個模式啟用
- 資料管理頁應反映真實已安裝資產，不可與實際快取狀態脫節
- 若改動會影響：
  - Python env
  - model cache
  - App Support 路徑
  - Core ML 載入策略
  - onboarding 安裝流程
  - 結果卡與摘要資料流
  必須同步更新 `PROJECT_CONTEXT.md`

## 版本與發版規則

- 版本號至少同步兩處：
  - `README.md`
  - `desktop-appkit/Resources/Info.plist`
- release 使用 git tag
- 命名規則：
  - `v{major}.{minor}.{patch}`
  - beta 可加後綴，例如 `v0.8.0-beta`

## 發版最低流程

1. 同步版本字串
2. `cd desktop-appkit && ./build.sh`
3. commit
4. tag
5. push branch + tag
6. 建 GitHub release
