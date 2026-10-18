from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_onnxruntime.py")
SPEC = importlib.util.spec_from_file_location("fetch_onnxruntime", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


WINDOWS_FILES = (
    "include/onnxruntime_c_api.h",
    "lib/onnxruntime.lib",
    "lib/onnxruntime.dll",
    "LICENSE",
    "ThirdPartyNotices.txt",
)


def make_zip(root: str, files: tuple[str, ...], extra: tuple[str, ...]) -> bytes:
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w") as archive:
        for name in files:
            archive.writestr(f"{root}/{name}", name.encode())
        for name in extra:
            archive.writestr(name, b"extra")
    return result.getvalue()


def make_tar(root: str, extra: tuple[tuple[str, str, str], ...]) -> bytes:
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w:gz") as archive:
        directories = (root, f"{root}/include", f"{root}/lib")
        for name in directories:
            item = tarfile.TarInfo(name)
            item.type = tarfile.DIRTYPE
            archive.addfile(item)
        files = (
            f"{root}/include/onnxruntime_c_api.h",
            f"{root}/LICENSE",
            f"{root}/ThirdPartyNotices.txt",
            f"{root}/lib/libonnxruntime.so.{fetcher.VERSION}",
        )
        for name in files:
            data = name.encode()
            item = tarfile.TarInfo(name)
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
        for name, kind, target in extra:
            item = tarfile.TarInfo(name)
            if kind == "symlink":
                item.type = tarfile.SYMTYPE
                item.linkname = target
                archive.addfile(item)
            else:
                data = target.encode()
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        for name, target in (
            (f"{root}/lib/libonnxruntime.so.{fetcher.VERSION.split('.')[0]}", f"libonnxruntime.so.{fetcher.VERSION}"),
            (f"{root}/lib/libonnxruntime.so", f"libonnxruntime.so.{fetcher.VERSION.split('.')[0]}"),
        ):
            item = tarfile.TarInfo(name)
            item.type = tarfile.SYMTYPE
            item.linkname = target
            archive.addfile(item)
    return result.getvalue()


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "repository"
        (self.repository / "scripts").mkdir(parents=True)

    @contextlib.contextmanager
    def configured(self, system: str, machine: str, root_platform: str, suffix: str, data: bytes, expected: str):
        asset = f"fixture-{system.casefold()}{suffix}"
        digest = expected
        cache = self.repository / ".build" / "onnxruntime" / fetcher.VERSION
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(fetcher, "__file__", str(self.repository / "scripts" / "fetch_onnxruntime.py")))
            stack.enter_context(mock.patch.object(fetcher.platform, "system", return_value=system))
            stack.enter_context(mock.patch.object(fetcher.platform, "machine", return_value=machine))
            stack.enter_context(mock.patch.dict(fetcher.ASSETS, {(system.casefold(), machine.casefold()): (root_platform, asset, digest)}))
            yield asset, cache, self.repository / ".build" / "onnxruntime" / fetcher.VERSION / f"onnxruntime-{root_platform}-{fetcher.VERSION}", data

    def test_valid_zip_and_tar_archives(self) -> None:
        windows_root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        linux_root = f"onnxruntime-linux-x64-{fetcher.VERSION}"
        for system, machine, root_platform, suffix, data in (
            ("Windows", "AMD64", "win-x64", ".zip", make_zip(windows_root, WINDOWS_FILES, ())),
            ("Linux", "x86_64", "linux-x64", ".tgz", make_tar(linux_root, ())),
        ):
            with self.subTest(system=system), self.configured(system, machine, root_platform, suffix, data, hashlib.sha256(data).hexdigest()) as (_, cache, destination, _):
                cache.mkdir(parents=True, exist_ok=True)
                with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))):
                    result = fetcher.fetch()
                self.assertEqual(result, destination.resolve())
                self.assertTrue((destination / "include" / "onnxruntime_c_api.h").is_file())
                self.assertTrue((destination / "LICENSE").is_file())
                self.assertTrue((destination / "ThirdPartyNotices.txt").is_file())
                if system == "Windows":
                    self.assertTrue((destination / "lib" / "onnxruntime.lib").is_file())
                    self.assertTrue((destination / "lib" / "onnxruntime.dll").is_file())
                else:
                    self.assertEqual((destination / "lib" / "libonnxruntime.so").resolve(), (destination / "lib" / f"libonnxruntime.so.{fetcher.VERSION}").resolve())

    def test_tar_rejects_escaping_traversal_and_symlink(self) -> None:
        root = f"onnxruntime-linux-x64-{fetcher.VERSION}"
        cases = (
            ((f"{root}/../../outside", "file", "bad"),),
            ((f"{root}/lib/escape", "symlink", "../../outside"),),
        )
        for extra in cases:
            data = make_tar(root, extra)
            with self.subTest(extra=extra), self.configured("Linux", "x86_64", "linux-x64", ".tgz", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
                cache.mkdir(parents=True, exist_ok=True)
                (cache / asset).write_bytes(data)
                with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))):
                    with self.assertRaises((tarfile.TarError, ValueError)):
                        fetcher.fetch()
                self.assertFalse(destination.exists())
                self.assertFalse((cache.parent.parent / "outside").exists())

    def test_zip_absolute_paths_are_rejected_before_extraction(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        for unsafe in ("/outside", "\\outside", "C:/outside", "C:\\outside", "\\\\server\\share\\outside"):
            data = make_zip(root, WINDOWS_FILES, (unsafe,))
            with self.subTest(name=unsafe), self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
                cache.mkdir(parents=True, exist_ok=True)
                (cache / asset).write_bytes(data)
                with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))), mock.patch.object(zipfile.ZipFile, "extractall", wraps=zipfile.ZipFile.extractall) as extract:
                    with self.assertRaises(ValueError):
                        fetcher.fetch()
                extract.assert_not_called()
                self.assertFalse(destination.exists())

    def test_zip_dotdot_is_normalized_by_zipfile(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        files = tuple(f"include/../onnxruntime_c_api.h" if name == "include/onnxruntime_c_api.h" else name for name in WINDOWS_FILES)
        data = make_zip(root, files, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (_, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))):
                result = fetcher.fetch()
            self.assertEqual(result, destination.resolve())
            self.assertTrue((destination / "include" / "onnxruntime_c_api.h").is_file())
            self.assertEqual(list(cache.glob(".extract-*/**/*outside*")), [])

    def test_wrong_multiple_roots_and_missing_required_files_fail(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        variants = (
            (make_zip("unexpected", WINDOWS_FILES, ()), "wrong root"),
            (make_zip(root, WINDOWS_FILES, ("other/file",)), "multiple roots"),
            (make_zip(root, tuple(name for name in WINDOWS_FILES if name != "include/onnxruntime_c_api.h"), ()), "header"),
            (make_zip(root, tuple(name for name in WINDOWS_FILES if name != "lib/onnxruntime.lib"), ()), "library"),
            (make_zip(root, tuple(name for name in WINDOWS_FILES if name != "LICENSE"), ()), "license"),
        )
        for data, label in variants:
            with self.subTest(case=label), self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
                cache.mkdir(parents=True, exist_ok=True)
                (cache / asset).write_bytes(data)
                with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))):
                    with self.assertRaises(ValueError):
                        fetcher.fetch()
                self.assertFalse(destination.exists())

    def test_linux_library_symlink_must_resolve_inside_root_to_file(self) -> None:
        root = f"onnxruntime-linux-x64-{fetcher.VERSION}"
        data = make_tar(root, ((f"{root}/other/directory-link", "symlink", "../lib"),))
        with self.configured("Linux", "x86_64", "linux-x64", ".tgz", data, hashlib.sha256(data).hexdigest()) as (_, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))):
                with self.assertRaises(ValueError):
                    fetcher.fetch()
            self.assertFalse(destination.exists())

    def test_cached_hash_mismatch_never_downloads_or_extracts(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            (cache / asset).write_bytes(b"corrupt cache")
            with mock.patch.object(fetcher.urllib.request, "urlopen") as download, mock.patch.object(zipfile.ZipFile, "extractall") as extract:
                with self.assertRaises(ValueError):
                    fetcher.fetch()
            download.assert_not_called()
            extract.assert_not_called()
            self.assertFalse(destination.exists())

    def test_downloaded_hash_mismatch_is_not_extracted_or_published(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, expected=hashlib.sha256(b"different").hexdigest()) as (_, cache, destination, _):
            with mock.patch.object(fetcher.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))), mock.patch.object(zipfile, "ZipFile") as open_zip:
                with self.assertRaises(ValueError):
                    fetcher.fetch()
            open_zip.assert_not_called()
            self.assertFalse(destination.exists())
            self.assertEqual(list(cache.glob("*.zip")), [])
            self.assertEqual(list(cache.glob("*.download")), [])

    def test_repeated_fetch_reuses_valid_tree_untouched(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            archive = cache / asset
            archive.write_bytes(data)
            first = fetcher.fetch()
            header = first / "include" / "onnxruntime_c_api.h"
            marker = first / "tree-marker"
            marker.write_bytes(b"preserved")
            header_bytes = header.read_bytes()
            mtime_ns = 1_700_000_000_000_000_000
            os.utime(header, ns=(mtime_ns, mtime_ns))
            header_stat = header.stat()
            marker_bytes = marker.read_bytes()
            archive.write_bytes(b"corrupt archive must not be checked")

            with mock.patch.object(fetcher.urllib.request, "urlopen") as download, mock.patch.object(zipfile.ZipFile, "extractall") as extract:
                second = fetcher.fetch()
            download.assert_not_called()
            extract.assert_not_called()
            self.assertEqual(first, second)
            self.assertEqual(second, destination.resolve())
            self.assertEqual(header.stat(), header_stat)
            self.assertEqual(header.stat().st_mtime_ns, mtime_ns)
            self.assertEqual(header.read_bytes(), header_bytes)
            self.assertEqual(marker.read_bytes(), marker_bytes)

    def test_invalid_existing_tree_requires_deletion_and_remains_untouched(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (_, cache, destination, _):
            destination.mkdir(parents=True)
            marker = destination / "invalid-marker"
            marker.write_text("keep invalid tree")
            with mock.patch.object(fetcher.urllib.request, "urlopen") as download, mock.patch.object(zipfile.ZipFile, "extractall") as extract:
                with self.assertRaises(RuntimeError) as raised:
                    fetcher.fetch()
            self.assertIn(str(destination.resolve()), str(raised.exception))
            self.assertIn("削除", str(raised.exception))
            self.assertIsInstance(raised.exception.__cause__, ValueError)
            download.assert_not_called()
            extract.assert_not_called()
            self.assertEqual(marker.read_text(), "keep invalid tree")

    def test_stale_generated_files_are_removed_but_unrelated_files_remain(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            (cache / asset).write_bytes(data)
            stale_staging = cache / ".extract-stale"
            stale_staging.mkdir()
            (stale_staging / "partial").write_text("partial")
            official_download = cache / f".{fetcher.WINDOWS_X64[1]}.stale.download"
            official_download.write_bytes(b"partial download")
            unrelated_file = cache / "keep.txt"
            unrelated_file.write_text("keep")
            unrelated_download = cache / ".unrelated.download"
            unrelated_download.write_bytes(b"keep")

            result = fetcher.fetch()

            self.assertEqual(result, destination.resolve())
            self.assertFalse(stale_staging.exists())
            self.assertFalse(official_download.exists())
            self.assertEqual(unrelated_file.read_text(), "keep")
            self.assertEqual(unrelated_download.read_bytes(), b"keep")

    def test_publication_failure_cleans_staging_without_creating_destination(self) -> None:
        root = f"onnxruntime-win-x64-{fetcher.VERSION}"
        data = make_zip(root, WINDOWS_FILES, ())
        with self.configured("Windows", "AMD64", "win-x64", ".zip", data, hashlib.sha256(data).hexdigest()) as (asset, cache, destination, _):
            cache.mkdir(parents=True, exist_ok=True)
            (cache / asset).write_bytes(data)
            real_replace = os.replace
            replace_calls: list[tuple[Path, Path]] = []

            def fail_publication(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
                source_path, target_path = Path(source), Path(target)
                replace_calls.append((source_path, target_path))
                if source_path.parent.name.startswith(".extract-"):
                    raise OSError("injected publication failure")
                real_replace(source, target)

            with mock.patch.object(fetcher.os, "replace", side_effect=fail_publication):
                with self.assertRaisesRegex(OSError, "injected publication failure"):
                    fetcher.fetch()
            self.assertEqual(len(replace_calls), 1)
            self.assertTrue(replace_calls[0][0].parent.name.startswith(".extract-"))
            self.assertEqual(replace_calls[0][1].resolve(), destination.resolve())
            self.assertFalse(destination.exists())
            self.assertEqual(list(cache.glob(".extract-*")), [])

    def test_cli_requires_python_312_before_fetch(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Python 3.12 以上", stderr.getvalue())
            fetch.assert_not_called()

    def test_cli_stdout_errors_and_arguments(self) -> None:
        expected = Path(self.temporary.name) / "published-root"
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch", return_value=expected):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 0)
            self.assertEqual(stdout.getvalue(), f"{expected}\n")
            self.assertEqual(stderr.getvalue(), "")

        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch", side_effect=RuntimeError("失敗")):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("失敗", stderr.getvalue())

        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py", "--extra"]), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertNotEqual(stderr.getvalue(), "")
            fetch.assert_not_called()

    def test_supported_platform_machine_spellings(self) -> None:
        for system, machine in (("Linux", "x86_64"), ("Linux", "aarch64"), ("Linux", "arm64"), ("Windows", "AMD64"), ("Windows", "x86_64"), ("Windows", "ARM64"), ("Windows", "aarch64")):
            with self.subTest(system=system, machine=machine):
                self.assertEqual(len(fetcher.choose_asset(system, machine)), 3)


if __name__ == "__main__":
    unittest.main()
