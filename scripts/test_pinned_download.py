from __future__ import annotations

import contextlib
import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import pinned_download


class EnsureRepositoryDirectoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.root = self.root.resolve()

    def make_symlink(self, link: Path, target: Path) -> None:
        link.symlink_to(target, target_is_directory=True)

    def test_creates_nested_directories_and_reuses_root(self) -> None:
        directory = self.root / "cache" / "models"

        result = pinned_download.ensure_repository_directory(self.root, directory)
        repeated = pinned_download.ensure_repository_directory(self.root, directory)

        self.assertEqual(result, directory)
        self.assertTrue(result.is_dir())
        self.assertEqual(repeated, directory)
        self.assertEqual(pinned_download.ensure_repository_directory(self.root, self.root), self.root)

    def test_rejects_relative_outside_and_parent_reference_paths(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "絶対パス"):
            pinned_download.ensure_repository_directory(Path("relative-root"), Path("relative-directory"))
        with self.assertRaisesRegex(RuntimeError, "絶対パス"):
            pinned_download.ensure_repository_directory(self.root, Path("relative-directory"))
        with self.assertRaisesRegex(RuntimeError, "リポジトリ外"):
            pinned_download.ensure_repository_directory(self.root, self.root.parent / "outside")
        with self.assertRaisesRegex(RuntimeError, "親参照"):
            pinned_download.ensure_repository_directory(self.root, self.root / "cache" / ".." / "outside")

    def test_rejects_missing_file_and_symlink_roots(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "ありません"):
            pinned_download.ensure_repository_directory(self.root / "missing", self.root / "missing" / "child")

        file_root = self.root / "root-file"
        file_root.write_text("not a directory")
        with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
            pinned_download.ensure_repository_directory(file_root, file_root / "child")

        link_root = self.root.parent / "root-link"
        self.make_symlink(link_root, self.root)
        with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
            pinned_download.ensure_repository_directory(link_root, link_root / "child")

    def test_rejects_regular_file_component(self) -> None:
        file_component = self.root / "file"
        file_component.write_text("not a directory")

        with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
            pinned_download.ensure_repository_directory(self.root, file_component / "child")

    def test_rejects_in_root_and_dangling_directory_symlinks(self) -> None:
        real_directory = self.root / "real-directory"
        real_directory.mkdir()
        in_root_link = self.root / "in-root-link"
        self.make_symlink(in_root_link, real_directory)
        with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
            pinned_download.ensure_repository_directory(self.root, in_root_link / "child")

        dangling_link = self.root / "dangling-link"
        self.make_symlink(dangling_link, self.root / "missing-target")
        with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
            pinned_download.ensure_repository_directory(self.root, dangling_link / "child")


class DownloadVerifiedPathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.root = self.root.resolve()
        self.destination = self.root / "cache" / "model.bin"
        self.destination.parent.mkdir()

    def make_symlink(self, link: Path, target: Path, target_is_directory: bool) -> None:
        link.symlink_to(target, target_is_directory=target_is_directory)

    def test_rejects_relative_destination(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "絶対パス"):
            pinned_download.download_verified("https://example.invalid/model", "unused", Path("model.bin"))

    def test_rejects_directory_destination(self) -> None:
        self.destination.mkdir()
        with mock.patch.object(pinned_download.urllib.request, "urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "通常ファイル"):
                pinned_download.download_verified("https://example.invalid/model", "unused", self.destination)
        download.assert_not_called()

    def test_rejects_in_root_and_dangling_file_symlinks(self) -> None:
        target = self.root / "target.bin"
        target.write_bytes(b"keep")
        self.make_symlink(self.destination, target, False)
        with mock.patch.object(pinned_download.urllib.request, "urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "通常ファイル"):
                pinned_download.download_verified("https://example.invalid/model", "unused", self.destination)
        download.assert_not_called()
        self.assertEqual(target.read_bytes(), b"keep")

        self.destination.unlink()
        self.make_symlink(self.destination, self.root / "missing-target.bin", False)
        with mock.patch.object(pinned_download.urllib.request, "urlopen") as download:
            with self.assertRaisesRegex(RuntimeError, "通常ファイル"):
                pinned_download.download_verified("https://example.invalid/model", "unused", self.destination)
        download.assert_not_called()

    def test_publication_failure_cleans_temporary_file_and_preserves_exception(self) -> None:
        payload = b"verified fixture"
        expected = hashlib.sha256(payload).hexdigest()
        failure = OSError("injected publication failure")
        with mock.patch.object(
            pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(payload)),
        ), mock.patch.object(pinned_download.os, "replace", side_effect=failure):
            with self.assertRaises(OSError) as raised:
                pinned_download.download_verified("https://example.invalid/model", expected, self.destination)

        self.assertIs(raised.exception, failure)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.glob(f".{self.destination.name}.*.download")), [])

    def test_replace_receives_verified_file_in_destination_directory(self) -> None:
        payload = b"verified publication fixture"
        expected = hashlib.sha256(payload).hexdigest()
        real_replace = pinned_download.os.replace
        replace_calls: list[tuple[Path, Path]] = []

        def verify_and_replace(source: str | Path, target: str | Path) -> None:
            source_path, target_path = Path(source), Path(target)
            replace_calls.append((source_path, target_path))
            self.assertEqual(source_path.parent, self.destination.parent)
            self.assertEqual(target_path, self.destination)
            self.assertEqual(source_path.read_bytes(), payload)
            self.assertEqual(hashlib.sha256(source_path.read_bytes()).hexdigest(), expected)
            real_replace(source, target)

        with mock.patch.object(
            pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(payload)),
        ), mock.patch.object(pinned_download.os, "replace", side_effect=verify_and_replace):
            result = pinned_download.download_verified("https://example.invalid/model", expected, self.destination)

        self.assertEqual(result, self.destination)
        self.assertEqual(len(replace_calls), 1)
        self.assertEqual(self.destination.read_bytes(), payload)
        self.assertEqual(list(self.destination.parent.glob(f".{self.destination.name}.*.download")), [])


if __name__ == "__main__":
    unittest.main()
