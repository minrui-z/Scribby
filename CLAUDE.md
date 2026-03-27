# Scribby 規則摘要

這份文件只保留長期不太變的 invariant。

實際架構、資料流、路徑、模型與版本細節，請看：

- [PROJECT_CONTEXT.md](./PROJECT_CONTEXT.md)

## 產品定位

- 專案名稱：Scribby / 逐字搞定
- 主線產品：macOS 原生語音轉寫 app
- 主線目錄：`desktop-appkit/`
- 目前不再以舊 Tauri `desktop/` 為主線

## 平台與硬限制

- Bundle ID：`com.minrui.scribby`
- App 名稱：`逐字搞定 Beta`
- 最低系統：macOS 13
- 目標架構：Apple Silicon（arm64）
- 人聲加強依賴 MLX，因此 enhancement 只支援 Apple Silicon

## 核心技術決策

- ASR 主線：`SwiftWhisper + whisper.cpp + Core ML`
- 多語者辨識：`pyannote.audio`
- 人聲加強：`mlx-audio`
- Python 功能採「首次使用時就地重建環境」策略
- 大模型與 Python 套件不預設打進 `.app`

## 版本規則

- 版本號要同步至少兩處：
  - `README.md`
  - `desktop-appkit/Resources/Info.plist`
- release 使用 git tag
- 命名規則：
  - `v{major}.{minor}.{patch}`
  - beta 可加後綴，例如 `v0.5.0-beta`

## 發版最低流程

1. 同步版本字串
2. `cd desktop-appkit && ./build.sh`
3. commit
4. tag
5. push branch + tag
6. 建 GitHub release

## 工作原則

- 優先保持行為等價，不要在重構時偷偷改產品語意
- 文件角色固定：
  - `CLAUDE.md`：規則與 invariant
  - `PROJECT_CONTEXT.md`：架構真相
  - `desktop-appkit/README.md`：最短入口
- 若修改會影響：
  - Python env
  - model cache
  - App Support 路徑
  - pause/stop 語意
  - 結果卡版面
  必須在 `PROJECT_CONTEXT.md` 補記
