from __future__ import annotations

import hashlib
import json
import pathlib
import tempfile
import urllib.request
from typing import Any


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("unsupported schema_version")
    if not data.get("id"):
        raise ValueError("manifest id is required")
    resources = data.get("resources")
    if not isinstance(resources, list):
        raise ValueError("resources must be a list")
    return data


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_resource(
    resource: dict[str, Any],
    *,
    cache_root: pathlib.Path,
) -> pathlib.Path:
    expected = resource.get("sha256")
    if not isinstance(expected, str) or len(expected) != 64:
        raise ValueError(
            "resource sha256 must be a 64-character hex string"
        )
    try:
        int(expected, 16)
    except ValueError as exc:
        raise ValueError(
            "resource sha256 must be hexadecimal"
        ) from exc

    url = resource.get("url")
    filename = resource.get("filename")
    if not isinstance(url, str) or not url:
        raise ValueError("resource url is required")
    if not isinstance(filename, str) or not filename:
        raise ValueError("resource filename is required")

    cache_root.mkdir(parents=True, exist_ok=True)
    destination = cache_root / filename
    if destination.exists():
        if _sha256(destination) == expected:
            return destination
        destination.unlink()

    fd, temp_name = tempfile.mkstemp(
        prefix=filename + ".",
        suffix=".download",
        dir=cache_root,
    )
    temp_path = pathlib.Path(temp_name)
    try:
        with urllib.request.urlopen(url) as response, open(
            fd, "wb", closefd=True
        ) as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        actual = _sha256(temp_path)
        if actual != expected:
            raise ValueError(
                f"SHA-256 mismatch for "
                f"{resource.get('name', filename)}: "
                f"expected {expected}, got {actual}"
            )
        temp_path.replace(destination)
        return destination
    except Exception:
        temp_path.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        raise
