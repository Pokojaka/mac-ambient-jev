#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
import sys

FORBIDDEN_IMPORTS = {
    "AVFoundation",
    "AppKit",
    "CoreAudio",
    "CoreML",
    "Security",
    "SwiftUI",
}

IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\s*$")


def scan(root: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    violations: list[tuple[pathlib.Path, str]] = []
    for path in sorted(root.rglob("*.swift")):
        for line in path.read_text(encoding="utf-8").splitlines():
            match = IMPORT_RE.match(line)
            if match and match.group(1) in FORBIDDEN_IMPORTS:
                violations.append((path, match.group(1)))
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "core",
        nargs="?",
        default="app/MacAmbientJev/Sources/MacAmbientJevCore",
    )
    args = parser.parse_args()
    root = pathlib.Path(args.core)
    if not root.is_dir():
        print(f"portable core directory not found: {root}", file=sys.stderr)
        return 2

    violations = scan(root)
    if violations:
        for path, module in violations:
            print(f"{path}: forbidden Apple framework import: {module}", file=sys.stderr)
        return 1

    print(f"Portable Core import check passed ({root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
