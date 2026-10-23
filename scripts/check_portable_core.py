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
    "Combine",
    "ScreenCaptureKit",
    "FluidAudio",
    "MLX",
    "MLXNN",
    "MLXFast",
    "MLXRandom",
    "Qwen3ASR",
    "MacAmbientJevRuntime",
    "MacAmbientJevAppleSupport",
    "MacAmbientJevCapture",
    "MacAmbientJevEngine",
}

IMPORT_RE = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|package)\s+)?import\s+"
    r"(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)\b"
)
PLATFORM_GUARDS = {
    "Darwin": {"canImport(Darwin)", "os(macOS)", "os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)"},
    "Glibc": {"canImport(Glibc)", "os(Linux)"},
    "WinSDK": {"canImport(WinSDK)", "os(Windows)"},
    "MacAmbientJevWindowsSupport": {"os(Windows)"},
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


def scan_test_imports(root: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    violations: list[tuple[pathlib.Path, str]] = []
    for path in sorted(root.rglob("*.swift")):
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.split("//", 1)[0].strip()
            match = IMPORT_RE.match(line)
            if match and match.group(1) == "XCTest":
                violations.append((path, "XCTest"))
    return violations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "roots",
        nargs="*",
        default=[
            "app/MacAmbientJev/Sources/MacAmbientJevCore",
            "app/MacAmbientJev/Sources/MacAmbientJevPipeline",
            "app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol",
            "app/MacAmbientJev/Sources/MacAmbientJevEngineHost",
            "app/MacAmbientJev/Sources/MacAmbientJevDiarization",
            "app/MacAmbientJev/Sources/MacAmbientJevDiarizationMeasurement",
            "app/MacAmbientJev/Sources/MacAmbientJevONNX",
            "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime",
        ],
    )
    args = parser.parse_args()
    roots = [pathlib.Path(root) for root in args.roots]
    tests_root = pathlib.Path("app/MacAmbientJev/Tests")
    missing_roots = [root for root in [*roots, tests_root] if not root.is_dir()]
    if missing_roots:
        for root in missing_roots:
            print(f"portable Core/Pipeline/EngineProtocol/EngineHost/Diarization/ONNX/PortableRuntime directory not found: {root}", file=sys.stderr)
        return 2

    violations = [violation for root in roots for violation in scan(root)]
    test_violations = scan_test_imports(tests_root)
    if violations or test_violations:
        for path, module in violations:
            print(f"{path}: forbidden or unguarded platform import: {module}", file=sys.stderr)
        for path, module in test_violations:
            print(
                f"{path}: import XCTest is forbidden; use swift-testing (import Testing) "
                "because XCTest's async setUp deadlocks on Linux",
                file=sys.stderr,
            )
        return 1

    print(f"Portable Core / Pipeline / EngineProtocol / EngineHost / Diarization / ONNX / PortableRuntime import check passed ({', '.join(args.roots)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
