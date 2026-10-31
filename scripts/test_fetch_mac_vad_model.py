from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("fetch_mac_vad_model.py")
SPEC = importlib.util.spec_from_file_location("fetch_mac_vad_model", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


class FetchTests(unittest.TestCase):
    def test_downloads_each_manifest_file_into_the_models_layout(self) -> None:
        payload = b"stand-in vad file"
        manifest = {
            "vad": {
                "repository": "owner/vad",
                "commit": "abc123",
                "files": [{
                    "name": "m.mlmodelc/weights/weight.bin",
                    "role": "vad_weights",
                    "byteCount": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }],
            }
        }
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve() / "repository"
            (repository / "scripts").mkdir(parents=True)
            manifest_path = repository / "mac_models.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with mock.patch.object(fetcher, "__file__", repository / "scripts" / "fetch_mac_vad_model.py"), \
                    mock.patch.object(fetcher, "MANIFEST", manifest_path), \
                    mock.patch.object(
                        fetcher.pinned_download.urllib.request, "urlopen",
                        return_value=contextlib.closing(io.BytesIO(payload)),
                    ) as download:
                root = fetcher.fetch()

            self.assertEqual(root, repository / ".build" / "mac-test-models" / "abc123")
            stored = root / "mac-ambient-jev/models" / fetcher.VAD_DIRECTORY / "m.mlmodelc/weights/weight.bin"
            self.assertEqual(stored.read_bytes(), payload)
            download.assert_called_once_with(
                "https://huggingface.co/owner/vad/resolve/abc123/m.mlmodelc/weights/weight.bin", timeout=60
            )


if __name__ == "__main__":
    unittest.main()
