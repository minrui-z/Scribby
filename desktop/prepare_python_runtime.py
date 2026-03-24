from __future__ import annotations

import argparse
import shutil
from importlib.metadata import Distribution, distributions
from pathlib import Path, PurePosixPath

from packaging.markers import default_environment
from packaging.requirements import Requirement


PROJECT_ROOT = Path(__file__).resolve().parent.parent
RUNTIME_ROOT = PROJECT_ROOT / "desktop" / "runtime"
STAGED_PYTHON = RUNTIME_ROOT / "python"
FRAMEWORK_ROOT = Path("/Library/Frameworks/Python.framework/Versions/3.10")
VENV_SITE_PACKAGES = PROJECT_ROOT / "venv" / "lib" / "python3.10" / "site-packages"

FRAMEWORK_IGNORE = shutil.ignore_patterns(
    "__pycache__",
    "test",
    "tests",
    "site-packages",
    "tkinter",
    "turtledemo",
    "idlelib",
    "ensurepip",
    "venv",
    "*.pyc",
    "*.pyo",
)

FRAMEWORK_BINARIES = ("python3", "python3.10")

# Desktop app is macOS Apple Silicon only. Resolve the runtime from a narrow
# dependency closure and manually add the tiny subset of WhisperX files used by
# engine.diarize so the bundle does not carry the Faster-Whisper stack.
SEED_DISTRIBUTIONS = (
    "mlx-whisper",
    "mlx",
    "pyannote-audio",
    "pyannote-core",
    "pyannote-database",
    "pyannote-metrics",
    "pyannote-pipeline",
    "huggingface-hub",
    "requests",
    "packaging",
    "typing-extensions",
)

SAFE_PRUNE_DIRECTORIES = (
    "torch/include",
    "torch/share",
    "mlx/include",
    "mlx/share",
)

MANUAL_PACKAGE_FILES: dict[str, tuple[str, ...]] = {
    "whisperx": (
        "__init__.py",
        "audio.py",
        "diarize.py",
        "log_utils.py",
        "schema.py",
        "utils.py",
    ),
}

EXCLUDED_DISTRIBUTIONS = {
    "whisperx",
    "torchcodec",
}

SKIP_DISTRIBUTION_FILE_SUFFIXES = (".pyc", ".pyo")
SKIP_DISTRIBUTION_FILE_NAMES = {"RECORD"}


def normalize_name(name: str) -> str:
    return "".join("-" if char in "._" else char.lower() for char in name).strip("-")


def ensure_exists(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"{label} 不存在: {path}")


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def remove_path(path: Path) -> None:
    if not path.exists():
        return
    if path.is_dir():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)


def distribution_index() -> dict[str, Distribution]:
    index: dict[str, Distribution] = {}
    for dist in distributions(path=[str(VENV_SITE_PACKAGES)]):
        name = dist.metadata.get("Name")
        if not name:
            continue
        index[normalize_name(name)] = dist
    return index


def requirement_names(dist: Distribution) -> list[str]:
    env = default_environment()
    env["extra"] = ""
    names: list[str] = []
    for raw in dist.metadata.get_all("Requires-Dist") or []:
        req = Requirement(raw)
        if req.marker and not req.marker.evaluate(env):
            continue
        names.append(normalize_name(req.name))
    return names


def resolve_distribution_closure(index: dict[str, Distribution]) -> dict[str, Distribution]:
    selected: dict[str, Distribution] = {}
    pending = [normalize_name(name) for name in SEED_DISTRIBUTIONS]

    while pending:
        name = pending.pop()
        if name in selected:
            continue
        dist = index.get(name)
        if dist is None:
            continue
        selected[name] = dist
        pending.extend(requirement_names(dist))

    for name in EXCLUDED_DISTRIBUTIONS:
        selected.pop(normalize_name(name), None)

    return selected


