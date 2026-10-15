#!/usr/bin/env python3
"""Claude Code statusLine bridge. Stores only quota fields, never the full input."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, help="One unique snapshot path per Claude account")
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(1_048_577)
        if len(raw) > 1_048_576:
            raise ValueError("input too large")
        source = json.loads(raw).get("rate_limits")
        if not isinstance(source, dict):
            print("Claude · 额度待更新")
            return
        limits = {}
        labels = []
        for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
            window = source.get(key)
            if window is None:
                continue
            used = window.get("used_percentage")
            if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
                raise ValueError("invalid quota")
            sanitized = {"used_percentage": used}
            reset = window.get("resets_at")
            if reset is not None:
                if isinstance(reset, bool) or not isinstance(reset, (int, float)) or not math.isfinite(reset) or not 0 < reset < 253_402_300_800:
                    raise ValueError("invalid reset")
                sanitized["resets_at"] = reset
            limits[key] = sanitized
            labels.append(f"{label} 剩余 {100 - used:g}%")
        if not limits:
            print("Claude · 额度待更新")
            return
        output = Path(args.output).expanduser().absolute()
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=output.parent, prefix=".quota-", delete=False) as handle:
                temporary = Path(handle.name)
                os.chmod(temporary, 0o600)
                json.dump({"rate_limits": limits}, handle, ensure_ascii=False, allow_nan=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, output)
        finally:
            if temporary and temporary.exists():
                temporary.unlink()
        print("Claude · " + " / ".join(labels))
    except (OSError, ValueError, TypeError, AttributeError):
        # Status lines must never leak input, paths, tokens or interrupt a session.
        print("Claude · 额度快照未更新")


if __name__ == "__main__":
    main()
