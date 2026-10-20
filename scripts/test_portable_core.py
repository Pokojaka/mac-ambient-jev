#!/usr/bin/env python3
import pathlib
import tempfile
import unittest

from check_portable_core import scan


class PortableImportTests(unittest.TestCase):
    def violations(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Core.swift").write_text(source, encoding="utf-8")
            return [module for _, module in scan(root)]

    def test_apple_frameworks_are_rejected_even_when_guarded(self):
        for module in ["AudioToolbox", "CryptoKit", "IOKit", "CoreMedia", "AVFoundation"]:
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


if __name__ == "__main__":
    unittest.main()
