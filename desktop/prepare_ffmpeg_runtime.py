from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
from collections import deque
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
RUNTIME_ROOT = PROJECT_ROOT / "desktop" / "runtime"
BIN_DIR = RUNTIME_ROOT / "bin"
LIB_DIR = RUNTIME_ROOT / "lib"

FFMPEG_BIN = Path("/opt/homebrew/bin/ffmpeg")
FFPROBE_BIN = Path("/opt/homebrew/bin/ffprobe")
HOMEBREW_PREFIXES = ("/opt/homebrew/", "/usr/local/")


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def ensure_exists(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"{label} 不存在: {path}")


def dependency_paths(binary: Path) -> list[str]:
    output = run("otool", "-L", str(binary))
    lines = output.splitlines()[1:]
    deps: list[str] = []
    for line in lines:
        path = line.strip().split(" ", 1)[0]
        if path.startswith(HOMEBREW_PREFIXES):
            deps.append(path)
    return deps


def install_name_target(original: str, current_file: Path) -> str:
    basename = Path(original).name
    if current_file.parent == BIN_DIR:
        return f"@executable_path/../lib/{basename}"
    return f"@loader_path/{basename}"


def normalize_permissions() -> None:
    for path in BIN_DIR.iterdir():
        if path.is_file():
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)

    for path in LIB_DIR.iterdir():
        if path.is_file():
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clean", action="store_true", help="重新建立 ffmpeg runtime")
    args = parser.parse_args()

    ensure_exists(FFMPEG_BIN, "ffmpeg")
    ensure_exists(FFPROBE_BIN, "ffprobe")

    if args.clean:
        shutil.rmtree(BIN_DIR, ignore_errors=True)
        shutil.rmtree(LIB_DIR, ignore_errors=True)

    BIN_DIR.mkdir(parents=True, exist_ok=True)
    LIB_DIR.mkdir(parents=True, exist_ok=True)

    ffmpeg_real = FFMPEG_BIN.resolve()
    ffprobe_real = FFPROBE_BIN.resolve()
    shutil.copy2(ffmpeg_real, BIN_DIR / "ffmpeg")
    shutil.copy2(ffprobe_real, BIN_DIR / "ffprobe")

    copied: set[Path] = set()
    queue: deque[Path] = deque([ffmpeg_real, ffprobe_real])

    while queue:
        current = queue.popleft()
        for dep in dependency_paths(current):
            dep_path = Path(dep).resolve()
            target = LIB_DIR / dep_path.name
            if dep_path not in copied:
                shutil.copy2(dep_path, target)
                copied.add(dep_path)
                queue.append(dep_path)

    for lib in LIB_DIR.iterdir():
        if lib.is_file():
            subprocess.check_call(
                ["install_name_tool", "-id", f"@loader_path/{lib.name}", str(lib)]
            )

    for binary in [BIN_DIR / "ffmpeg", BIN_DIR / "ffprobe", *sorted(LIB_DIR.iterdir())]:
        if not binary.is_file():
            continue
        originals = dependency_paths(binary)
        for original in originals:
            subprocess.check_call(
                [
                    "install_name_tool",
                    "-change",
                    original,
                    install_name_target(original, binary),
                    str(binary),
                ]
            )

    normalize_permissions()
    print(f"Prepared bundled ffmpeg runtime at: {RUNTIME_ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
