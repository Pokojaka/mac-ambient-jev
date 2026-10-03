import hashlib
import json

import pytest

from common.corpus import load_manifest, prepare_resource


def test_manifest_rejects_unknown_schema(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(
        json.dumps({
            "schema_version": 2,
            "id": "bad",
            "resources": [],
        }),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="schema_version"):
        load_manifest(path)


def test_prepare_resource_accepts_verified_cache(tmp_path):
    payload = b"fixture-data"
    digest = hashlib.sha256(payload).hexdigest()
    cache = tmp_path / "cache"
    cache.mkdir()
    destination = cache / "fixture.bin"
    destination.write_bytes(payload)

    result = prepare_resource(
        {
            "url": "unused",
            "filename": "fixture.bin",
            "sha256": digest,
        },
        cache_root=cache,
    )

    assert result == destination
    assert result.read_bytes() == payload


def test_prepare_resource_requires_locked_sha256(tmp_path):
    with pytest.raises(ValueError, match="sha256"):
        prepare_resource(
            {
                "url": "unused",
                "filename": "fixture.bin",
            },
            cache_root=tmp_path / "cache",
        )


def test_prepare_resource_rejects_cached_file_with_wrong_hash(tmp_path):
    cache = tmp_path / "cache"
    cache.mkdir()
    destination = cache / "fixture.bin"
    destination.write_bytes(b"tampered")

    with pytest.raises(ValueError, match="SHA-256"):
        prepare_resource(
            {
                "url": "unused",
                "filename": "fixture.bin",
                "sha256": hashlib.sha256(b"original").hexdigest(),
            },
            cache_root=cache,
        )
    assert destination.read_bytes() == b"tampered"
