#!/usr/bin/env python3
import pathlib
import subprocess
import sys
import tempfile
import unittest

from check_portable_core import scan, scan_test_imports

CHECK_SCRIPT = pathlib.Path(__file__).resolve().with_name("check_portable_core.py")
DEFAULT_ROOTS = (
    "app/MacAmbientJev/Sources/MacAmbientJevCore",
    "app/MacAmbientJev/Sources/MacAmbientJevPipeline",
    "app/MacAmbientJev/Sources/MacAmbientJevDiarization",
    "app/MacAmbientJev/Sources/MacAmbientJevDiarizationMeasurement",
    "app/MacAmbientJev/Sources/MacAmbientJevONNX",
    "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime",
)


class PortableImportTests(unittest.TestCase):
    def violations(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Core.swift").write_text(source, encoding="utf-8")
            return [module for _, module in scan(root)]

    def test_xctest_is_rejected_in_test_sources_and_swift_testing_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            test_file = root / "Community1ReconstructionTests.swift"
            test_file.write_text("import XCTest", encoding="utf-8")
            self.assertEqual(scan(root), [])
            self.assertEqual(scan_test_imports(root), [(test_file, "XCTest")])

            test_file.write_text("import Testing", encoding="utf-8")
            self.assertEqual(scan_test_imports(root), [])

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
        self.write_fixture(directory, "app/MacAmbientJev/Tests", "import Testing")
        return subprocess.run(
            [sys.executable, "-B", str(CHECK_SCRIPT)],
            cwd=directory,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_collects_violations_from_all_default_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write_fixture(directory, DEFAULT_ROOTS[0], "import Foundation")
            self.write_fixture(directory, DEFAULT_ROOTS[1], "import AVFoundation")
            self.write_fixture(directory, DEFAULT_ROOTS[2], "import CoreML")
            self.write_fixture(directory, DEFAULT_ROOTS[3], "import FluidAudio")
            self.write_fixture(directory, DEFAULT_ROOTS[4], "import Foundation")
            self.write_fixture(directory, DEFAULT_ROOTS[5], "import Foundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("AVFoundation", result.stderr)
            self.assertIn("CoreML", result.stderr)
            self.assertIn("FluidAudio", result.stderr)

    def test_cli_requires_all_default_roots(self):
        for missing_root in DEFAULT_ROOTS:
            with self.subTest(missing_root=missing_root):
                with tempfile.TemporaryDirectory() as directory:
                    for root in DEFAULT_ROOTS:
                        if root != missing_root:
                            self.write_fixture(directory, root, "import Foundation")

                    result = self.run_default_cli(directory)

                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(pathlib.Path(missing_root).name, result.stderr)
                    self.assertIn("not found", result.stderr)

    def test_cli_passes_when_all_default_roots_are_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            for root in DEFAULT_ROOTS:
                self.write_fixture(directory, root, "import Foundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(
                result.stdout.startswith("Portable Core / Pipeline / Diarization / ONNX / PortableRuntime import check passed"),
                result.stdout,
            )


if __name__ == "__main__":
    unittest.main()
