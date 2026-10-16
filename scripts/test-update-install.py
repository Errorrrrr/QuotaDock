#!/usr/bin/env python3
"""macOS desktop smoke test; debug-only silent helper, isolated demo apps, no real account changes.
Run scripts/test.sh and scripts/build-app.sh first. Nothing is published.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

PROJECT = Path(__file__).resolve().parent.parent
CONFIG = Path.home() / "Library/Application Support/QuotaDock/config.json"


def config_hash():
    return hashlib.sha256(CONFIG.read_bytes()).digest() if CONFIG.exists() else None


def sign(path):
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], check=True, capture_output=True)


def version(app, value):
    plist = app / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info["CFBundleShortVersionString"] = value
    plist.write_bytes(plistlib.dumps(info))
    sign(app)


def stop_test_apps(root):
    # Only executables under this invocation's isolated directory are eligible.
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
    for row in rows:
        fields = row.strip().split(None, 1)
        if len(fields) == 2 and fields[1].startswith(str(root) + "/"):
            try:
                os.kill(int(fields[0]), signal.SIGTERM)
            except ProcessLookupError:
                pass


def run_case(rollback):
    before = config_hash()
    root = Path(tempfile.mkdtemp(prefix="quotadock-updater-test-")).resolve()
    parent = worker = None
    try:
        target = root / "QuotaDock.app"
        shutil.copytree(PROJECT / "dist/QuotaDock.app", target)
        shutil.copy2(PROJECT / ".build/debug/QuotaDock", target / "Contents/MacOS/QuotaDock")
        shutil.copy2(PROJECT / ".build/debug/QuotaDockUpdater", target / "Contents/Helpers/QuotaDockUpdater")
        sign(target / "Contents/Helpers/QuotaDockUpdater")
        version(target, "999.0.0")
        session = str(uuid.uuid4()).upper()
        staging = root / (".QuotaDock-update-" + session)
        staging.mkdir(mode=0o700)
        candidate = staging / "QuotaDock.app"
        shutil.copytree(target, candidate)
        if rollback:
            # Valid signed executable that exits without launching a GUI app.
            shutil.copy2(PROJECT / ".build/debug/QuotaDockUpdater", candidate / "Contents/MacOS/QuotaDock")
        version(candidate, "999.0.1")
        helper = staging / "QuotaDockUpdater"
        shutil.copy2(PROJECT / ".build/debug/QuotaDockUpdater", helper)
        parent = subprocess.Popen(["/bin/sleep", "30"])
        log = root / "helper.log"
        with log.open("wb") as stderr:
            worker = subprocess.Popen([str(helper), str(target), "999.0.1", session, str(parent.pid), "--demo"],
                                      env={**os.environ, "QUOTADOCK_UPDATER_TEST": "1"},
                                      stdout=subprocess.DEVNULL, stderr=stderr)
            deadline = time.monotonic() + 10
            while not (staging / "helper-ready").exists():
                if worker.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError("Helper startup failed: " + log.read_text())
                time.sleep(0.1)
            parent.terminate()
            parent.wait(timeout=5)
            worker.wait(timeout=40)
        expected = "999.0.0" if rollback else "999.0.1"
        actual = plistlib.loads((target / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
        assert actual == expected, f"Expected {expected}, found {actual}: {log.read_text()}"
        assert bool(log.read_text()) == rollback, log.read_text()
        assert not staging.exists(), "Installer left staging after completion"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(target)], check=True)
        assert config_hash() == before, "Real configuration changed"
        print("PASS:", "failed launch restores old app" if rollback else "atomic install and native relaunch confirmation", "; configuration unchanged")
    finally:
        for process in (parent, worker):
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        stop_test_apps(root)
        shutil.rmtree(root)


if __name__ == "__main__":
    run_case(False)
    run_case(True)
