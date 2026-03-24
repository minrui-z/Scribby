from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_APP = (
    PROJECT_ROOT
    / "desktop"
    / "tauri"
    / "src-tauri"
    / "target"
    / "release"
    / "bundle"
    / "macos"
    / "逐字搞定 Beta.app"
)


def bundled_root(app_path: Path) -> Path:
    root = app_path / "Contents" / "Resources" / "_up_" / "_up_" / "_up_"
    if not root.exists():
        raise SystemExit(f"找不到 bundle resources：{root}")
    return root


def build_env(root: Path) -> dict[str, str]:
    python_home = root / "desktop" / "runtime" / "python"
    python_bin = python_home / "bin" / "python3"
    ffmpeg_bin = root / "desktop" / "runtime" / "bin" / "ffmpeg"
    lib_dir = root / "desktop" / "runtime" / "lib"
    site_packages = python_home / "lib" / "python3.10" / "site-packages"

    env = os.environ.copy()
    env["PYTHONHOME"] = str(python_home)
    env["PYTHONPATH"] = str(site_packages)
    env["PYTHONNOUSERSITE"] = "1"
    env["FFMPEG_BINARY"] = str(ffmpeg_bin)
    env["IMAGEIO_FFMPEG_EXE"] = str(ffmpeg_bin)
    env["PATH"] = os.pathsep.join(
        [
            str(python_home / "bin"),
            str(root / "desktop" / "runtime" / "bin"),
            str(python_home / "lib"),
            env.get("PATH", ""),
        ]
    )
    env["DYLD_LIBRARY_PATH"] = os.pathsep.join(
        [
            str(python_home / "lib"),
            str(lib_dir),
            env.get("DYLD_LIBRARY_PATH", ""),
        ]
    )
    return env


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default=str(DEFAULT_APP))
    args = parser.parse_args()

    app_path = Path(args.app).expanduser().resolve()
    if not app_path.exists():
        raise SystemExit(f"找不到桌面 App：{app_path}")

    root = bundled_root(app_path)
    python_bin = root / "desktop" / "runtime" / "python" / "bin" / "python3"
    backend = root / "desktop" / "python_backend.py"
    env = build_env(root)

    command = [
        str(python_bin),
        str(backend),
    ]

    proc = subprocess.run(
        command,
        input=json.dumps(
            {
                "kind": "command",
                "id": "1",
                "command": "get_info",
                "payload": {},
            },
            ensure_ascii=False,
        )
        + "\n",
        text=True,
        capture_output=True,
        env=env,
        cwd=root / "desktop",
        timeout=30,
    )

    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        raise SystemExit(
            "Desktop bundle smoke test 失敗。\n"
            f"returncode={proc.returncode}\n"
            f"stdout={stdout}\n"
            f"stderr={stderr}"
        )

    lines = [line for line in (proc.stdout or "").splitlines() if line.strip()]
    if not lines:
        raise SystemExit("Desktop bundle smoke test 失敗：backend 沒有輸出任何訊息")

    parsed = [json.loads(line) for line in lines]
    has_ready = any(item.get("kind") == "event" and item.get("event") == "backend_ready" for item in parsed)
    has_response = any(
        item.get("kind") == "response"
        and item.get("request_id") == "1"
        and item.get("ok") is True
        for item in parsed
    )

    if not has_ready or not has_response:
        raise SystemExit(
            "Desktop bundle smoke test 失敗：未收到完整 backend_ready/get_info 回應\n"
            + (proc.stdout or "")
        )

    print(f"Desktop bundle smoke test passed: {app_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
