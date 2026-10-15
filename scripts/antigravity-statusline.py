#!/usr/bin/env python3
"""Capture only documented Antigravity quota/profile fields, never full session input."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile


def clean_text(value, limit=120):
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value if value and len(value) <= limit and not any(ord(c) < 32 or ord(c) == 127 for c in value) else None


def sanitize(source):
    if not isinstance(source, dict) or source.get("product") != "antigravity":
        raise ValueError("wrong product")
    quotas = source.get("quota")
    if not isinstance(quotas, dict):
        quotas = {}
    result = {"product": "antigravity", "quota": {}}
    for key, window in quotas.items():
        if not clean_text(key) or not isinstance(window, dict):
            raise ValueError("invalid quota")
        remaining = window.get("remaining_fraction")
        if isinstance(remaining, bool) or not isinstance(remaining, (int, float)) or not math.isfinite(remaining) or not 0 <= remaining <= 1:
            raise ValueError("invalid quota")
        entry = {"remaining_fraction": remaining}
        if window.get("reset_time") is not None:
            reset = clean_text(window["reset_time"])
            if not reset:
                raise ValueError("invalid reset")
            entry["reset_time"] = reset
        result["quota"][key] = entry
    for key, limit in (("email", 254), ("plan_tier", 120)):
        value = clean_text(source.get(key), limit)
        if value:
            result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, help="Unique output file for this account")
    args = parser.parse_args()
    temporary = None
    try:
        raw = sys.stdin.buffer.read(1_048_577)
        if len(raw) > 1_048_576:
            raise ValueError("input too large")
        result = sanitize(json.loads(raw))
        output = Path(args.output).expanduser().absolute()
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, prefix=".quota-", delete=False) as handle:
            temporary = Path(handle.name)
            os.chmod(temporary, 0o600)
            json.dump(result, handle, ensure_ascii=False, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
        labels = [f"{key} 剩余 {window['remaining_fraction'] * 100:g}%" for key, window in result["quota"].items()]
        print("Antigravity · " + (" / ".join(labels) if labels else "额度待更新"))
    except (OSError, ValueError, TypeError, AttributeError):
        print("Antigravity · 额度快照未更新")
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    main()
