from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_community1_diarization.py")
SPEC = importlib.util.spec_from_file_location("fetch_community1_diarization", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)

REPOSITORY = Path(__file__).resolve().parent.parent
SWIFT_MANIFEST = (
    REPOSITORY
    / "app/MacAmbientJev/Sources/MacAmbientJevDiarization/Resources/community1_diarization_models.json"
)

PINS = {
    "segmentation": (
        "avencera/speakrs-models",
        "67f963b6a1d94fcd4678948237b3cc8bd69bf1d8",
        "segmentation-3.0.onnx",
        5_916_308,
        "038b971741ed623af9773ecafdefa4b7bc523520099c2a68f8568b24189e8ad9",
    ),
    "embedding": (
        "avencera/speakrs-models",
        "67f963b6a1d94fcd4678948237b3cc8bd69bf1d8",
        "wespeaker-multimask-tail.onnx",
        26_777_461,
        "3695eeb26e875c606d5b5d82314f08dbcbb685d691837c035d7ea690863c64ea",
    ),
    "plda": (
        "FluidInference/speaker-diarization-coreml",
        "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "plda-parameters.json",
        89_416,
        "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f",
    ),
    "xvector": (
        "FluidInference/speaker-diarization-coreml",
        "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "xvector-transform.json",
        177_499,
        "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688",
    ),
}


