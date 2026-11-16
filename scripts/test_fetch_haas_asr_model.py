from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("fetch_haas_asr_model.py")
SPEC = importlib.util.spec_from_file_location("fetch_haas_asr_model", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name) / "destination").resolve()

    def test_bundled_manifest_repository_commit_and_files(self) -> None:
        metadata = fetcher.MODEL_METADATA
        self.assertEqual(metadata["repository"], "Sanami/haas-ja-onnx")
        self.assertEqual(metadata["commit"], "354baedfd9612b00e74cc1ae87dff7f2c558db6f")
        files = metadata["files"]
        self.assertEqual(
            [file["name"] for file in files],
            [
                "int8dyn/encoder.onnx",
                "int8dyn/encoder.onnx.data",
                "int8dyn/decoder_joint.onnx",
                "int8dyn/decoder_joint.onnx.data",
                "tokenizer.model",
                "LICENSE",
                "NOTICE",
            ],
        )
        for file in files:
            self.assertIsInstance(file["byteCount"], int)
            self.assertGreater(file["byteCount"], 0)
            self.assertRegex(file["sha256"], re.compile(r"^[0-9a-f]{64}$"))

    def test_downloads_nested_files_and_reuses_verified_files(self) -> None:
        repository, commit = "test/repository", "test-commit"
        payloads = (("encoder/model.onnx", b"encoder"), ("tokenizer.model", b"tokens"))
        metadata = {
            "repository": repository,
            "commit": commit,
            "files": [
                {"name": name, "byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                for name, data in payloads
            ],
        }
        urls = [
            f"https://huggingface.co/{repository}/resolve/{commit}/{name}"
            for name, _data in payloads
        ]
        with mock.patch.object(fetcher, "MODEL_METADATA", metadata), mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            side_effect=[contextlib.closing(io.BytesIO(data)) for _name, data in payloads],
        ) as urlopen:
            self.assertEqual(fetcher.fetch(self.root), self.root)
            self.assertEqual(fetcher.fetch(self.root), self.root)
        self.assertEqual([call.args[0] for call in urlopen.call_args_list], urls)
        self.assertEqual(urlopen.call_count, 2)
        for name, data in payloads:
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_downloaded_hash_mismatch_is_not_published(self) -> None:
        payload = b"wrong payload"
        metadata = {
            "repository": "test/repository",
            "commit": "test-commit",
            "files": [{"name": "nested/model.onnx", "byteCount": len(payload), "sha256": hashlib.sha256(b"expected").hexdigest()}],
        }
        target = self.root / "nested/model.onnx"
        with mock.patch.object(fetcher, "MODEL_METADATA", metadata), mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(payload)),
        ):
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                fetcher.fetch(self.root)
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.glob(".model.onnx.*.download")), [])

    def test_wrong_download_size_is_rejected(self) -> None:
        payload = b"tiny payload"
        metadata = {
            "repository": "test/repository",
            "commit": "test-commit",
            "files": [{"name": "model.onnx", "byteCount": len(payload) + 1, "sha256": hashlib.sha256(payload).hexdigest()}],
        }
        with mock.patch.object(fetcher, "MODEL_METADATA", metadata), mock.patch.object(
            fetcher.pinned_download.urllib.request,
            "urlopen",
            return_value=contextlib.closing(io.BytesIO(payload)),
        ):
            with self.assertRaisesRegex(ValueError, "ファイルサイズが一致しません"):
                fetcher.fetch(self.root)


if __name__ == "__main__":
    unittest.main()
