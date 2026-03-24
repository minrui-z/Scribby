from __future__ import annotations

import io
import zipfile
from pathlib import Path


def transcript_filename(display_name: str | None) -> str:
    base = Path(display_name or "transcript").stem.strip() or "transcript"
    return f"{base}_transcript.txt"


def bundle_filename() -> str:
    return "transcripts.zip"


def write_transcript(destination: str | Path, text: str) -> str:
    target = Path(destination).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")
    return str(target)


def build_zip(entries: list[tuple[str, str]]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, text in entries:
            archive.writestr(name, text)
    return buffer.getvalue()


def write_zip(destination: str | Path, entries: list[tuple[str, str]]) -> str:
    target = Path(destination).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(build_zip(entries))
    return str(target)
