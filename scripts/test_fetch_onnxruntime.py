from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_onnxruntime.py")
SPEC = importlib.util.spec_from_file_location("fetch_onnxruntime", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)
PLATFORM_CASES = (
    ("Linux", "x86_64", "linux-x64"), ("Linux", "aarch64", "linux-arm64"),
    ("Windows", "AMD64", "win-x64"), ("Windows", "ARM64", "win-arm64"),
    ("Darwin", "arm64", "osx-arm64"),
)
EXPECTED_NATIVE_FILES = {
    "linux-x64": (("libonnxruntime.so", "libonnxruntime.so"), ("libonnxruntime_providers_shared.so", "libonnxruntime_providers_shared.so")),
    "linux-arm64": (("libonnxruntime.so", "libonnxruntime.so"), ("libonnxruntime_providers_shared.so", "libonnxruntime_providers_shared.so")),
    "osx-arm64": (("libonnxruntime.dylib", "libonnxruntime.1.dylib"),),
    "win-x64": (("onnxruntime.dll", "onnxruntime.dll"), ("onnxruntime.lib", "onnxruntime.lib"), ("onnxruntime_providers_shared.dll", "onnxruntime_providers_shared.dll"), ("onnxruntime_providers_shared.lib", "onnxruntime_providers_shared.lib")),
    "win-arm64": (("onnxruntime.dll", "onnxruntime.dll"), ("onnxruntime.lib", "onnxruntime.lib"), ("onnxruntime_providers_shared.dll", "onnxruntime_providers_shared.dll"), ("onnxruntime_providers_shared.lib", "onnxruntime_providers_shared.lib")),
}


def fixture_members() -> dict[str, bytes]:
    members = {
        "LICENSE": b"license bytes\x00",
        "ThirdPartyNotices.txt": b"third party bytes\x00",
        "build/native/include/onnxruntime_c_api.h": b"/* ONNX Runtime C API */\r\n#ifndef ONNXRUNTIME_C_API_H\r\n#define ONNXRUNTIME_C_API_H\r\n#endif\r\n",
        "build/native/include/onnxruntime_experimental_c_api.inc": b"ORT_API2_STATUS(ReleaseValue, (OrtValue* value));\r\n",
        "build/native/include/provider_options.h": b"/* Execution provider options */\r\n",
        "build/native/include/subdir/ignored.h": b"ignored nested header",
        "build/native/include/onnxruntime.nuspec": b"ignored metadata",
        "build/native/lib/netstandard2.0/ignored.dll": b"ignored framework binary",
        "runtimes/win-x64/lib/netstandard2.0/ignored.dll": b"ignored runtime metadata",
    }
    for rid, files in EXPECTED_NATIVE_FILES.items():
        for source, _ in files:
            name = f"runtimes/{rid}/native/{source}"
            members[name] = f"native bytes for {name}".encode()
    return members