class ManifestTests(unittest.TestCase):
    def test_script_reads_the_manifest_file_the_swift_target_bundles(self) -> None:
        self.assertEqual(fetcher.MANIFEST_PATH, SWIFT_MANIFEST)
        copies = [
            path
            for path in REPOSITORY.rglob("community1_diarization_models.json")
            if ".build" not in path.relative_to(REPOSITORY).parts
        ]
        self.assertEqual(copies, [SWIFT_MANIFEST])

    def test_all_four_pins(self) -> None:
        files, key = fetcher.load_manifest()

        self.assertEqual([file.role for file in files], list(fetcher.ROLES))
        for file in files:
            repository, revision, name, byte_count, sha256 = PINS[file.role]
            self.assertEqual(
                (file.repository, file.revision, file.name, file.byte_count, file.sha256),
                (repository, revision, name, byte_count, sha256),
            )
            self.assertEqual(
                file.url,
                f"https://huggingface.co/{repository}/resolve/{revision}/{name}",
            )
        self.assertEqual(key, "df2625ac79a7-67f963b6a1d9")

    def test_swift_and_script_share_the_coordinate_signs_owner(self) -> None:
        manifest = json.loads(SWIFT_MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(len(manifest["coordinateSigns"]), 128)
        self.assertTrue(all(sign in (-1, 1) for sign in manifest["coordinateSigns"]))

    def test_invalid_manifests_are_rejected(self) -> None:
        valid = json.loads(SWIFT_MANIFEST.read_text(encoding="utf-8"))

        def mutated(change) -> str:
            copy = json.loads(json.dumps(valid))
            change(copy)
            return json.dumps(copy)

        cases = {
            "missing role": lambda m: m["files"].pop(),
            "duplicate role": lambda m: m["files"].append(dict(m["files"][0])),
            "unknown role": lambda m: m["files"][0].update(role="other"),
            "path in name": lambda m: m["files"][0].update(name="../escape.onnx"),
            "short sha": lambda m: m["files"][0].update(sha256="abc"),
            "uppercase sha": lambda m: m["files"][0].update(sha256=m["files"][0]["sha256"].upper()),
            "zero size": lambda m: m["files"][0].update(byteCount=0),
        }
        for name, change in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                fetcher.parse_manifest(mutated(change))
        with self.assertRaises(KeyError):
            fetcher.parse_manifest(mutated(lambda m: m["files"][0].update(source="unknown")))


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = self.make_repository("repository")
        self.payloads = {
            role: f"offline {role} fixture".encode() for role in fetcher.ROLES
        }
        self.files = [
            fetcher.ModelFile(
                role,
                repository,
                revision,
                name,
                len(self.payloads[role]),
                hashlib.sha256(self.payloads[role]).hexdigest(),
            )
            for role, (repository, revision, name, _, _) in PINS.items()
        ]
        self.key = "fixture-key"
        self.by_url = {file.url: self.payloads[file.role] for file in self.files}
        self.fetched_urls: list[str] = []

    def make_repository(self, name: str) -> Path:
        repository = Path(self.temporary.name) / name
        (repository / "scripts").mkdir(parents=True)
        return repository.resolve()

    def urlopen(self, url: str, timeout: int):
        self.fetched_urls.append(url)
        return contextlib.closing(io.BytesIO(self.by_url[url]))

    def fetch(self, repository: Path | None = None, files=None) -> Path:
        repository = repository or self.repository
        with mock.patch.object(
            fetcher, "__file__", repository / "scripts" / "fetch_community1_diarization.py"
        ), mock.patch.object(
            fetcher.pinned_download.urllib.request, "urlopen", side_effect=self.urlopen
        ):
            return fetcher.fetch(files or self.files, self.key)

    def directory(self, repository: Path | None = None) -> Path:
        return (repository or self.repository) / ".build" / "community1-diarization" / self.key

    def test_downloads_all_four_pinned_files_into_one_directory(self) -> None:
        result = self.fetch()

        self.assertTrue(result.is_absolute())
        self.assertEqual(result, self.directory())
        self.assertEqual(self.fetched_urls, [file.url for file in self.files])
        for file in self.files:
            self.assertEqual((result / file.name).read_bytes(), self.payloads[file.role])
        self.assertEqual(sorted(path.name for path in result.iterdir()), sorted(f.name for f in self.files))

    def test_duplicate_run_reuses_the_verified_directory_without_network(self) -> None:
        first = self.fetch()
        mtime_ns = 1_700_000_000_000_000_000
        for path in first.iterdir():
            os.utime(path, ns=(mtime_ns, mtime_ns))
        self.fetched_urls.clear()

        second = self.fetch()

        self.assertEqual(first, second)
        self.assertEqual(self.fetched_urls, [])
        for path in second.iterdir():
            self.assertEqual(path.stat().st_mtime_ns, mtime_ns)

    def test_corrupt_existing_file_is_rejected_without_download_or_overwrite(self) -> None:
        directory = self.directory()
        directory.mkdir(parents=True)
        corrupt = directory / self.files[2].name
        corrupt.write_bytes(b"corrupt existing file")

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.fetch()

        self.assertEqual(corrupt.read_bytes(), b"corrupt existing file")
        self.assertNotIn(self.files[2].url, self.fetched_urls)

    def test_wrong_size_with_matching_hash_is_rejected(self) -> None:
        wrong_size = [self.files[0]._replace(byte_count=self.files[0].byte_count + 1), *self.files[1:]]

        with self.assertRaisesRegex(ValueError, "ファイルサイズ"):
            self.fetch(files=wrong_size)

    def test_downloaded_hash_mismatch_is_not_published(self) -> None:
        self.by_url[self.files[1].url] = b"different bytes"

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.fetch()

        directory = self.directory()
        self.assertTrue((directory / self.files[0].name).exists())
        self.assertFalse((directory / self.files[1].name).exists())
        self.assertEqual(list(directory.glob("*.download")), [])

    def test_interrupted_download_leaves_no_file_and_the_next_run_recovers(self) -> None:
        class BrokenStream(io.BytesIO):
            def read(self, size: int = -1) -> bytes:
                if self.tell() > 0:
                    raise ConnectionResetError("connection dropped")
                return super().read(4)

        broken_url = self.files[1].url
        real_urlopen = self.urlopen

        def interrupted(url: str, timeout: int):
            if url == broken_url:
                self.fetched_urls.append(url)
                return contextlib.closing(BrokenStream(self.by_url[url]))
            return real_urlopen(url, timeout)

        with mock.patch.object(
            fetcher, "__file__", self.repository / "scripts" / "fetch_community1_diarization.py"
        ), mock.patch.object(
            fetcher.pinned_download.urllib.request, "urlopen", side_effect=interrupted
        ):
            with self.assertRaises(ConnectionResetError):
                fetcher.fetch(self.files, self.key)

        directory = self.directory()
        self.assertFalse((directory / self.files[1].name).exists())
        self.assertEqual(list(directory.glob("*.download")), [])

        self.assertEqual(self.fetch(), directory)
        for file in self.files:
            self.assertEqual((directory / file.name).read_bytes(), self.payloads[file.role])

    def test_stale_partial_temporary_file_from_a_killed_run_is_ignored(self) -> None:
        directory = self.directory()
        directory.mkdir(parents=True)
        stale = directory / f".{self.files[0].name}.abcd1234.download"
        stale.write_bytes(self.payloads["segmentation"][:5])

        result = self.fetch()

        for file in self.files:
            self.assertEqual((result / file.name).read_bytes(), self.payloads[file.role])
        self.assertEqual(stale.read_bytes(), self.payloads["segmentation"][:5])

    def test_repository_path_with_spaces_and_non_ascii(self) -> None:
        repository = self.make_repository("リポジトリ with spaces ü")

        result = self.fetch(repository)

        self.assertEqual(result, self.directory(repository))
        for file in self.files:
            self.assertEqual((result / file.name).read_bytes(), self.payloads[file.role])
        self.assertEqual(self.fetch(repository), result)

    def test_symlinked_cache_directory_escape_is_rejected(self) -> None:
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        build = self.repository / ".build"
        build.mkdir()
        (build / "community1-diarization").symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(RuntimeError, "リポジトリ外|通常のディレクトリ"):
            self.fetch()

        self.assertEqual(list(outside.iterdir()), [])

    def test_cli_rejects_unsupported_python_and_arguments(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_community1_diarization.py"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Python 3.12 以上", stderr.getvalue())
            fetch.assert_not_called()

        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_community1_diarization.py", "--extra"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("引数を受け付けません", stderr.getvalue())
            fetch.assert_not_called()

    def test_cli_prints_only_the_absolute_directory_on_success(self) -> None:
        expected = self.directory()
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_community1_diarization.py"]
        ), mock.patch.object(fetcher, "fetch", return_value=expected):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), f"{expected}\n")
        self.assertEqual(stderr.getvalue(), "")

    def test_cli_reports_failure_on_stderr_with_exit_code_1(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_community1_diarization.py"]
        ), mock.patch.object(fetcher, "fetch", side_effect=OSError("network unavailable")):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("network unavailable", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
