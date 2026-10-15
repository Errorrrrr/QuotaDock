#!/usr/bin/env python3
"""No credentials or installed CLI required."""
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


class BridgeTests(unittest.TestCase):
    def test_filtered_atomic_snapshot_and_invalid_input(self):
        script = Path(__file__).with_name("antigravity-statusline.py")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "quota.json"
            source = {
                "product": "antigravity",
                "quota": {"weekly": {"remaining_fraction": 0.75, "reset_time": "2099-01-01T00:00:00Z"}},
                "email": "test@example.com", "plan_tier": "Pro",
                "access_token": "secret-must-not-persist", "cwd": "/private/project",
            }
            def run(payload):
                return subprocess.run([sys.executable, str(script), "--output", str(output)],
                                      input=json.dumps(payload), text=True, capture_output=True, check=True)
            result = run(source)
            saved = json.loads(output.read_text())
            self.assertEqual(set(saved), {"product", "quota", "email", "plan_tier"})
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertNotIn("secret-must-not-persist", output.read_text() + result.stdout + result.stderr)
            self.assertIn("75%", result.stdout)
            source["quota"]["weekly"]["remaining_fraction"] = True
            run(source)
            self.assertEqual(json.loads(output.read_text()), saved)
            # Missing current quota clears the observation instead of pretending it refreshed.
            run({"product": "antigravity"})
            self.assertEqual(json.loads(output.read_text())["quota"], {})


if __name__ == "__main__":
    unittest.main()
