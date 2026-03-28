# Scribby v0.8.0-beta

Scribby 是一個以 macOS 為主的本地語音轉寫工具，支援人聲增強、語者辨識、AI 校稿，以及 `readable` 模式下的 AI 主旨改名與摘要。

## 目前能力

- 本地轉譯：`SwiftWhisper + whisper.cpp + Core ML`
- 模型選擇：`tiny`、`large-v3-turbo`、`large-v3`
- 人聲增強：`mlx-audio`
- 語者辨識：`pyannote.audio`
- AI 校稿：`Gemma 3 Text 4B`
- `readable` 模式額外提供：
  - AI 主旨檔名
  - AI 摘要預覽與下載

## 產品特性

- 音訊在本地處理，不會離開電腦
- 首次啟動會透過 wizard 準備所選功能
- Whisper 模型與 Core ML encoder 採 `mlpackage-first`
- `large-v3-turbo` / `large-v3` 會優先嘗試 `CPU_AND_NE`，失敗後再退到 `CPU_AND_GPU`，最後才是 CPU-only
- UI 不直接顯示底層 log；等待中的狀態用卡片、進度條與動畫表達

## 系統需求

- macOS 13 以上
- Apple Silicon
- 首次使用需網路連線以下載模型與建立環境

## 安裝

從 [Releases](https://github.com/minrui-z/Scribby/releases) 下載最新版本，解壓後拖入 `Applications`。

目前為 beta，app 尚未完成 Apple 公證。首次開啟若被系統阻擋，可用以下任一方式：

1. Finder 對 app 按右鍵，選「打開」
2. 或在終端機執行：

```bash
xattr -cr /path/to/逐字搞定\ Beta.app
```

## 首次啟動

首次啟動會進入逐題 onboarding wizard，依序設定：

1. 是否開啟人聲增強
2. 使用哪個轉譯模型
3. 是否開啟語者辨識
4. 是否開啟 AI 校稿，以及校稿模式
5. 安裝頁集中準備：
   - 轉譯模型
   - Core ML encoder
   - enhancement / diarization / proofreading 環境
   - AI 校稿模型

## 本地資料

模型、Python 環境、AI 校稿模型與 debug logs 會放在：

- `~/Library/Application Support/com.minrui.scribby/`

設定、首次精靈旗標與模型偏好則存在 `UserDefaults`。

## 開發

```bash
cd desktop-appkit
./build.sh
```

產物位置：

- `desktop-appkit/build/逐字搞定 Beta.app`

## 文件

- [PROJECT_CONTEXT.md](./PROJECT_CONTEXT.md)
  - 架構真相、資料流、模型策略、路徑與已知設計
- [CLAUDE.md](./CLAUDE.md)
  - 長期 invariant、發版規則、工作原則
- [desktop-appkit/README.md](./desktop-appkit/README.md)
  - 原生 workspace 的最短 build 入口
