from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from check_test_time_limits import HANG_GUARD_MINUTES, scan


CHECKER = Path(__file__).with_name("check_test_time_limits.py")


def make_test_root(repository_root: Path) -> Path:
    tests_root = repository_root / "app" / "MacAmbientJev" / "Tests"
    tests_root.mkdir(parents=True)
    return tests_root


def write_swift(repository_root: Path, source: str, name: str = "Fixture.swift") -> Path:
    path = make_test_root(repository_root) / name
    path.write_text(source, encoding="utf-8")
    return path


class TimeLimitScannerTests(unittest.TestCase):
    def test_accepts_existing_and_multiline_comment_separated_forms(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_swift(
                root,
                """@Test(.timeLimit(.minutes(10)))
@Suite(
  . /* member */ timeLimit /* open */ (
    . /* unit */ minutes /* open */ ( 10 )
  )
)
Trait.timeLimit(.minutes(10))
""",
            )
            self.assertEqual(scan(root), [])

    def test_rejects_wrong_units_values_expressions_and_nil_with_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write_swift(
                root,
                """@Test(.timeLimit(.minutes(1)))
@Test(.timeLimit(.minutes(2)))
@Test(.timeLimit(.seconds(600)))
@Test(.timeLimit(.minutes(5 + 5)))
@Test(.timeLimit(.minutes(nil)))
""",
            )
            diagnostics = scan(root)
            self.assertEqual(len(diagnostics), 5)
            for line, diagnostic in enumerate(diagnostics, start=1):
                self.assertTrue(diagnostic.startswith(f"{path}:{line}:"), diagnostic)
                self.assertIn(f"minutes({HANG_GUARD_MINUTES})", diagnostic)

    def test_qualified_backticked_and_nested_calls_are_checked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write_swift(
                root,
                """Trait.timeLimit(.minutes(10))
Trait.`timeLimit`(.minutes(2))
Trait.timeLimit(.minutes(other.timeLimit(.minutes(10))))
`timeLimit`(.minutes(10))
""",
            )
            diagnostics = scan(root)
            self.assertEqual(len(diagnostics), 3)
            self.assertTrue(all(diagnostic.startswith(f"{path}:") for diagnostic in diagnostics))
            self.assertIn(f"{path}:2:", diagnostics[0])
            self.assertIn(f"{path}:3:", diagnostics[1])
            self.assertIn(f"{path}:4:", diagnostics[2])

    def test_ignores_comment_and_string_lookalikes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write_swift(
                root,
                '''// .timeLimit(.minutes(1))
/* outer .timeLimit(.minutes(1)) /* nested .timeLimit(.minutes(2)) */ */
let ordinary = ".timeLimit(.minutes(1))"
let multiline = """
.timeLimit(.minutes(2))
"""
let raw = #".timeLimit(.minutes(1))"#
let rawMultiline = ##"""
.timeLimit(.minutes(2))
"""##
''',
            )
            self.assertEqual(scan(root), [])

    def test_scans_code_inside_string_interpolation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write_swift(root, 'let message = "\\(Trait.timeLimit(.minutes(1)))"\n')
            diagnostics = scan(root)
            self.assertEqual(len(diagnostics), 1)
            self.assertTrue(diagnostics[0].startswith(f"{path}:1:"), diagnostics[0])

    def test_reports_source_line_for_violation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write_swift(root, "struct Fixture {\n  @Test(.timeLimit(.minutes(2)))\n}\n")
            diagnostics = scan(root)
            self.assertEqual(len(diagnostics), 1)
            self.assertTrue(diagnostics[0].startswith(f"{path}:2:"), diagnostics[0])

    def test_reports_missing_root_and_empty_scan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = root / "missing"
            self.assertIn("repository root", scan(missing)[0])
            self.assertIn("no Swift files", scan(root)[0])

    def test_rejects_unterminated_comments_and_strings(self) -> None:
        cases = (
            ("/* outer /* nested */\n", "unterminated block comment", 1),
            ('let text = "unterminated\n', "unterminated string literal", 1),
            ('let text = """\nunterminated\n', "unterminated string literal", 1),
        )
        for source, message, line in cases:
            with self.subTest(message=message, source=source), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = write_swift(root, source)
                diagnostics = scan(root)
                self.assertEqual(len(diagnostics), 1)
                self.assertTrue(diagnostics[0].startswith(f"{path}:{line}:"), diagnostics[0])
                self.assertIn(message, diagnostics[0])

    def test_cli_exit_status_for_failure_success_and_missing_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = write_swift(root, "@Test(.timeLimit(.minutes(1)))\n")
            failed = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(failed.returncode, 1)
            self.assertIn(f"{path}:1:", failed.stderr)

            path.write_text("@Test(.timeLimit(.minutes(10)))\n", encoding="utf-8")
            passed = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)

            missing = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(root / "missing")],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(missing.returncode, 1)
            self.assertIn("repository root", missing.stderr)


if __name__ == "__main__":
    unittest.main()
