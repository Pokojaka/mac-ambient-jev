from __future__ import annotations

import json
import sys
from pathlib import Path

import pinned_download

MANIFEST = Path(__file__).resolve().parent.parent / (
    "app/MacAmbientJev/Sources/MacAmbientJevRuntime/Resources/mac_models.json"
)
# The VAD model's directory under `models`; `MacModel.vad.relativeDirectory` in MacModelStore.swift
# is the same string, and the VAD parity test fails when they differ.
VAD_DIRECTORY = "fluidaudio-silero-vad"


def fetch() -> Path:
    """Downloads the pinned VAD files named in mac_models.json and returns the application-support
    root that `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` takes."""
    entry = json.loads(MANIFEST.read_text(encoding="utf-8"))["vad"]
    repository = Path(__file__).resolve().parent.parent
    root = pinned_download.ensure_repository_directory(
        repository, repository / ".build" / "mac-test-models" / entry["commit"]
    )
    models = pinned_download.ensure_repository_directory(
        repository, root / "mac-ambient-jev" / "models" / VAD_DIRECTORY
    )
    for file in entry["files"]:
        parent = pinned_download.ensure_repository_directory(
            repository, (models / file["name"]).parent
        )
        url = f"https://huggingface.co/{entry['repository']}/resolve/{entry['commit']}/{file['name']}"
        downloaded = pinned_download.download_verified(url, file["sha256"], parent / Path(file["name"]).name)
        if downloaded.stat().st_size != file["byteCount"]:
            raise ValueError(f"サイズが一致しません: {downloaded}")
    return root


def main() -> int:
    if sys.version_info < (3, 12):
        print("エラー: Python 3.12 以上が必要です。", file=sys.stderr)
        return 1
    if len(sys.argv) != 1:
        print("エラー: このコマンドは引数を受け付けません。", file=sys.stderr)
        return 2
    try:
        print(fetch())
    except Exception as error:
        print(f"エラー: VAD モデルの取得に失敗しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
