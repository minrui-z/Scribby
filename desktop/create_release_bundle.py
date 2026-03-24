from __future__ import annotations

import argparse
import shutil
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
APP_SOURCE = PROJECT_ROOT / "desktop" / "tauri" / "src-tauri" / "target" / "release" / "bundle" / "macos" / "逐字搞定 Beta.app"
RELEASE_DIR = PROJECT_ROOT / "release"
APP_TARGET = RELEASE_DIR / "逐字搞定 Beta.app"
README_TARGET = RELEASE_DIR / "README.txt"
RUNTIME_SOURCE = PROJECT_ROOT / "desktop" / "runtime"


README_TEXT = """逐字搞定 Beta

版本：0.1.0-beta.1
平台：macOS Apple Silicon

使用方式：
1. 雙擊「逐字搞定 Beta.app」
2. 若 macOS 安全性阻擋，請在系統設定允許後再次開啟
3. 第一次模型載入可能較久

注意事項：
- 這是 beta 版
- 只支援 macOS Apple Silicon
- 已內嵌 Python runtime 與 ffmpeg
- 音訊轉譯仍可能受模型下載、 Hugging Face Token、語者分離模型授權影響
"""


def copy_runtime_into_app(app_root: Path) -> None:
    resource_root = app_root / "Contents" / "Resources" / "_up_" / "_up_" / "_up_" / "desktop" / "runtime"
    resource_root.mkdir(parents=True, exist_ok=True)

    for name in ("bin", "lib"):
        source = RUNTIME_SOURCE / name
        target = resource_root / name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(source, target)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    if not APP_SOURCE.exists():
        raise SystemExit(f"找不到已打包的 App：{APP_SOURCE}")

    if args.clean and RELEASE_DIR.exists():
        shutil.rmtree(RELEASE_DIR)

    RELEASE_DIR.mkdir(parents=True, exist_ok=True)
    if APP_TARGET.exists():
        shutil.rmtree(APP_TARGET)

    shutil.copytree(APP_SOURCE, APP_TARGET)
    copy_runtime_into_app(APP_TARGET)
    README_TARGET.write_text(README_TEXT, encoding="utf-8")
    print(f"Prepared release folder at: {RELEASE_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
