from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_clause_tagger.py")
SPEC = importlib.util.spec_from_file_location("fetch_clause_tagger", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)

REPOSITORY = Path(__file__).resolve().parent.parent
SWIFT_MANIFEST = (
    REPOSITORY
    / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json"
)

MEMBER_PINS = {
    "model": ("ClauseTagger.onnx", 146_889_561, "8f9e7d3e4f72f2b7d18db1c59bac6b9506d135f976512ae8afbff1386687b699"),
    "tokenizer": ("tokenizer.json", 6_724_873, "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"),
    "export": ("export.json", 253_705, "2d8d8e8585f9d34476d4e1377c8bcf90f47004c1aa4a7efe05f7d05acd292627"),
    "license": ("LICENSE.txt", 1_292, "2e97bfc46df586a08bb5942dc2af608d1aced6023735f65797d0ced0ba7fd77a"),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ManifestTests(unittest.TestCase):
    def test_script_reads_the_manifest_file_the_swift_target_bundles(self) -> None:
        self.assertEqual(fetcher.MANIFEST_PATH, SWIFT_MANIFEST)
        copies = [
            path
            for path in REPOSITORY.rglob("clause_tagger_model.json")
            if ".build" not in path.relative_to(REPOSITORY).parts
        ]
        self.assertEqual(copies, [SWIFT_MANIFEST])

    def test_pins(self) -> None:
        release, members = fetcher.load_manifest()

        self.assertEqual(release.repository, "Pokojaka/mac-ambient-jev")
        self.assertEqual(release.tag, "clause-tagger-onnx-90501ea3-v1")
        self.assertEqual(release.asset, "clause-tagger-onnx-90501ea3-v1.tar.gz")
        self.assertEqual(release.byte_count, 110_829_019)
        self.assertEqual(
            release.sha256, "95985c53bacb0feea79b1f627864026cd22767f44eaf330eb0e5a0b4887ac30d"
        )
        self.assertEqual(release.directory, "clause-tagger-onnx")
        self.assertEqual(
            release.url,
            "https://github.com/Pokojaka/mac-ambient-jev/releases/download/"
            "clause-tagger-onnx-90501ea3-v1/clause-tagger-onnx-90501ea3-v1.tar.gz",
        )
        self.assertEqual([member.role for member in members], list(fetcher.ROLES))
        for member in members:
            name, byte_count, digest = MEMBER_PINS[member.role]
            self.assertEqual((member.name, member.byte_count, member.sha256), (name, byte_count, digest))

    def test_invalid_manifests_are_rejected(self) -> None:
        valid = json.loads(SWIFT_MANIFEST.read_text(encoding="utf-8"))

        def mutated(change) -> str:
            copy = json.loads(json.dumps(valid))
            change(copy)
            return json.dumps(copy)

        cases = {
            "schema version": lambda m: m.update(schemaVersion=2),
            "missing role": lambda m: m["members"].pop(),
            "duplicate role": lambda m: m["members"].append(dict(m["members"][0])),
            "unknown role": lambda m: m["members"][0].update(role="other"),
            "duplicate name": lambda m: m["members"][1].update(name=m["members"][0]["name"]),
            "path in name": lambda m: m["members"][0].update(name="../escape.onnx"),
            "backslash in name": lambda m: m["members"][0].update(name="a\\b"),
            "short sha": lambda m: m["members"][0].update(sha256="abc"),
            "uppercase sha": lambda m: m["members"][0].update(sha256=m["members"][0]["sha256"].upper()),
            "zero size": lambda m: m["members"][0].update(byteCount=0),
            "release zero size": lambda m: m["release"].update(byteCount=0),
            "release path in asset": lambda m: m["release"].update(asset="a/b.tar.gz"),
            "release short sha": lambda m: m["release"].update(sha256="abc"),
            "tokenizer differs from model": lambda m: m["model"].update(tokenizerSHA256="a" * 64),
        }
        for name, change in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                fetcher.parse_manifest(mutated(change))


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = self.make_repository("repository")
        self.payloads = {
            role: f"offline {role} fixture".encode() * (role == "model" and 50 or 1)
            for role in fetcher.ROLES
        }
        self.members = [
            fetcher.Member(role, MEMBER_PINS[role][0], len(self.payloads[role]), sha256(self.payloads[role]))
            for role in fetcher.ROLES
        ]
        self.fetched_urls: list[str] = []
        self.archive_bytes = self.build_archive()
        self.manifest = self.make_manifest(self.archive_bytes)

    def make_repository(self, name: str) -> Path:
        repository = Path(self.temporary.name) / name
        (repository / "scripts").mkdir(parents=True)
        return repository.resolve()

    def make_manifest(self, archive: bytes) -> fetcher.Manifest:
        release = fetcher.Release(
            "example/repository",
            "clause-tagger-onnx-fixture-v1",
            "clause-tagger-onnx-fixture-v1.tar.gz",
            len(archive),
            sha256(archive),
            "clause-tagger-onnx",
        )
        return fetcher.Manifest(release, self.members)

    def build_archive(self, entries=None, directory_entry: bool = True) -> bytes:
        """`entries` is a list of (name, payload or TarInfo-customizing callable) pairs."""
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            if directory_entry:
                info = tarfile.TarInfo("clause-tagger-onnx")
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                archive.addfile(info)
            if entries is None:
                entries = [(f"clause-tagger-onnx/{m.name}", self.payloads[m.role]) for m in self.members]
            for name, payload in entries:
                info = tarfile.TarInfo(name)
                if callable(payload):
                    data = payload(info)
                else:
                    data = payload
                    info.size = len(data)
                archive.addfile(info, io.BytesIO(data) if data is not None else None)
        return buffer.getvalue()

    def urlopen(self, url: str, timeout: int):
        self.fetched_urls.append(url)
        return contextlib.closing(io.BytesIO(self.archive_bytes))

    def fetch(self, repository: Path | None = None, manifest=None) -> Path:
        repository = repository or self.repository
        with mock.patch.object(
            fetcher, "__file__", repository / "scripts" / "fetch_clause_tagger.py"
        ), mock.patch.object(
            fetcher.pinned_download.urllib.request, "urlopen", side_effect=self.urlopen
        ):
            return fetcher.fetch(manifest or self.manifest)

    def cache(self, repository: Path | None = None) -> Path:
        return (repository or self.repository) / ".build" / "clause-tagger-onnx" / self.manifest.release.tag

    def use_archive(self, archive: bytes) -> fetcher.Manifest:
        self.archive_bytes = archive
        return self.make_manifest(archive)

    def assert_nothing_published(self) -> None:
        cache = self.cache()
        self.assertFalse((cache / "clause-tagger-onnx").exists())
        self.assertEqual(list(cache.glob(".extract-*")), [])

    def test_publishes_the_four_members_and_removes_the_archive(self) -> None:
        result = self.fetch()

        self.assertTrue(result.is_absolute())
        self.assertEqual(result, self.cache() / "clause-tagger-onnx")
        self.assertEqual(self.fetched_urls, [self.manifest.release.url])
        for member in self.members:
            self.assertEqual((result / member.name).read_bytes(), self.payloads[member.role])
        self.assertEqual(sorted(path.name for path in result.iterdir()), sorted(m.name for m in self.members))
        self.assertEqual([path.name for path in self.cache().iterdir()], ["clause-tagger-onnx"])

    def test_archive_without_a_directory_entry_is_accepted(self) -> None:
        manifest = self.use_archive(self.build_archive(directory_entry=False))

        result = self.fetch(manifest=manifest)

        for member in self.members:
            self.assertEqual((result / member.name).read_bytes(), self.payloads[member.role])

    def test_existing_valid_cache_short_circuits_without_network(self) -> None:
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

    def test_corrupt_existing_member_is_rejected_without_download_or_overwrite(self) -> None:
        directory = self.cache() / "clause-tagger-onnx"
        directory.mkdir(parents=True)
        for member in self.members:
            (directory / member.name).write_bytes(self.payloads[member.role])
        corrupt = directory / self.members[1].name
        corrupt.write_bytes(b"x" * len(self.payloads["tokenizer"]))

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.fetch()

        self.assertEqual(corrupt.read_bytes(), b"x" * len(self.payloads["tokenizer"]))
        self.assertEqual(self.fetched_urls, [])

    def test_existing_cache_with_wrong_size_missing_or_extra_member_is_rejected(self) -> None:
        directory = self.cache() / "clause-tagger-onnx"
        directory.mkdir(parents=True)
        for member in self.members:
            (directory / member.name).write_bytes(self.payloads[member.role])

        (directory / self.members[0].name).write_bytes(b"short")
        with self.assertRaisesRegex(ValueError, "ファイルサイズ"):
            self.fetch()
        (directory / self.members[0].name).write_bytes(self.payloads["model"])

        (directory / "extra.bin").write_bytes(b"extra")
        with self.assertRaisesRegex(ValueError, "余分"):
            self.fetch()
        (directory / "extra.bin").unlink()

        (directory / self.members[2].name).unlink()
        with self.assertRaisesRegex(ValueError, "不足"):
            self.fetch()
        self.assertEqual(self.fetched_urls, [])

    def test_existing_cache_member_that_is_a_symlink_is_rejected(self) -> None:
        directory = self.cache() / "clause-tagger-onnx"
        directory.mkdir(parents=True)
        for member in self.members:
            (directory / member.name).write_bytes(self.payloads[member.role])
        target = Path(self.temporary.name) / "outside.bin"
        target.write_bytes(self.payloads["license"])
        (directory / self.members[3].name).unlink()
        (directory / self.members[3].name).symlink_to(target)

        with self.assertRaisesRegex(ValueError, "通常ファイル"):
            self.fetch()

    def test_downloaded_archive_hash_mismatch_is_not_published(self) -> None:
        self.archive_bytes = self.archive_bytes[:-1] + bytes([self.archive_bytes[-1] ^ 1])

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.fetch()

        self.assert_nothing_published()
        self.assertEqual(list(self.cache().glob("*.download")), [])
        self.assertFalse((self.cache() / self.manifest.release.asset).exists())

    def test_archive_size_mismatch_with_matching_hash_is_rejected(self) -> None:
        release = self.manifest.release._replace(byte_count=self.manifest.release.byte_count + 1)

        with self.assertRaisesRegex(ValueError, "アーカイブのサイズ"):
            self.fetch(manifest=fetcher.Manifest(release, self.members))

        self.assert_nothing_published()

    def test_existing_corrupt_archive_is_rejected_not_redownloaded(self) -> None:
        self.cache().mkdir(parents=True)
        stale = self.cache() / self.manifest.release.asset
        stale.write_bytes(b"corrupt archive")

        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.fetch()

        self.assertEqual(stale.read_bytes(), b"corrupt archive")
        self.assertEqual(self.fetched_urls, [])

    def test_stale_extract_directory_from_a_killed_run_is_removed(self) -> None:
        stale = self.cache() / ".extract-killed"
        stale.mkdir(parents=True)
        (stale / "partial").write_bytes(b"partial")

        result = self.fetch()

        self.assertFalse(stale.exists())
        self.assertEqual(sorted(path.name for path in result.iterdir()), sorted(m.name for m in self.members))

    def reject_archive(self, archive: bytes, pattern: str) -> None:
        shutil.rmtree(self.cache(), ignore_errors=True)
        manifest = self.use_archive(archive)
        with self.assertRaisesRegex(ValueError, pattern):
            self.fetch(manifest=manifest)
        self.assert_nothing_published()

    def member_entries(self) -> list[tuple[str, bytes]]:
        return [(f"clause-tagger-onnx/{m.name}", self.payloads[m.role]) for m in self.members]

    def test_malicious_archive_paths_are_rejected(self) -> None:
        first = self.member_entries()[0]
        cases = {
            "traversal": f"clause-tagger-onnx/../{self.members[0].name}",
            "absolute": f"/clause-tagger-onnx/{self.members[0].name}",
            "backslash": f"clause-tagger-onnx\\{self.members[0].name}",
            "dot segment": f"clause-tagger-onnx/./{self.members[0].name}",
            "wrong root": f"other/{self.members[0].name}",
            "nested": f"clause-tagger-onnx/sub/{self.members[0].name}",
            "no root": self.members[0].name,
        }
        for label, name in cases.items():
            with self.subTest(label):
                self.reject_archive(
                    self.build_archive([(name, first[1]), *self.member_entries()[1:]]),
                    "アーカイブ内パス",
                )

    def test_links_and_special_entries_are_rejected(self) -> None:
        for label, kind in (
            ("symlink", tarfile.SYMTYPE),
            ("hardlink", tarfile.LNKTYPE),
            ("fifo", tarfile.FIFOTYPE),
            ("chardev", tarfile.CHRTYPE),
        ):
            def link(info: tarfile.TarInfo, kind=kind) -> None:
                info.type = kind
                info.linkname = "/etc/passwd"
                return None

            with self.subTest(label):
                entries = [*self.member_entries()[:-1], (f"clause-tagger-onnx/{self.members[3].name}", link)]
                self.reject_archive(self.build_archive(entries), "通常ファイル以外")

    def test_duplicate_unexpected_and_missing_members_are_rejected(self) -> None:
        entries = self.member_entries()
        self.reject_archive(self.build_archive([*entries, entries[0]]), "重複")
        self.reject_archive(
            self.build_archive([*entries, ("clause-tagger-onnx/NOTICE.txt", b"notice")]), "想定外"
        )
        self.reject_archive(self.build_archive(entries[:-1]), "必要なファイルがありません")
        self.reject_archive(
            self.build_archive([("clause-tagger-onnx/extra/", lambda info: setattr(info, "type", tarfile.DIRTYPE))]),
            "想定外",
        )

    def test_oversize_and_undersize_members_are_rejected(self) -> None:
        entries = self.member_entries()
        self.reject_archive(
            self.build_archive([(entries[0][0], self.payloads["model"] + b"x"), *entries[1:]]),
            "サイズ",
        )
        self.reject_archive(
            self.build_archive([(entries[0][0], self.payloads["model"][:-1]), *entries[1:]]),
            "サイズ",
        )

    def test_same_size_wrong_content_member_is_rejected(self) -> None:
        entries = self.member_entries()
        wrong = bytes(byte ^ 0xFF for byte in self.payloads["export"])

        self.reject_archive(self.build_archive([*entries[:2], (entries[2][0], wrong), entries[3]]), "SHA-256")

    def test_repository_path_with_spaces_and_non_ascii(self) -> None:
        repository = self.make_repository("リポジトリ with spaces ü")

        result = self.fetch(repository)

        self.assertEqual(result, self.cache(repository) / "clause-tagger-onnx")
        for member in self.members:
            self.assertEqual((result / member.name).read_bytes(), self.payloads[member.role])
        self.assertEqual(self.fetch(repository), result)

    def test_symlinked_cache_directory_escape_is_rejected(self) -> None:
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        build = self.repository / ".build"
        build.mkdir()
        (build / "clause-tagger-onnx").symlink_to(outside, target_is_directory=True)

        with self.assertRaisesRegex(RuntimeError, "リポジトリ外|通常のディレクトリ"):
            self.fetch()

        self.assertEqual(list(outside.iterdir()), [])

    def test_cli_rejects_unsupported_python_and_arguments(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 11, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("Python 3.12 以上", stderr.getvalue())
            fetch.assert_not_called()

        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py", "--extra"]
        ), mock.patch.object(fetcher, "fetch") as fetch:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()
            self.assertEqual(code, 2)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("引数を受け付けません", stderr.getvalue())
            fetch.assert_not_called()

    def test_cli_prints_only_the_absolute_directory_on_success(self) -> None:
        expected = self.cache() / "clause-tagger-onnx"
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py"]
        ), mock.patch.object(fetcher, "fetch", return_value=expected):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 0)
        self.assertEqual(stdout.getvalue(), f"{expected}\n")
        self.assertEqual(stderr.getvalue(), "")

    def test_cli_reports_failure_on_stderr_with_exit_code_1(self) -> None:
        with mock.patch.object(fetcher.sys, "version_info", (3, 12, 0)), mock.patch.object(
            fetcher.sys, "argv", ["fetch_clause_tagger.py"]
        ), mock.patch.object(fetcher, "fetch", side_effect=OSError("network unavailable")):
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = fetcher.main()

        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("network unavailable", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
