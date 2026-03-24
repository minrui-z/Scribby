import sys
from pathlib import Path


def project_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
    return Path(__file__).resolve().parent


def resource_path(*parts: str) -> Path:
    return project_root().joinpath(*parts)


def templates_dir() -> Path:
    return resource_path("templates")


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def worker_command() -> list[str]:
    if is_frozen():
        return [sys.executable, "--worker"]
    return [sys.executable, str(resource_path("transcribe_worker.py"))]