def should_skip_distribution_file(relative_path: PurePosixPath) -> bool:
    if relative_path.name in SKIP_DISTRIBUTION_FILE_NAMES:
        return True
    if relative_path.suffix in SKIP_DISTRIBUTION_FILE_SUFFIXES:
        return True
    if "__pycache__" in relative_path.parts:
        return True
    return False


def copy_distribution_files(target_site_packages: Path, selected: dict[str, Distribution]) -> None:
    copied: set[PurePosixPath] = set()
    for dist in selected.values():
        for relative in dist.files or []:
            rel_path = PurePosixPath(relative)
            if should_skip_distribution_file(rel_path):
                continue
            if rel_path in copied:
                continue
            copied.add(rel_path)
            source = VENV_SITE_PACKAGES / Path(rel_path)
            if not source.exists() or source.is_dir():
                continue
            target = target_site_packages / Path(rel_path)
            copy_file(source, target)


def copy_framework_binaries(target_bin: Path) -> None:
    target_bin.mkdir(parents=True, exist_ok=True)
    for name in FRAMEWORK_BINARIES:
        copy_file(FRAMEWORK_ROOT / "bin" / name, target_bin / name)


def copy_manual_package_files(target_site_packages: Path) -> None:
    for package_name, entries in MANUAL_PACKAGE_FILES.items():
        source_root = VENV_SITE_PACKAGES / package_name
        if not source_root.exists():
            raise SystemExit(f"找不到手動保留的套件目錄：{source_root}")
        for entry in entries:
            source = source_root / entry
            if not source.exists():
                raise SystemExit(f"找不到手動保留的套件檔案：{source}")
            target = target_site_packages / package_name / entry
            copy_file(source, target)


def prune_runtime_site_packages(target_site_packages: Path) -> None:
    for relative in SAFE_PRUNE_DIRECTORIES:
        remove_path(target_site_packages / relative)

    for path in target_site_packages.rglob("__pycache__"):
        remove_path(path)
    for pattern in ("*.pyc", "*.pyo"):
        for path in target_site_packages.rglob(pattern):
            remove_path(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--clean", action="store_true", help="重新建立 runtime staging")
    args = parser.parse_args()

    ensure_exists(FRAMEWORK_ROOT, "Python framework")
    ensure_exists(VENV_SITE_PACKAGES, "venv site-packages")

    if args.clean and RUNTIME_ROOT.exists():
        shutil.rmtree(RUNTIME_ROOT)

    if STAGED_PYTHON.exists():
        shutil.rmtree(STAGED_PYTHON)

    STAGED_PYTHON.mkdir(parents=True, exist_ok=True)

    copy_file(FRAMEWORK_ROOT / "Python", STAGED_PYTHON / "Python")
    copy_file(FRAMEWORK_ROOT / "Resources" / "Info.plist", STAGED_PYTHON / "Resources" / "Info.plist")
    copy_framework_binaries(STAGED_PYTHON / "bin")
    shutil.copytree(
        FRAMEWORK_ROOT / "lib" / "python3.10",
        STAGED_PYTHON / "lib" / "python3.10",
        symlinks=False,
        ignore=FRAMEWORK_IGNORE,
        dirs_exist_ok=True,
    )

    target_site_packages = STAGED_PYTHON / "lib" / "python3.10" / "site-packages"
    target_site_packages.mkdir(parents=True, exist_ok=True)

    index = distribution_index()
    selected = resolve_distribution_closure(index)
    copy_distribution_files(target_site_packages, selected)
    copy_manual_package_files(target_site_packages)
    prune_runtime_site_packages(target_site_packages)

    (STAGED_PYTHON / "README.txt").write_text(
        "Bundled Python runtime for 逐字搞定 desktop app.\n"
        "Target: macOS Apple Silicon only.\n",
        encoding="utf-8",
    )
    print(f"Prepared bundled Python runtime at: {STAGED_PYTHON}")
    print(f"Selected distributions: {len(selected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
