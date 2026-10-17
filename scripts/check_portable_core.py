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
    "AudioToolbox",
    "CryptoKit",
    "IOKit",
    "CoreMedia",
}

IMPORT_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|package)\s+)?import\s+"
    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)\b"
)
PLATFORM_GUARDS = {
    "Darwin": {"canImport(Darwin)", "os(macOS)", "os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)"},
    "Glibc": {"canImport(Glibc)", "os(Linux)"},
    "WinSDK": {"canImport(WinSDK)", "os(Windows)"},
}


def scan(root: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    violations: list[tuple[pathlib.Path, str]] = []
    for path in sorted(root.rglob("*.swift")):
        guards: list[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("//", 1)[0].strip()
            if line.startswith("#if "):
                guards.append(line[4:].strip())
            elif line.startswith("#elseif "):
                if guards:
                    guards[-1] = line[8:].strip()
            elif line == "#else":
                if guards:
                    guards[-1] = ""
            elif line == "#endif":
                if guards:
                    guards.pop()
            match = IMPORT_RE.match(line)
            if match:
                module = match.group(1)
                if module in FORBIDDEN_IMPORTS or (
                    module in PLATFORM_GUARDS
                    and not any(guard in PLATFORM_GUARDS[module] for guard in guards)
                ):
                    violations.append((path, module))
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
            print(f"{path}: forbidden or unguarded platform import: {module}", file=sys.stderr)
        return 1

    print(f"Portable Core import check passed ({root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
