from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import pinned_download


MODEL_METADATA = json.loads(
    (
        Path(__file__).resolve().parent.parent
        / "app/MacAmbientJev/Sources/MacAmbientJevHaasASR/Resources/haas_asr_model.json"
    ).read_text(encoding="utf-8")
)


def fetch(destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve(strict=True)
    for file in MODEL_METADATA["files"]:
        name = file["name"]
        target = root / name
        pinned_download.ensure_repository_directory(root, target.parent)
        url = (
            f"https://huggingface.co/{MODEL_METADATA['repository']}/resolve/"
            f"{MODEL_METADATA['commit']}/{name}"
        )
        downloaded = pinned_download.download_verified(url, file["sha256"], target)
        actual_size = downloaded.stat().st_size
        if actual_size != file["byteCount"]:
            raise ValueError(
                f"ファイルサイズが一致しません: {downloaded}。"
                f"期待値 {file['byteCount']}、実際 {actual_size}。"
            )
    return root


def main() -> int:
    parser = argparse.ArgumentParser(description="Haas ASR モデルを取得します")
    parser.add_argument("--destination", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        root = fetch(arguments.destination)
    except Exception as error:
        print(f"エラー: Haas ASR モデルの取得に失敗しました: {error}", file=sys.stderr)
        return 1
    print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
