# 桌面版瘦身禁刪清單

這份清單只適用於 `desktop/` 桌面版。每次調整 `desktop/prepare_python_runtime.py` 或 release 流程前，都要先看這份，再跑完整 smoke test。

## 一定不能盲刪的內容

- `torch.testing`
  刪掉後 `import torch` 會直接壞。

- `numpy._core.tests`
  這個環境下刪掉後可能讓 `numpy` import 失敗。

- `scipy` 內部子模組
  `mlx-whisper` 會用到 `scipy`，不要因為體積大就裁內部樹。

- `pyannote-audio`、`pyannote-core`、`pyannote-database`、`pyannote-metrics`、`pyannote-pipeline`
  語者分離直接依賴這條鏈，不能拆散刪。

- `torch`、`torchaudio`
  語者分離模型會用到，不能只保留表面 `.dist-info`。

- `mlx`、`mlx_whisper`
  這是桌面版主轉譯引擎，不能動它們的 runtime 內容。

## 可以瘦，但只能定點處理

- `whisperx`
  不能整包照 dependency closure 帶進去，會把 `faster-whisper`、`ctranslate2`、`onnxruntime`、`av`、`nltk` 一起拖進來。
  目前桌面版只保留：
  - `__init__.py`
  - `audio.py`
  - `diarize.py`
  - `log_utils.py`
  - `schema.py`
  - `utils.py`

- `torch/include`、`torch/share`
  可刪，屬於 build/header 資產。

- `mlx/include`、`mlx/share`
  可刪，屬於 build/header 資產。

- `__pycache__`、`*.pyc`、`*.pyo`
  可刪。

## 現階段已知可不帶的肥大依賴

這些已從桌面版 runtime 排除，之後瘦身時不要又因 dependency metadata 把它們帶回來：

- `faster-whisper`
- `ctranslate2`
- `onnxruntime`
- `av`
- `nltk`
- `torchcodec`

其中 `torchcodec` 被拿掉後，`pyannote.audio` 會出 warning，但桌面版目前走 `whisperx.audio.load_audio()` 先把 waveform 載入記憶體再送進 diarization，所以這個 warning 可接受，不是 blocker。

## 每次瘦身前後必做檢查

1. 先確認 `desktop/prepare_python_runtime.py` 沒有全域遞迴刪：
   - `tests`
   - `test`
   - `testing`
   - `docs`
   - `examples`

2. 重建 runtime：
   - `venv/bin/python desktop/prepare_python_runtime.py --clean`

3. 跑語法檢查：
   - `venv/bin/python -m py_compile desktop/python_backend.py desktop/adapters/transcription_service.py desktop/prepare_python_runtime.py desktop/smoke_test_desktop_bundle.py`
   - `node --check desktop/frontend/app.js`

4. 跑桌面 bundle smoke test：
   - `npm run build`
   - `npm run release:bundle`

5. smoke test 至少要通過這兩層：
   - bundled backend 能回 `backend_ready`
   - bundle 內可 `import mlx_whisper`、`from whisperx.diarize import DiarizationPipeline`

## 目前已知會直接出大問題的回歸症狀

- `No module named 'torch.testing'`
- `No module named 'numpy._core.tests'`
- `Broken pipe (os error 32)`，通常代表 backend 因 import-time crash 提前死掉
- 「選取音訊檔」或存檔完全沒反應
  先檢查桌面版是否仍走 `osascript choose file / choose file name` 路線，不要把 `rfd` / `tauri-plugin-dialog` 再帶回來。

- 點選選檔直接 crash
  `NSOpenPanel` 在這個桌面版環境裡不穩，不要再改回 `rfd` 或 `tauri-plugin-dialog` 的原生檔案對話框。

- 選檔卡在「正在開啟選檔視窗」
  不要用 `System Events` 來切前景；桌面版只允許用 `tell application id "com.minrui.zhuzigaoding" to activate` 後再跑 `choose file / choose file name`。
