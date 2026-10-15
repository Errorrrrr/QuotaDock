#!/usr/bin/env python3
"""Called by the release workflow only after release assets are published."""
import json
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Invalid VERSION")
if os.environ.get("RELEASE_TAG") != f"v{version}":
    raise SystemExit("RELEASE_TAG does not match VERSION")
notes = (root / "docs" / "releases" / f"v{version}.md").read_text().strip().split("\n\n")[0]
base = "https://github.com/Errorrrrr/QuotaDock/releases"
manifest = {
    "version": version,
    "notes": notes,
    "releaseURL": f"{base}/tag/v{version}",
    "downloadURL": f"{base}/download/v{version}/QuotaDock-{version}-macOS-arm64.zip",
    "architecture": "arm64",
    "minimumSystemVersion": "14.0.0",
}
(root / "update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
