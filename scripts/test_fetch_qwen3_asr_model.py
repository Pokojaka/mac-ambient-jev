from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_qwen3_asr_model.py")
SPEC = importlib.util.spec_from_file_location("fetch_qwen3_asr_model", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


EXPECTED_REPOSITORIES = {
    "0.6b": "andrewleech/qwen3-asr-0.6b-onnx",
    "1.7b": "andrewleech/qwen3-asr-1.7b-onnx",
}
EXPECTED_COMMITS = {
    "0.6b": "4fc24a1402e74db89c4d2ef256875e71680128c4",
    "1.7b": "df916193ac67e59347769891a21e10d81d12acdd",
}
EXPECTED_FILES = {
    "0.6b": (
        ("encoder.onnx", 745762694, "3c027f880f677615de85e1f6934906e1d5d77624b724096d33accef99c753eed"),
        ("decoder_init.int4.onnx", 355390, "6d54633bbb9e6b1ecf372f218d04adb3bf6f2bfc442ce55c988526d532896faa"),
        ("decoder_step.int4.onnx", 354888, "7eaa4f31d5eb6ae2937ff45222c32f692f2d5ac29b46cbae9046da332a9f317d"),
        ("decoder_weights.int4.data", 962460672, "d68cd1c0695a7ba42651d06b1bc1158e2e58af5f9adbb6dba874fbbb8a4f22cf"),
        ("embed_tokens.bin", 311164928, "e80150119fa5f7e56e85aed64c3a02d5c78eb7a37cfdcb973d0987316f15bee2"),
        ("tokenizer.json", 11429377, "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"),
    ),
    "1.7b": (
        ("encoder.onnx", 1270241779, "c19ff8d702707693877a509ba1867472b0ad964593b93751091891a143edffec"),
        ("decoder_init.int4.onnx", 356165, "c638585ada629b3cf65ce9cb068b7b980fccc9454a7f05e2333b8813730c1999"),
        ("decoder_step.int4.onnx", 355662, "fa138c025c26f6559e12be51cfbba5204a0b6993a1f3bb1177f80a0a65873bb5"),
        ("decoder_weights.int4.data", 2226321408, "3f8d8fb695bcffc20ce8d8e823471e011404420785adf7678aac31057ef67333"),
        ("embed_tokens.bin", 622329856, "1489075dbd08fcd6b87bc69c5feca278014d29fa5693bd4aa61e47c1a3a160d4"),
        ("tokenizer.json", 11429377, "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"),
    ),
}


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "destination"
        self.root.mkdir()
        self.root = self.root.resolve()
        self.network_forbidden = mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            side_effect=AssertionError("unexpected network access"),
        )
        self.network_forbidden.start()
        self.addCleanup(self.network_forbidden.stop)

    def tiny_files(self, payload: bytes) -> dict[str, tuple[tuple[str, int, str], ...]]:
        return {
            size: (("model.bin", len(payload), hashlib.sha256(payload).hexdigest()),)
            for size in EXPECTED_REPOSITORIES
        }

    def test_pinned_tables_match_expected_repositories_commits_and_files(self) -> None:
        self.assertEqual(fetcher.REPOSITORIES, EXPECTED_REPOSITORIES)
        self.assertEqual(fetcher.COMMITS, EXPECTED_COMMITS)
        self.assertEqual(fetcher.FILES, EXPECTED_FILES)
        for size in EXPECTED_REPOSITORIES:
            self.assertEqual(len(fetcher.FILES[size]), 6)

    def test_download_urls_arguments_and_output_directory_for_each_size(self) -> None:
        test_files = {
            size: tuple(
                (filename, index, f"sha-{size}-{index}")
                for index, (filename, _byte_size, _sha256) in enumerate(
                    EXPECTED_FILES[size], start=1
                )
            )
            for size in EXPECTED_REPOSITORIES
        }
        sizes_by_sha = {
            sha256: byte_size
            for rows in test_files.values()
            for _filename, byte_size, sha256 in rows
        }
        calls: list[tuple[str, str, Path]] = []

        def download_stub(url: str, sha256: str, destination: Path) -> Path:
            calls.append((url, sha256, destination))
            destination.write_bytes(b"x" * sizes_by_sha[sha256])
            return destination

        with mock.patch.object(fetcher, "FILES", test_files), mock.patch.object(
            fetcher.pinned_download, "download_verified", side_effect=download_stub
        ) as download:
            for size in ("0.6b", "1.7b"):
                result = fetcher.fetch(size, self.root)
                expected_directory = self.root / (
                    f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
                )
                self.assertEqual(result, expected_directory)
                self.assertTrue(result.is_dir())
                self.assertEqual(
                    sorted(path.name for path in result.iterdir()),
                    sorted(filename for filename, _byte_size, _sha in test_files[size]),
                )

        expected_calls = [
            (
                f"https://huggingface.co/{EXPECTED_REPOSITORIES[size]}/resolve/"
                f"{EXPECTED_COMMITS[size]}/{filename}",
                sha256,
                self.root
                / f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
                / filename,
            )
            for size in ("0.6b", "1.7b")
            for filename, _byte_size, sha256 in test_files[size]
        ]
        self.assertEqual(calls, expected_calls)
        self.assertEqual(download.call_args_list, [mock.call(*call) for call in expected_calls])

    def test_fetch_rejects_unsupported_size(self) -> None:
        with self.assertRaisesRegex(ValueError, "未対応"):
            fetcher.fetch("0.6B", self.root)

    def test_validate_destination_rejects_relative_missing_and_non_directory(self) -> None:
        with self.assertRaisesRegex(ValueError, "絶対パス"):
            fetcher.validate_destination(Path("relative"))
        with self.assertRaisesRegex(ValueError, "ありません"):
            fetcher.validate_destination(self.root / "missing")
        file_path = self.root / "not-a-directory"
        file_path.write_text("file", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "ディレクトリではありません"):
            fetcher.validate_destination(file_path)

    def test_validate_destination_allows_directory_symlink_and_canonicalizes(self) -> None:
        actual = self.root / "actual"
        actual.mkdir()
        alias = self.root / "alias"
        try:
            alias.symlink_to(actual, target_is_directory=True)
        except (NotImplementedError, OSError) as error:
            self.skipTest(f"directory symlinks are unavailable: {error}")
        self.assertEqual(fetcher.validate_destination(alias), actual.resolve())

    def test_model_child_symlink_is_rejected(self) -> None:
        size = "0.6b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        try:
            model_directory.symlink_to(outside, target_is_directory=True)
        except (NotImplementedError, OSError) as error:
            self.skipTest(f"directory symlinks are unavailable: {error}")
        with mock.patch.object(fetcher, "FILES", self.tiny_files(b"x")):
            with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
                fetcher.fetch(size, self.root)
        self.assertEqual(list(outside.iterdir()), [])

    def test_model_child_file_is_rejected(self) -> None:
        size = "1.7b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        model_directory.write_text("not a directory", encoding="utf-8")
        with mock.patch.object(fetcher, "FILES", self.tiny_files(b"x")):
            with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
                fetcher.fetch(size, self.root)

    def test_existing_verified_file_is_reused_without_network_or_mtime_change(self) -> None:
        payload = b"verified tiny model"
        size = "0.6b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        model_directory.mkdir()
        target = model_directory / "model.bin"
        target.write_bytes(payload)
        mtime_ns = 1_700_000_000_000_000_000
        os.utime(target, ns=(mtime_ns, mtime_ns))
        original_mtime = target.stat().st_mtime_ns

        with mock.patch.object(fetcher, "FILES", self.tiny_files(payload)):
            result = fetcher.fetch(size, self.root)

        self.assertEqual(result, model_directory)
        self.assertEqual(target.stat().st_mtime_ns, original_mtime)
        self.assertEqual(target.read_bytes(), payload)

    def test_existing_hash_mismatch_fails_without_redownload(self) -> None:
        payload = b"expected payload"
        size = "1.7b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        model_directory.mkdir()
        target = model_directory / "model.bin"
        target.write_bytes(b"corrupt existing payload")
        with mock.patch.object(fetcher, "FILES", self.tiny_files(payload)):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                fetcher.fetch(size, self.root)
        self.assertEqual(target.read_bytes(), b"corrupt existing payload")

    def test_downloaded_hash_mismatch_is_not_published(self) -> None:
        payload = b"wrong downloaded payload"
        expected_hash = hashlib.sha256(b"different expected payload").hexdigest()
        size = "0.6b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        files = {model: (("model.bin", len(payload), expected_hash),) for model in EXPECTED_REPOSITORIES}
        with mock.patch.object(fetcher, "FILES", files), mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(payload)),
        ):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                fetcher.fetch(size, self.root)
        self.assertFalse((model_directory / "model.bin").exists())
        self.assertEqual(list(model_directory.glob(".model.bin.*.download")), [])

    def test_downloaded_size_mismatch_raises_value_error_with_details(self) -> None:
        size = "0.6b"
        filename = "model.bin"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        expected_size = 9
        target = model_directory / filename
        files = {model: ((filename, expected_size, "unused-sha"),) for model in EXPECTED_REPOSITORIES}

        def write_wrong_size(_url: str, _sha256: str, destination: Path) -> Path:
            destination.write_bytes(b"bad")
            return destination

        with mock.patch.object(fetcher, "FILES", files), mock.patch.object(
            fetcher.pinned_download, "download_verified", side_effect=write_wrong_size
        ):
            with self.assertRaisesRegex(
                ValueError,
                rf"{re.escape(str(target))}.*期待値 {expected_size}、実際 3",
            ):
                fetcher.fetch(size, self.root)

    def test_cli_rejects_unsupported_python_before_arguments(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_qwen3_asr_model.py"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Python 3.12 以上", stderr.getvalue())
        fetch.assert_not_called()

    def test_cli_requires_exactly_two_arguments(self) -> None:
        for argv in (
            ["fetch_qwen3_asr_model.py"],
            ["fetch_qwen3_asr_model.py", "0.6b"],
            ["fetch_qwen3_asr_model.py", "0.6b", str(self.root), "extra"],
        ):
            with self.subTest(argv=argv), mock.patch.object(
                fetcher.sys, "version_info", (3, 13, 3)
            ), mock.patch.object(fetcher.sys, "argv", argv), mock.patch.object(
                fetcher, "fetch"
            ) as fetch:
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    code = fetcher.main()
                self.assertEqual(code, 2)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("使い方", stderr.getvalue())
                fetch.assert_not_called()

    def test_cli_bad_sizes_and_destinations_exit_two_before_fetch(self) -> None:
        file_path = self.root / "file"
        file_path.write_text("file", encoding="utf-8")
        invalid_arguments = (
            ("0.6B", str(self.root)),
            ("0.6", str(self.root)),
            ("7b", str(self.root)),
            ("", str(self.root)),
            ("0.6b", "relative"),
            ("0.6b", str(self.root / "missing")),
            ("0.6b", str(file_path)),
        )
        for size, destination in invalid_arguments:
            with self.subTest(size=size, destination=destination), mock.patch.object(
                fetcher.sys, "version_info", (3, 13, 3)
            ), mock.patch.object(
                fetcher.sys,
                "argv",
                ["fetch_qwen3_asr_model.py", size, destination],
            ), mock.patch.object(fetcher, "fetch") as fetch:
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    code = fetcher.main()
                self.assertEqual(code, 2)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("エラー:", stderr.getvalue())
                fetch.assert_not_called()

    def test_cli_prints_only_model_directory_on_success(self) -> None:
        expected = self.root / "qwen3-asr-0.6b-int4-commit"
        with mock.patch.object(fetcher.sys, "version_info", (3, 13, 3)), mock.patch.object(
            fetcher.sys,
            "argv",
            ["fetch_qwen3_asr_model.py", "0.6b", str(self.root)],
        ), mock.patch.object(fetcher, "fetch", return_value=expected) as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), f"{expected}\n")
        self.assertEqual(stderr.getvalue(), "")
        fetch.assert_called_once_with("0.6b", self.root)

    def test_cli_destination_os_failure_exits_one(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 13, 3)), mock.patch.object(
            fetcher.sys,
            "argv",
            ["fetch_qwen3_asr_model.py", "0.6b", str(self.root)],
        ), mock.patch.object(
            fetcher, "validate_destination", side_effect=PermissionError("permission denied")
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Qwen3-ASR モデルの取得に失敗しました", stderr.getvalue())
        self.assertIn("permission denied", stderr.getvalue())
        fetch.assert_not_called()

    def test_cli_acquisition_exception_exits_one(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 13, 3)), mock.patch.object(
            fetcher.sys,
            "argv",
            ["fetch_qwen3_asr_model.py", "0.6b", str(self.root)],
        ), mock.patch.object(
            fetcher, "fetch", side_effect=OSError("network unavailable")
        ) as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("エラー: Qwen3-ASR モデルの取得に失敗しました:", stderr.getvalue())
        self.assertIn("network unavailable", stderr.getvalue())
        fetch.assert_called_once()

    def test_cli_size_mismatch_exits_one_as_acquisition_failure(self) -> None:
        size = "1.7b"
        model_directory = self.root / (
            f"qwen3-asr-{size}-int4-{EXPECTED_COMMITS[size]}"
        )
        target = model_directory / "model.bin"
        files = {model: (("model.bin", 5, "unused-sha"),) for model in EXPECTED_REPOSITORIES}

        def write_wrong_size(_url: str, _sha256: str, destination: Path) -> Path:
            destination.write_bytes(b"bad")
            return destination

        with mock.patch.object(fetcher, "FILES", files), mock.patch.object(
            fetcher.pinned_download, "download_verified", side_effect=write_wrong_size
        ), mock.patch.object(fetcher.sys, "version_info", (3, 13, 3)), mock.patch.object(
            fetcher.sys,
            "argv",
            ["fetch_qwen3_asr_model.py", size, str(self.root)],
        ):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("Qwen3-ASR モデルの取得に失敗しました", stderr.getvalue())
        self.assertIn(str(target), stderr.getvalue())
        self.assertIn("期待値 5、実際 3", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