def make_package(members: dict[str, bytes], extra: tuple[str, ...] = (), special: tuple[str, ...] = ()) -> bytes:
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in members.items():
            info = zipfile.ZipInfo(name)
            info.external_attr = (stat.S_IFLNK | 0o777) << 16 if name in special else 0
            archive.writestr(info, data)
            if name not in special:
                info.external_attr = 0
        for name in extra:
            info = zipfile.ZipInfo(name)
            info.filename = name
            info.external_attr = 0
            archive.writestr(info, b"ignored extra")
            info.external_attr = 0
    return result.getvalue()


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    @contextlib.contextmanager
    def configured(self, system: str, machine: str, data: bytes, digest: str, size: int):
        repository = Path(tempfile.mkdtemp(prefix="repository-", dir=self.temporary.name))
        (repository / "scripts").mkdir()
        cache = repository / ".build" / "onnxruntime" / fetcher.VERSION
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(fetcher, "__file__", str(repository / "scripts" / "fetch_onnxruntime.py")))
            stack.enter_context(mock.patch.object(fetcher.platform, "system", return_value=system))
            stack.enter_context(mock.patch.object(fetcher.platform, "machine", return_value=machine))
            stack.enter_context(mock.patch.object(fetcher, "PACKAGE_SHA256", digest))
            stack.enter_context(mock.patch.object(fetcher, "PACKAGE_BYTES", size))
            download = stack.enter_context(mock.patch.object(fetcher.pinned_download.urllib.request, "urlopen", return_value=contextlib.closing(io.BytesIO(data))))
            yield cache, cache / fetcher.choose_platform(system, machine), download

    def test_platform_inventory_preserves_selected_bytes(self) -> None:
        members = fixture_members()
        data = make_package(members)
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertTrue(all(info.external_attr == 0 for info in archive.infolist()))
        for system, machine, rid in PLATFORM_CASES:
            with self.subTest(platform=rid), self.configured(system, machine, data, hashlib.sha256(data).hexdigest(), len(data)) as (cache, destination, _):
                result = fetcher.fetch()
                self.assertEqual(result, destination.resolve())
                expected = {"LICENSE", "ThirdPartyNotices.txt", "include/onnxruntime_c_api.h", "include/onnxruntime_experimental_c_api.inc", "include/provider_options.h"}
                expected.update(f"lib/{output}" for _, output in EXPECTED_NATIVE_FILES[rid])
                if rid.startswith("linux-"):
                    expected.add("lib/libonnxruntime.so.1")
                actual = {path.relative_to(destination).as_posix() for path in destination.rglob("*") if path.is_file() or path.is_symlink()}
                self.assertEqual(actual, expected)
                for name in ("LICENSE", "ThirdPartyNotices.txt", "include/onnxruntime_c_api.h", "include/onnxruntime_experimental_c_api.inc", "include/provider_options.h"):
                    source = name if name in ("LICENSE", "ThirdPartyNotices.txt") else f"build/native/{name}"
                    self.assertEqual((destination / name).read_bytes(), members[source])
                for source, output in EXPECTED_NATIVE_FILES[rid]:
                    member = f"runtimes/{rid}/native/{source}"
                    self.assertEqual((destination / "lib" / output).read_bytes(), members[member])
                self.assertEqual((cache / fetcher.PACKAGE_NAME).read_bytes(), data)
                if rid.startswith("linux-"):
                    link = destination / "lib" / "libonnxruntime.so.1"
                    self.assertTrue(link.is_symlink())
                    self.assertEqual(os.readlink(link), "libonnxruntime.so")
                    self.assertTrue((destination / "lib" / "libonnxruntime.so").is_file())
                if rid == "osx-arm64":
                    self.assertFalse((destination / "lib" / "libonnxruntime.1.dylib").is_symlink())

    def test_unsafe_paths_and_selected_special_files_are_rejected(self) -> None:
        base = fixture_members()
        cases = ("../outside", "/outside", r"\outside", "C:/outside", "C:\\outside", "safe\\name", "build/native/include/C:outside.h", "build/native/include/header.h:stream.h")
        for unsafe in cases:
            data = make_package(base, extra=(unsafe,))
            with self.subTest(path=unsafe), self.configured("Windows", "AMD64", data, hashlib.sha256(data).hexdigest(), len(data)) as (_, destination, _):
                with self.assertRaisesRegex(ValueError, "安全でない"):
                    fetcher.fetch()
                self.assertFalse(destination.exists())
        selected = "runtimes/win-x64/native/onnxruntime.dll"
        data = make_package(base, special=(selected,))
        with self.configured("Windows", "AMD64", data, hashlib.sha256(data).hexdigest(), len(data)) as (_, destination, _):
            with self.assertRaisesRegex(ValueError, "通常ファイル"):
                fetcher.fetch()
            self.assertFalse(destination.exists())

    def test_missing_headers_licenses_and_native_files_fail(self) -> None:
        cases = [
            ("LICENSE", "Windows", "AMD64"),
            ("ThirdPartyNotices.txt", "Windows", "AMD64"),
            ("build/native/include/onnxruntime_c_api.h", "Windows", "AMD64"),
            ("build/native/include/onnxruntime_experimental_c_api.inc", "Windows", "AMD64"),
        ]
        for system, machine, rid in PLATFORM_CASES:
            cases.extend((f"runtimes/{rid}/native/{source}", system, machine) for source, _ in EXPECTED_NATIVE_FILES[rid])
        for missing, system, machine in cases:
            members = fixture_members()
            del members[missing]
            data = make_package(members)
            with self.subTest(missing=missing), self.configured(system, machine, data, hashlib.sha256(data).hexdigest(), len(data)) as (_, destination, _):
                with self.assertRaises(ValueError):
                    fetcher.fetch()
                self.assertFalse(destination.exists())

    def test_cached_and_downloaded_hash_mismatches_fail(self) -> None:
        data = make_package(fixture_members())
        wrong_digest = hashlib.sha256(b"different pinned package").hexdigest()
        for cached in (False, True):
            with self.subTest(cached=cached), self.configured("Windows", "AMD64", data, wrong_digest, len(data)) as (cache, destination, download):
                if cached:
                    cache.mkdir(parents=True)
                    (cache / fetcher.PACKAGE_NAME).write_bytes(data)
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    fetcher.fetch()
                self.assertFalse(destination.exists())
                self.assertEqual(list(cache.glob(f".{fetcher.PACKAGE_NAME}.*.download")), [])
                self.assertEqual((cache / fetcher.PACKAGE_NAME).exists(), cached)
                if cached:
                    download.assert_not_called()

    def test_package_size_is_checked_before_extraction_on_every_platform(self) -> None:
        data = make_package(fixture_members())
        for system, machine, rid in PLATFORM_CASES:
            with self.subTest(platform=rid), self.configured(system, machine, data, hashlib.sha256(data).hexdigest(), len(data) + 1) as (_, destination, _):
                with mock.patch.object(fetcher, "_extract") as extract:
                    with self.assertRaisesRegex(ValueError, "サイズが一致しません"):
                        fetcher.fetch()
                extract.assert_not_called()
                self.assertFalse(destination.exists())

    def test_valid_tree_is_reused_untouched(self) -> None:
        data = make_package(fixture_members())
        with self.configured("Windows", "AMD64", data, hashlib.sha256(data).hexdigest(), len(data)) as (cache, destination, _):
            first = fetcher.fetch()
            header = first / "include" / "onnxruntime_c_api.h"
            marker = first / "tree-marker"
            marker.write_bytes(b"preserve")
            os.utime(header, ns=(1_700_000_000_000_000_000, 1_700_000_000_000_000_000))
            before = header.stat()
            (cache / fetcher.PACKAGE_NAME).write_bytes(b"bad cached archive ignored")
            with mock.patch.object(fetcher.pinned_download.urllib.request, "urlopen") as download, mock.patch.object(fetcher, "_extract") as extract:
                second = fetcher.fetch()
            download.assert_not_called()
            extract.assert_not_called()
            self.assertEqual(first, second)
            self.assertEqual(header.stat(), before)
            self.assertEqual(marker.read_bytes(), b"preserve")

    def test_invalid_existing_tree_requires_deletion_and_stays_untouched(self) -> None:
        data = make_package(fixture_members())
        digest = hashlib.sha256(data).hexdigest()
        with self.configured("Windows", "AMD64", data, digest, len(data)) as (_, destination, download):
            destination.mkdir(parents=True)
            marker = destination / "keep.txt"
            marker.write_text("invalid but untouched")
            with self.assertRaisesRegex(RuntimeError, "削除") as raised:
                fetcher.fetch()
            self.assertIn(str(destination.resolve()), str(raised.exception))
            self.assertEqual(marker.read_text(), "invalid but untouched")
            download.assert_not_called()

        for corruption, target in (("escaping", None), ("directory", "../include"), ("dangling", "missing.so")):
            with self.subTest(linux_soname=corruption), self.configured("Linux", "x86_64", data, digest, len(data)) as (_, destination, _):
                fetcher.fetch()
                marker = destination / "keep.txt"
                marker.write_text("valid tree marker")
                soname = destination / "lib" / "libonnxruntime.so.1"
                soname.unlink()
                if corruption == "escaping":
                    outside = Path(self.temporary.name) / "outside-soname-target.so"
                    outside.write_bytes(b"outside target")
                    target = str(outside)
                soname.symlink_to(target)
                before_link = os.readlink(soname)
                with self.assertRaisesRegex(RuntimeError, "削除") as raised:
                    fetcher.fetch()
                self.assertIn(str(destination.resolve()), str(raised.exception))
                self.assertEqual(marker.read_text(), "valid tree marker")
                self.assertTrue(soname.is_symlink())
                self.assertEqual(os.readlink(soname), before_link)

        with self.subTest(macos="unexpected symlink"), self.configured("Darwin", "arm64", data, digest, len(data)) as (_, destination, _):
            fetcher.fetch()
            marker = destination / "keep.txt"
            marker.write_text("valid tree marker")
            unexpected = destination / "lib" / "unexpected-link"
            unexpected.symlink_to("libonnxruntime.1.dylib")
            with self.assertRaisesRegex(RuntimeError, "削除") as raised:
                fetcher.fetch()
            self.assertIn(str(destination.resolve()), str(raised.exception))
            self.assertEqual(marker.read_text(), "valid tree marker")
            self.assertTrue(unexpected.is_symlink())
            self.assertEqual(os.readlink(unexpected), "libonnxruntime.1.dylib")

    def test_only_current_package_temporaries_and_staging_are_cleaned(self) -> None:
        data = make_package(fixture_members())
        with self.configured("Windows", "AMD64", data, hashlib.sha256(data).hexdigest(), len(data)) as (cache, destination, _):
            cache.mkdir(parents=True)
            (cache / fetcher.PACKAGE_NAME).write_bytes(data)
            staging = cache / ".extract-stale"
            staging.mkdir()
            (staging / "partial").write_bytes(b"partial")
            temporary = cache / f".{fetcher.PACKAGE_NAME}.stale.download"
            temporary.write_bytes(b"partial")
            unrelated = cache / ".microsoft.ml.onnxruntime.1.30.0.nupkg.stale.download"
            unrelated.write_bytes(b"retain")
            fetcher.fetch()
            self.assertFalse(staging.exists())
            self.assertFalse(temporary.exists())
            self.assertEqual(unrelated.read_bytes(), b"retain")
            self.assertTrue(destination.is_dir())

    def test_failed_publication_cleans_staging(self) -> None:
        data = make_package(fixture_members())
        with self.configured("Windows", "AMD64", data, hashlib.sha256(data).hexdigest(), len(data)) as (cache, destination, _):
            cache.mkdir(parents=True)
            (cache / fetcher.PACKAGE_NAME).write_bytes(data)
            with mock.patch.object(fetcher.os, "replace", side_effect=OSError("injected publication failure")):
                with self.assertRaisesRegex(OSError, "injected publication failure"):
                    fetcher.fetch()
            self.assertFalse(destination.exists())
            self.assertEqual(list(cache.glob(".extract-*")), [])

    def test_package_identity_platform_mapping_and_cli(self) -> None:
        self.assertEqual(fetcher.VERSION, "1.31.0")
        self.assertEqual(fetcher.PACKAGE_NAME, "microsoft.ml.onnxruntime.1.31.0.nupkg")
        self.assertEqual(fetcher.PACKAGE_URL, "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.31.0/microsoft.ml.onnxruntime.1.31.0.nupkg")
        self.assertEqual(fetcher.PACKAGE_BYTES, 159626085)
        self.assertEqual(fetcher.PACKAGE_SHA256, "7e35fdb4f5adb62f01e60798e2e5ed05108f5fbbe1cca03fbcc37903cf7c5e3b")
        for system, machine, rid in PLATFORM_CASES + (("Linux", "arm64", "linux-arm64"), ("Windows", "x86_64", "win-x64"), ("Windows", "aarch64", "win-arm64")):
            with self.subTest(platform=(system, machine)):
                self.assertEqual(fetcher.choose_platform(system, machine), rid)
        with self.assertRaises(RuntimeError) as unsupported:
            fetcher.choose_platform("Darwin", "x86_64")
        self.assertEqual(str(unsupported.exception), "未対応の実行環境です: platform.system()='Darwin', platform.machine()='x86_64'。Linux x86_64/aarch64/arm64、Windows AMD64/x86_64/ARM64/aarch64、macOS arm64 のみ対応します。")
        expected = Path(self.temporary.name) / "published"
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch") as fetch:
            output, error = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                self.assertEqual(fetcher.main(), 1)
            self.assertEqual(output.getvalue(), "")
            self.assertIn("Python 3.12 以上", error.getvalue())
            fetch.assert_not_called()
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py", "--extra"]), mock.patch.object(fetcher, "fetch") as fetch:
            output, error = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                self.assertEqual(fetcher.main(), 2)
            self.assertEqual(output.getvalue(), "")
            self.assertIn("引数", error.getvalue())
            fetch.assert_not_called()
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch", return_value=expected):
            output, error = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                self.assertEqual(fetcher.main(), 0)
            self.assertEqual(output.getvalue(), f"{expected}\n")
            self.assertEqual(error.getvalue(), "")
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(fetcher.sys, "argv", ["fetch_onnxruntime.py"]), mock.patch.object(fetcher, "fetch", side_effect=RuntimeError("失敗")):
            output, error = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                self.assertEqual(fetcher.main(), 1)
            self.assertEqual(output.getvalue(), "")
            self.assertIn("失敗", error.getvalue())


if __name__ == "__main__":
    unittest.main()
