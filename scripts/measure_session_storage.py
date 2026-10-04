#!/usr/bin/env python3
"""Measure real session storage with synthetic audio and injected inference engines."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions-root", type=Path, required=True,
                        help="Explicit scratch directory outside real app data; each run gets a new child")
    parser.add_argument("--seconds", type=int, default=600,
                        help="Synthetic duration, in seconds (default: ten minutes)")
    options = parser.parse_args()
    if options.seconds <= 0:
        parser.error("--seconds must be positive")
    selected = options.sessions_root.expanduser().resolve()
    home = Path.home()
    protected = [
        home / "Library/Application Support/mac-ambient-jev",
        home / "Library/Caches/mac-ambient-jev",
        home / "Library/Containers/app.mac-ambient-jev/Data/Library/Application Support/mac-ambient-jev",
        home / "Library/Containers/app.mac-ambient-jev/Data/Library/Caches/mac-ambient-jev",
    ]
    selected_parts = tuple(part.casefold() for part in selected.parts)
    for path in protected:
        protected_parts = tuple(part.casefold() for part in path.resolve().parts)
        if (selected_parts[:len(protected_parts)] == protected_parts
                or protected_parts[:len(selected_parts)] == selected_parts):
            parser.error("--sessions-root must not overlap real app data or cache roots")
    selected.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="storage-", dir=selected))
    environment = os.environ.copy()
    environment["STORAGE_HARNESS_ROOT"] = str(run)
    environment["STORAGE_HARNESS_SECONDS"] = str(options.seconds)
    repository = Path(__file__).resolve().parent.parent
    subprocess.run([
        "swift", "test", "--package-path", "app/MacAmbientJev",
        "--filter", "storageDiskUsageHarness",
    ], cwd=repository, env=environment, check=True)
    report_path = run / "disk-usage.json"
    report = json.loads(report_path.read_text())
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    print(f"Report and retained fixtures: {report_path}")


if __name__ == "__main__":
    main()
