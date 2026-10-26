from __future__ import annotations

import os
from pathlib import Path
import tempfile
import unittest

import report_build_size


class ReportBuildSizeTests(unittest.TestCase):
    def test_counts_regular_files_and_skips_links(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "debug-real").mkdir()
            (root / "debug-real" / "a.o").write_bytes(b"x" * 10)
            (root / "b.json").write_bytes(b"y" * 5)
            os.symlink(root / "debug-real", root / "debug", target_is_directory=True)
            self.assertEqual(report_build_size.tree_size(str(root)), 15)

    def test_missing_directory_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(report_build_size.main([str(Path(directory) / "missing")]), 1)


if __name__ == "__main__":
    unittest.main()
