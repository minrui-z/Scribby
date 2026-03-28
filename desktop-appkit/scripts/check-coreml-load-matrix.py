#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import textwrap
from pathlib import Path


def run_load(package_path: Path, compute_unit: str, timeout_seconds: int) -> dict:
    code = textwrap.dedent(
        f"""
        import json
        import time
        import coremltools as ct

        start = time.time()
        ct.models.MLModel(
            {str(package_path)!r},
            compute_units=ct.ComputeUnit.{compute_unit},
        )
        print(json.dumps({{"unit": {compute_unit!r}, "elapsed": time.time() - start}}))
        """
    )

    try:
        proc = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "unit": compute_unit,
            "status": "timeout",
            "timeout_seconds": timeout_seconds,
            "stdout": (exc.stdout or "")[-500:] if isinstance(exc.stdout, str) else "",
            "stderr": (exc.stderr or "")[-500:] if isinstance(exc.stderr, str) else "",
        }

    payload = {
        "unit": compute_unit,
        "status": "ok" if proc.returncode == 0 else "error",
        "returncode": proc.returncode,
        "stdout": proc.stdout[-500:],
        "stderr": proc.stderr[-500:],
    }
    if proc.returncode == 0:
        try:
            parsed = json.loads(proc.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError):
            parsed = {}
        if isinstance(parsed, dict):
            payload["elapsed"] = parsed.get("elapsed")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check Core ML package load health across compute units."
    )
    parser.add_argument("package", help="Path to the .mlpackage to test")
    parser.add_argument(
        "--timeout",
        type=int,
        default=30,
        help="Per-compute-unit load timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--json-out",
        type=str,
        default="",
        help="Optional path to write JSON results",
    )
    parser.add_argument(
        "--units",
        type=str,
        default="CPU_ONLY,CPU_AND_GPU,CPU_AND_NE,ALL",
        help="Comma-separated compute units to test",
    )
    args = parser.parse_args()

    package_path = Path(args.package).expanduser().resolve()
    if not package_path.exists():
        print(json.dumps({"error": f"package not found: {package_path}"}))
        return 1

    results = []
    units = [unit.strip() for unit in args.units.split(",") if unit.strip()]
    for unit in units:
        results.append(run_load(package_path, unit, args.timeout))

    payload = {
        "package": str(package_path),
        "timeout_seconds": args.timeout,
        "results": results,
    }

    if args.json_out:
        out_path = Path(args.json_out).expanduser().resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
