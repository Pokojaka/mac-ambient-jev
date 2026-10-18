from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_silero_vad.py")
SPEC = importlib.util.spec_from_file_location("fetch_silero_vad", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "repository"
        self.repository.mkdir()
        self.repository = self.repository.resolve()
        self.script_path = self.repository / "scripts" / "fetch_silero_vad.py"
        self.script_path.parent.mkdir()
        self.destination = (
            self.repository
            / ".build"
            / "silero-vad"
            / fetcher.COMMIT
            / fetcher.MODEL_FILENAME
        )
        self.payload = b"offline Silero VAD model fixture"
        self.expected = hashlib.sha256(self.payload).hexdigest()

    def fetch_fixture(self) -> Path:
        with mock.patch.object(fetcher, "__file__", self.script_path), mock.patch.object(
            fetcher, "SHA256", self.expected
        ):
            return fetcher.fetch()

    def test_downloads_pinned_model_to_repository_cache(self) -> None:
        with mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(self.payload)),
        ) as download:
            result = self.fetch_fixture()

        self.assertTrue(result.is_absolute())
        self.assertEqual(result, self.destination.resolve())
        self.assertEqual(result.read_bytes(), self.payload)
        download.assert_called_once_with(fetcher.MODEL_URL, timeout=60)
        self.assertEqual(list(self.destination.parent.glob("*.download")), [])

    def test_reuses_verified_model_without_network_or_mtime_change(self) -> None:
        with mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(self.payload)),
        ):
            first = self.fetch_fixture()
        mtime_ns = 1_700_000_000_000_000_000
        os.utime(first, ns=(mtime_ns, mtime_ns))
        original_mtime = first.stat().st_mtime_ns

        with mock.patch.object(fetcher.pinned_download.urllib.request, "urlopen") as download:
            second = self.fetch_fixture()

        download.assert_not_called()
        self.assertEqual(first, second)
        self.assertEqual(second.stat().st_mtime_ns, original_mtime)
        self.assertEqual(second.read_bytes(), self.payload)

    def test_existing_hash_mismatch_fails_without_download(self) -> None:
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"corrupt existing model")

        with mock.patch.object(fetcher.pinned_download.urllib.request, "urlopen") as download:
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                self.fetch_fixture()

        download.assert_not_called()
        self.assertEqual(self.destination.read_bytes(), b"corrupt existing model")

    def test_downloaded_hash_mismatch_is_not_published_and_temp_is_removed(self) -> None:
        wrong_sha256 = hashlib.sha256(b"different model").hexdigest()
        with mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(self.payload)),
        ), mock.patch.object(fetcher, "__file__", self.script_path), mock.patch.object(
            fetcher, "SHA256", wrong_sha256
        ):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                fetcher.fetch()

        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.glob(f".{fetcher.MODEL_FILENAME}.*.download")), [])

    def test_network_failure_removes_temporary_file(self) -> None:
        with mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            side_effect=OSError("network unavailable"),
        ):
            with self.assertRaisesRegex(OSError, "network unavailable"):
                self.fetch_fixture()

        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.destination.parent.glob(f".{fetcher.MODEL_FILENAME}.*.download")), [])

    def test_symlink_directory_escape_is_rejected(self) -> None:
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        build = self.repository / ".build"
        build.mkdir()
        (build / "silero-vad").symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(RuntimeError, "リポジトリ外|通常のディレクトリ"):
            self.fetch_fixture()

        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((outside / fetcher.COMMIT).exists())

    def test_symlink_file_escape_is_rejected(self) -> None:
        outside = Path(self.temporary.name) / "outside.onnx"
        outside.write_bytes(self.payload)
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to(outside)

        with self.assertRaisesRegex(RuntimeError, "リポジトリ外|通常ファイル"):
            self.fetch_fixture()

        self.assertEqual(outside.read_bytes(), self.payload)

    def test_cli_rejects_unsupported_python_and_arguments(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_silero_vad.py"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Python 3.12 以上", stderr.getvalue())
            fetch.assert_not_called()

        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_silero_vad.py", "--extra"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("引数を受け付けません", stderr.getvalue())
            fetch.assert_not_called()

    def test_cli_prints_only_absolute_path_on_success(self) -> None:
        expected = self.destination.resolve()
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_silero_vad.py"]
        ), mock.patch.object(fetcher, "fetch", return_value=expected):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), f"{expected}\n")
        self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
