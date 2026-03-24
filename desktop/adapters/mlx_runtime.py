from __future__ import annotations

import gc
import os
import subprocess
from typing import Any


GIB = 1024**3
MIB = 1024**2


def _clamp(value: int, lower: int, upper: int) -> int:
    return max(lower, min(value, upper))


def _total_memory_bytes() -> int:
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        total = int(pages) * int(page_size)
        if total > 0:
            return total
    except (AttributeError, OSError, ValueError):
        pass

    proc = subprocess.run(
        ["sysctl", "-n", "hw.memsize"],
        capture_output=True,
        text=True,
        check=False,
    )
    output = (proc.stdout or "").strip()
    if not output:
        raise RuntimeError("無法取得系統記憶體容量")
    return int(output)


def build_memory_policy(total_memory_bytes: int | None = None) -> dict[str, int | str]:
    total = total_memory_bytes or _total_memory_bytes()
    if total <= 16 * GIB:
        memory_limit = int(total * 0.60)
    else:
        memory_limit = int(total * 0.55)

    memory_limit = _clamp(memory_limit, int(4.5 * GIB), 12 * GIB)
    cache_limit = _clamp(int(memory_limit * 0.16), 512 * MIB, int(1.5 * GIB))
    wired_limit = _clamp(min(memory_limit - 768 * MIB, int(total * 0.48)), int(3.5 * GIB), memory_limit - 256 * MIB)

    return {
        "platform": "macOS Apple Silicon",
        "total_memory_bytes": total,
        "memory_limit_bytes": memory_limit,
        "cache_limit_bytes": cache_limit,
        "wired_limit_bytes": wired_limit,
    }


def configure_memory_policy() -> dict[str, Any]:
    import mlx.core as mx

    policy = build_memory_policy()
    previous_memory = mx.set_memory_limit(int(policy["memory_limit_bytes"]))
    previous_cache = mx.set_cache_limit(int(policy["cache_limit_bytes"]))

    wired_applied = False
    wired_error = None
    try:
        mx.set_wired_limit(int(policy["wired_limit_bytes"]))
        wired_applied = True
    except Exception as exc:  # pragma: no cover - depends on macOS version
        wired_error = str(exc)

    policy["previous_memory_limit_bytes"] = int(previous_memory)
    policy["previous_cache_limit_bytes"] = int(previous_cache)
    policy["wired_limit_applied"] = wired_applied
    if wired_error:
        policy["wired_limit_error"] = wired_error
    return policy


def collect_memory_stats() -> dict[str, int]:
    import mlx.core as mx

    return {
        "active_memory_bytes": int(mx.get_active_memory()),
        "cache_memory_bytes": int(mx.get_cache_memory()),
        "peak_memory_bytes": int(mx.get_peak_memory()),
    }


def reclaim_memory(reset_peak: bool = False) -> dict[str, int]:
    import mlx.core as mx

    gc.collect()
    mx.clear_cache()
    if reset_peak:
        mx.reset_peak_memory()
    return collect_memory_stats()


def is_memory_pressure_error(exc: BaseException) -> bool:
    if isinstance(exc, MemoryError):
        return True

    text = str(exc).lower()
    patterns = (
        "out of memory",
        "memory limit",
        "allocation",
        "resource exhausted",
        "not enough memory",
        "metal",
        "mps",
    )
    return any(pattern in text for pattern in patterns)
