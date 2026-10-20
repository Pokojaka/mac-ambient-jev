#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import unittest

from check_portable_core import scan

CHECK_SCRIPT = pathlib.Path(__file__).resolve().with_name("check_portable_core.py")
DEFAULT_ROOTS = (
    "app/MacAmbientJev/Sources/MacAmbientJevCore",
    "app/MacAmbientJev/Sources/MacAmbientJevPipeline",
)


class PortableImportTests(unittest.TestCase):
    def violations(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Core.swift").write_text(source, encoding="utf-8")
            return [module for _, module in scan(root)]

    def test_forbidden_modules_are_rejected_even_when_guarded(self):
        for module in [
            "AudioToolbox",
            "CryptoKit",
            "IOKit",
            "CoreMedia",
            "AVFoundation",
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
        ]:
            with self.subTest(module=module):
                self.assertEqual(self.violations(f"#if os(macOS)\nimport {module}\n#endif"), [module])

    def test_os_import_requires_its_own_positive_guard(self):
        for module in ["Darwin", "Glibc", "WinSDK"]:
            with self.subTest(module=module):
                self.assertEqual(self.violations(f"import {module}"), [module])
                self.assertEqual(self.violations(f"#if DEBUG\nimport {module}\n#endif"), [module])
                self.assertEqual(self.violations(f"#if !canImport({module})\nimport {module}\n#endif"), [module])

    def test_else_does_not_inherit_positive_guard(self):
        self.assertEqual(self.violations("#if canImport(Darwin)\nimport Darwin\n#else\nimport Glibc\n#endif"), ["Glibc"])

    def test_mutually_exclusive_os_imports_are_allowed(self):
        self.assertEqual(self.violations("#if canImport(Darwin)\nimport Darwin\n#elseif canImport(Glibc)\nimport Glibc\n#elseif os(Windows)\nimport WinSDK\n#endif"), [])

    def test_nested_guards_preserve_the_outer_platform(self):
        self.assertEqual(self.violations("#if os(Windows)\n#if DEBUG\nimport WinSDK\n#endif\n#endif\nimport Foundation"), [])

    def test_scoped_and_attributed_imports_are_checked(self):
        self.assertEqual(self.violations("@preconcurrency import CoreML\nimport struct Darwin.stat"), ["CoreML", "Darwin"])

    def write_fixture(self, directory, root, source):
        fixture_root = pathlib.Path(directory) / root
        fixture_root.mkdir(parents=True)
        (fixture_root / "Fixture.swift").write_text(source, encoding="utf-8")

    def run_default_cli(self, directory):
        return subprocess.run(
            [sys.executable, "-B", str(CHECK_SCRIPT)],
            cwd=directory,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_collects_violations_from_both_default_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write_fixture(directory, DEFAULT_ROOTS[0], "import Foundation")
            self.write_fixture(directory, DEFAULT_ROOTS[1], "import AVFoundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("AVFoundation", result.stderr)

    def test_cli_requires_both_default_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write_fixture(directory, DEFAULT_ROOTS[0], "import Foundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("MacAmbientJevPipeline", result.stderr)
            self.assertIn("not found", result.stderr)

    def test_cli_passes_when_both_default_roots_are_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            for root in DEFAULT_ROOTS:
                self.write_fixture(directory, root, "import Foundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Portable Core / Pipeline import check passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
