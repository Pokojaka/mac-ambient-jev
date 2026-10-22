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
    "app/MacAmbientJev/Sources/MacAmbientJevEngineProtocol",
    "app/MacAmbientJev/Sources/MacAmbientJevEngineHost",
    "app/MacAmbientJev/Sources/MacAmbientJevDiarization",
    "app/MacAmbientJev/Sources/MacAmbientJevDiarizationMeasurement",
    "app/MacAmbientJev/Sources/MacAmbientJevONNX",
    "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime",
)
WINDOWS_ONLY_ROOTS = (
    "app/MacAmbientJev/Sources/MacAmbientJevEngine",
    "app/MacAmbientJev/Sources/MacAmbientJevWindowsSupport",
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

    def test_engine_module_is_rejected_even_when_windows_guarded(self):
        source = "#if os(Windows)\nimport MacAmbientJevEngine\n#endif"
        self.assertEqual(self.violations(source), ["MacAmbientJevEngine"])

    def test_windows_support_requires_positive_windows_guard(self):
        rejected_sources = [
            "import MacAmbientJevWindowsSupport",
            "#if DEBUG\nimport MacAmbientJevWindowsSupport\n#endif",
            "#if os(Linux)\nimport MacAmbientJevWindowsSupport\n#endif",
            "#if !os(Windows)\nimport MacAmbientJevWindowsSupport\n#endif",
        ]
        for source in rejected_sources:
            with self.subTest(source=source):
                self.assertEqual(self.violations(source), ["MacAmbientJevWindowsSupport"])

        allowed_sources = [
            "#if os(Windows)\nimport MacAmbientJevWindowsSupport\n#endif",
            "#if os(Windows)\n#if DEBUG\nimport MacAmbientJevWindowsSupport\n#endif\n#endif",
        ]
        for source in allowed_sources:
            with self.subTest(source=source):
                self.assertEqual(self.violations(source), [])

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
            self.write_fixture(directory, DEFAULT_ROOTS[2], "import AppKit")
            self.write_fixture(directory, DEFAULT_ROOTS[3], "import WinSDK")
            self.write_fixture(directory, DEFAULT_ROOTS[4], "import CoreML")
            self.write_fixture(directory, DEFAULT_ROOTS[5], "import FluidAudio")
            self.write_fixture(directory, DEFAULT_ROOTS[6], "import Foundation")
            self.write_fixture(directory, DEFAULT_ROOTS[7], "import Foundation")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 1, result.stderr)
            for module in ["AVFoundation", "AppKit", "WinSDK", "CoreML", "FluidAudio"]:
                with self.subTest(module=module):
                    self.assertIn(module, result.stderr)
            self.assertIn(str(pathlib.PurePath(DEFAULT_ROOTS[2])), result.stderr)
            self.assertIn(str(pathlib.PurePath(DEFAULT_ROOTS[3])), result.stderr)

    def test_cli_rejects_platform_imports_in_each_engine_root(self):
        sources = [
            ("import AppKit", "AppKit"),
            ("#if os(macOS)\nimport AVFoundation\n#endif", "AVFoundation"),
            ("import WinSDK", "WinSDK"),
            (
                "#if os(Windows)\nimport MacAmbientJevEngine\n#endif",
                "MacAmbientJevEngine",
            ),
            ("import MacAmbientJevWindowsSupport", "MacAmbientJevWindowsSupport"),
        ]
        for engine_root in DEFAULT_ROOTS[2:4]:
            for source, module in sources:
                with self.subTest(engine_root=engine_root, module=module):
                    with tempfile.TemporaryDirectory() as directory:
                        for root in DEFAULT_ROOTS:
                            self.write_fixture(
                                directory,
                                root,
                                source if root == engine_root else "import Foundation",
                            )

                        result = self.run_default_cli(directory)

                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertIn(str(pathlib.PurePath(engine_root)), result.stderr)
                        self.assertIn(module, result.stderr)

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

    def test_cli_ignores_windows_only_source_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            for root in DEFAULT_ROOTS:
                self.write_fixture(directory, root, "import Foundation")
            for root in WINDOWS_ONLY_ROOTS:
                self.write_fixture(directory, root, "import WinSDK")

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_passes_when_all_default_roots_are_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            for root in DEFAULT_ROOTS:
                self.write_fixture(directory, root, "import Foundation")
            for root in WINDOWS_ONLY_ROOTS:
                self.assertFalse((pathlib.Path(directory) / root).exists())

            result = self.run_default_cli(directory)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(
                result.stdout.startswith("Portable Core / Pipeline / EngineProtocol / EngineHost / Diarization / ONNX / PortableRuntime import check passed"),
                result.stdout,
            )
            self.assertTrue(
                result.stdout.rstrip().endswith(f"({', '.join(DEFAULT_ROOTS)})"),
                result.stdout,
            )


if __name__ == "__main__":
    unittest.main()
