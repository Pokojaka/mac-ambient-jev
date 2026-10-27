from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_clause_tagger.py")
SPEC = importlib.util.spec_from_file_location("fetch_clause_tagger", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)

REAL_REPOSITORY_ROOT = fetcher.REPOSITORY_ROOT
MANIFEST_PATH = fetcher.MANIFEST_PATH
MANIFEST_COPY_PATH = Path(
    "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json"
)
BASE_MANIFEST = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
PINNED_REPOSITORY = "Pokojaka/modernbert-ja-30m-utterance-tagger"
PINNED_COMMIT = "5c0213592cf8d59fc0b665183ab7536ddde05d1f"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def clone_manifest() -> dict[str, object]:
    return copy.deepcopy(BASE_MANIFEST)


def member_array(manifest: dict[str, object], format: str) -> list[dict[str, object]]:
    key = "members" if format == "onnx" else "coremlMembers"
    return manifest[key]


class ManifestTests(unittest.TestCase):
    def test_fetcher_uses_the_single_bundled_manifest(self) -> None:
        copies = sorted(
            path.relative_to(REAL_REPOSITORY_ROOT)
            for path in REAL_REPOSITORY_ROOT.rglob("clause_tagger_model.json")
            if ".build" not in path.relative_to(REAL_REPOSITORY_ROOT).parts
        )

        self.assertEqual(fetcher.MANIFEST_PATH, REAL_REPOSITORY_ROOT / MANIFEST_COPY_PATH)
        self.assertEqual(copies, [MANIFEST_COPY_PATH])

    def test_malformed_manifest_fields_are_rejected(self) -> None:
        def mutate(format: str, change) -> str:
            manifest = clone_manifest()
            change(manifest, format)
            return json.dumps(manifest)

        cases = [
            ("source repository", "onnx", lambda m, _f: m["source"].update(repository="bad/repo/extra")),
            ("source commit", "onnx", lambda m, _f: m["source"].update(commit="g" * 40)),
            ("model id mismatch", "onnx", lambda m, _f: m["model"].update(id="another/repository")),
            ("missing ONNX role", "onnx", lambda m, f: member_array(m, f).pop()),
            (
                "missing CoreML role",
                "coreml",
                lambda m, f: member_array(m, f).pop(),
            ),
            (
                "duplicate ONNX role",
                "onnx",
                lambda m, f: member_array(m, f).append(dict(member_array(m, f)[0])),
            ),
            (
                "duplicate CoreML role",
                "coreml",
                lambda m, f: member_array(m, f).append(dict(member_array(m, f)[0])),
            ),
            (
                "unknown ONNX role",
                "onnx",
                lambda m, f: member_array(m, f)[0].update(role="unknown"),
            ),
            (
                "unknown CoreML role",
                "coreml",
                lambda m, f: member_array(m, f)[0].update(role="unknown"),
            ),
            (
                "invalid byte count",
                "onnx",
                lambda m, f: member_array(m, f)[0].update(byteCount=0),
            ),
            (
                "boolean byte count",
                "coreml",
                lambda m, f: member_array(m, f)[0].update(byteCount=True),
            ),
            (
                "invalid hash",
                "onnx",
                lambda m, f: member_array(m, f)[0].update(sha256="abc"),
            ),
            (
                "uppercase hash",
                "coreml",
                lambda m, f: member_array(m, f)[0].update(sha256="A" * 64),
            ),
            ("path and name disagree", "onnx", lambda m, f: member_array(m, f)[0].update(path="onnx/other.onnx")),
            (
                "wrong modelLicense name",
                "onnx",
                lambda m, f: next(x for x in member_array(m, f) if x["role"] == "modelLicense").update(name="LICENSE.txt"),
            ),
            (
                "nested ONNX name",
                "onnx",
                lambda m, f: member_array(m, f)[0].update(
                    name="nested/ClauseTagger.onnx", path="onnx/nested/ClauseTagger.onnx"
                ),
            ),
            (
                "tokenizer hash mismatch",
                "coreml",
                lambda m, _f: m["model"].update(tokenizerSHA256="f" * 64),
            ),
            ("onnx object required", "onnx", lambda m, _f: m.update(onnx=None)),
        ]
        for label, format, change in cases:
            with self.subTest(label=label), self.assertRaises(ValueError):
                fetcher.parse_manifest(mutate(format, change), format)

    def test_unsafe_names_and_paths_are_rejected(self) -> None:
        name_cases = {
            "traversal": "../escape",
            "absolute": "/absolute",
            "backslash": "nested\\file",
            "NUL": "bad\x00name",
            "colon": "bad:name",
            "empty component": "nested//file",
        }
        path_cases = {
            "traversal": "onnx/../escape",
            "absolute": "/absolute/file",
            "backslash": "onnx\\file",
            "NUL": "onnx/bad\x00file",
            "colon": "onnx/bad:file",
            "empty component": "onnx//file",
        }
        for label, invalid in name_cases.items():
            manifest = clone_manifest()
            manifest["members"][0]["name"] = invalid
            with self.subTest(field="name", label=label), self.assertRaises(ValueError):
                fetcher.parse_manifest(json.dumps(manifest), "onnx")
        for label, invalid in path_cases.items():
            manifest = clone_manifest()
            manifest["members"][0]["path"] = invalid
            with self.subTest(field="path", label=label), self.assertRaises(ValueError):
                fetcher.parse_manifest(json.dumps(manifest), "onnx")


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = self.make_repository("fixture repository 日本語")
        self.payloads: dict[str, dict[str, bytes]] = {"onnx": {}, "coreml": {}}
        self.manifests = {
            format: self.make_manifest(format) for format in ("onnx", "coreml")
        }
        self.requested_urls: list[str] = []
        self.response_errors: dict[str, BaseException] = {}
        self.response_overrides: dict[str, bytes] = {}

    def make_repository(self, name: str) -> Path:
        repository = Path(self.temporary.name) / name
        repository.mkdir(parents=True, exist_ok=True)
        return repository.resolve()

    def make_manifest(self, format: str) -> fetcher.Manifest:
        raw = clone_manifest()
        for member_format in ("onnx", "coreml"):
            for entry in member_array(raw, member_format):
                payload = f"offline fixture {entry['role']} {entry['name']}".encode("utf-8")
                self.payloads[member_format][entry["name"]] = payload
                entry["byteCount"] = len(payload)
                entry["sha256"] = sha256(payload)
        tokenizer = next(
            entry for entry in member_array(raw, format) if entry["role"] == "tokenizer"
        )
        raw["model"]["tokenizerSHA256"] = tokenizer["sha256"]
        return fetcher.parse_manifest(json.dumps(raw), format)

    def urlopen(self, url: str, timeout: int = 60):
        self.requested_urls.append(url)
        if url in self.response_errors:
            raise self.response_errors[url]
        if url in self.response_overrides:
            return io.BytesIO(self.response_overrides[url])
        for format, manifest in self.manifests.items():
            for member in manifest.members:
                expected_url = (
                    f"https://huggingface.co/{manifest.source.repository}/resolve/"
                    f"{manifest.source.commit}/{member.path}"
                )
                if url == expected_url:
                    return io.BytesIO(self.payloads[format][member.name])
        raise AssertionError(f"Unexpected URL: {url}")

    def fetch(
        self,
        format: str,
        repository: Path | None = None,
        manifest: fetcher.Manifest | None = None,
    ) -> Path:
        repository = self.repository if repository is None else repository
        manifest = self.manifests[format] if manifest is None else manifest
        with mock.patch.object(fetcher, "REPOSITORY_ROOT", repository), mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            side_effect=self.urlopen,
        ):
            return fetcher.fetch(manifest)

    def cache(self, format: str, repository: Path | None = None) -> Path:
        repository = self.repository if repository is None else repository
        return repository / fetcher.CACHE_ROOTS[format] / PINNED_COMMIT

    def destination(self, format: str, repository: Path | None = None) -> Path:
        return self.cache(format, repository) / fetcher.DIRECTORIES[format]

    def write_valid_cache(self, format: str, repository: Path) -> Path:
        destination = self.destination(format, repository)
        for member in self.manifests[format].members:
            path = destination.joinpath(*member.name.split("/"))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self.payloads[format][member.name])
        return destination

    def actual_tree(self, directory: Path) -> tuple[set[str], set[str]]:
        files: set[str] = set()
        directories: set[str] = set()
        for path in directory.rglob("*"):
            relative = path.relative_to(directory).as_posix()
            metadata = path.lstat()
            if stat.S_ISDIR(metadata.st_mode):
                directories.add(relative)
            elif stat.S_ISREG(metadata.st_mode):
                files.add(relative)
            else:
                self.fail(f"Unexpected special entry: {path}")
        return files, directories

    def expected_tree(self, format: str) -> tuple[set[str], set[str]]:
        files = {member.name for member in self.manifests[format].members}
        directories: set[str] = set()
        for member in self.manifests[format].members:
            parts = member.name.split("/")
            directories.update("/".join(parts[:index]) for index in range(1, len(parts)))
        return files, directories

    def assert_failed_fetch_is_clean(
        self, format: str, failed_url: str, failed_name: str
    ) -> None:
        with self.assertRaises(RuntimeError) as raised:
            self.fetch(format)
        message = str(raised.exception)
        self.assertIn(failed_url, message)
        self.assertIn(failed_name, message)
        self.assertEqual(self.requested_urls, [failed_url])
        self.assertFalse(os.path.lexists(self.destination(format)))
        self.assertEqual(list(self.cache(format).glob(".fetch-*")), [])
        self.assertEqual(list(self.cache(format).rglob("*.download")), [])

    def test_both_formats_publish_exact_verified_trees(self) -> None:
        for format in ("onnx", "coreml"):
            with self.subTest(format=format):
                self.requested_urls.clear()
                result = self.fetch(format)
                self.assertEqual(result, self.destination(format))
                self.assertTrue(result.is_absolute())
                self.assertEqual(self.actual_tree(result), self.expected_tree(format))
                for member in self.manifests[format].members:
                    self.assertEqual(
                        result.joinpath(*member.name.split("/")).read_bytes(),
                        self.payloads[format][member.name],
                    )
                expected_urls = [
                    f"https://huggingface.co/{PINNED_REPOSITORY}/resolve/{PINNED_COMMIT}/{member.path}"
                    for member in self.manifests[format].members
                ]
                self.assertEqual(self.requested_urls, expected_urls)
                self.assertEqual(
                    sorted(path.name for path in self.cache(format).iterdir()),
                    [fetcher.DIRECTORIES[format]],
                )

    def test_valid_cache_is_reused_without_network_for_both_formats(self) -> None:
        for format in ("onnx", "coreml"):
            with self.subTest(format=format):
                first = self.fetch(format)
                self.requested_urls.clear()
                second = self.fetch(format)
                self.assertEqual(second, first)
                self.assertEqual(self.requested_urls, [])

    def test_wrong_size_and_same_size_wrong_hash_cache_files_fail(self) -> None:
        for format in ("onnx", "coreml"):
            with self.subTest(format=format):
                self.requested_urls.clear()
                destination = self.fetch(format)
                member = self.manifests[format].members[0]
                path = destination.joinpath(*member.name.split("/"))
                correct = self.payloads[format][member.name]

                path.write_bytes(correct[:-1])
                with self.assertRaisesRegex(ValueError, "ファイルサイズ"):
                    self.fetch(format)

                wrong_same_size = bytes([correct[0] ^ 1]) + correct[1:]
                path.write_bytes(wrong_same_size)
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    self.fetch(format)
                self.assertEqual(self.requested_urls, [
                    f"https://huggingface.co/{PINNED_REPOSITORY}/resolve/{PINNED_COMMIT}/{item.path}"
                    for item in self.manifests[format].members
                ])

    def test_missing_and_extra_files_and_directories_fail_cache_verification(self) -> None:
        mutations = {
            "missing-file": lambda format, destination: destination.joinpath(
                *self.manifests[format].members[0].name.split("/")
            ).unlink(),
            "extra-file": lambda _format, destination: (destination / "extra.bin").write_bytes(b"extra"),
            "extra-directory": lambda _format, destination: (destination / "extra-directory").mkdir(),
        }
        if "ClauseTagger.mlpackage" in {
            member.name.split("/")[0] for member in self.manifests["coreml"].members
        }:
            mutations["missing-directory"] = lambda _format, destination: shutil.rmtree(
                destination / "ClauseTagger.mlpackage"
            )

        for format in ("onnx", "coreml"):
            applicable = [
                (label, mutation)
                for label, mutation in mutations.items()
                if label != "missing-directory" or format == "coreml"
            ]
            for label, mutation in applicable:
                with self.subTest(format=format, mutation=label):
                    repository = self.make_repository(f"cache-{format}-{label}")
                    destination = self.write_valid_cache(format, repository)
                    mutation(format, destination)
                    self.requested_urls.clear()
                    with self.assertRaisesRegex(ValueError, "構成|不足|余分"):
                        self.fetch(format, repository)
                    self.assertEqual(self.requested_urls, [])

    def create_symlink(self, link: Path, target: Path, target_is_directory: bool = False) -> None:
        try:
            link.symlink_to(target, target_is_directory=target_is_directory)
        except (NotImplementedError, OSError) as error:
            self.skipTest(f"Symlinks are unavailable: {error}")

    def test_symlinked_cache_file_and_directory_fail(self) -> None:
        for format in ("onnx", "coreml"):
            for kind in ("file", "directory"):
                with self.subTest(format=format, kind=kind):
                    repository = self.make_repository(f"symlink-{format}-{kind}")
                    destination = self.write_valid_cache(format, repository)
                    outside = Path(self.temporary.name) / f"outside-{format}-{kind}"
                    if kind == "file":
                        outside.write_bytes(b"outside target")
                        member = self.manifests[format].members[0]
                        target_path = destination.joinpath(*member.name.split("/"))
                        target_path.unlink()
                        self.create_symlink(target_path, outside)
                    else:
                        outside.mkdir()
                        self.create_symlink(destination / "linked-directory", outside, True)
                    self.requested_urls.clear()
                    with self.assertRaisesRegex(ValueError, "通常ファイルまたは通常ディレクトリ"):
                        self.fetch(format, repository)
                    self.assertEqual(self.requested_urls, [])

    def test_symlinked_cache_root_escape_fails(self) -> None:
        for format in ("onnx", "coreml"):
            with self.subTest(format=format):
                repository = self.make_repository(f"cache-escape-{format}")
                cache_root = repository / fetcher.CACHE_ROOTS[format]
                cache_root.parent.mkdir(parents=True, exist_ok=True)
                outside = Path(self.temporary.name) / f"outside-cache-{format}"
                outside.mkdir()
                self.create_symlink(cache_root, outside, True)
                with self.assertRaisesRegex(RuntimeError, "通常のディレクトリ"):
                    self.fetch(format, repository)
                self.assertEqual(list(outside.iterdir()), [])

    def test_http_and_network_failures_do_not_publish_or_retry(self) -> None:
        errors = {
            "HTTP": lambda url: urllib.error.HTTPError(
                url, 503, "offline server", {}, io.BytesIO(b"unavailable")
            ),
            "network": lambda _url: urllib.error.URLError("network unavailable"),
        }
        for format in ("onnx", "coreml"):
            member = self.manifests[format].members[0]
            url = (
                f"https://huggingface.co/{PINNED_REPOSITORY}/resolve/"
                f"{PINNED_COMMIT}/{member.path}"
            )
            for label, make_error in errors.items():
                with self.subTest(format=format, error=label):
                    self.requested_urls.clear()
                    self.response_errors = {url: make_error(url)}
                    self.assert_failed_fetch_is_clean(format, url, member.name)
                    self.response_errors.clear()

    def test_hash_mismatch_does_not_publish_or_retry(self) -> None:
        for format in ("onnx", "coreml"):
            member = self.manifests[format].members[0]
            url = (
                f"https://huggingface.co/{PINNED_REPOSITORY}/resolve/"
                f"{PINNED_COMMIT}/{member.path}"
            )
            correct = self.payloads[format][member.name]
            wrong = bytes([correct[0] ^ 1]) + correct[1:]
            with self.subTest(format=format):
                self.requested_urls.clear()
                self.response_overrides = {url: wrong}
                self.assert_failed_fetch_is_clean(format, url, member.name)
                self.response_overrides.clear()

    def test_size_mismatch_with_matching_download_hash_does_not_publish_or_retry(self) -> None:
        for format in ("onnx", "coreml"):
            base = self.manifests[format]
            first = base.members[0]
            wrong_size_member = first._replace(byte_count=first.byte_count + 1)
            altered_manifest = base._replace(members=[wrong_size_member, *base.members[1:]])
            url = (
                f"https://huggingface.co/{PINNED_REPOSITORY}/resolve/"
                f"{PINNED_COMMIT}/{first.path}"
            )
            with self.subTest(format=format):
                self.requested_urls.clear()
                with self.assertRaises(RuntimeError) as raised:
                    self.fetch(format, manifest=altered_manifest)
                self.assertIn(url, str(raised.exception))
                self.assertIn(first.name, str(raised.exception))
                self.assertEqual(self.requested_urls, [url])
                self.assertFalse(os.path.lexists(self.destination(format)))
                self.assertEqual(list(self.cache(format).glob(".fetch-*")), [])
                self.assertEqual(list(self.cache(format).rglob("*.download")), [])

    def test_cli_requires_supported_python_and_format_arguments(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py", "--format", "onnx"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Python 3.12 以上", stderr.getvalue())
            fetch.assert_not_called()

        invalid_arguments = [
            [],
            ["--format", "unknown"],
            ["--format", "onnx", "--extra"],
        ]
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher, "fetch"
        ) as fetch:
            for arguments in invalid_arguments:
                with self.subTest(arguments=arguments):
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with mock.patch.object(
                        fetcher.sys, "argv", ["fetch_clause_tagger.py", *arguments]
                    ), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as raised:
                            fetcher.main()
                    self.assertNotEqual(raised.exception.code, 0)
                    self.assertEqual(stdout.getvalue(), "")
                    fetch.assert_not_called()

    def test_cli_success_prints_only_destination_path(self) -> None:
        expected = self.destination("onnx")
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py", "--format", "onnx"]
        ), mock.patch.object(fetcher, "load_manifest", return_value=self.manifests["onnx"]), mock.patch.object(
            fetcher, "fetch", return_value=expected
        ):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), f"{expected}\n")
        self.assertEqual(stderr.getvalue(), "")

    def test_cli_failure_reports_stderr_and_no_stdout(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py", "--format", "coreml"]
        ), mock.patch.object(fetcher, "load_manifest", return_value=self.manifests["coreml"]), mock.patch.object(
            fetcher, "fetch", side_effect=RuntimeError("network unavailable")
        ):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("network unavailable", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
