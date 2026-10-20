from __future__ import annotations

import sys
from pathlib import Path

import pinned_download


REPOSITORY_ID = "andrewleech/qwen3-asr-1.7b-onnx"
COMMIT = "df916193ac67e59347769891a21e10d81d12acdd"
FILENAME = "tokenizer.json"
SHA256 = "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"
URL = f"https://huggingface.co/{REPOSITORY_ID}/resolve/{COMMIT}/{FILENAME}"


def fetch() -> Path:
    repository = Path(__file__).resolve().parent.parent
    cache = pinned_download.ensure_repository_directory(
        repository, repository / ".build" / "qwen3-asr-tokenizer" / COMMIT
    )
    return pinned_download.download_verified(URL, SHA256, cache / FILENAME)


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
        print(f"エラー: Qwen3-ASR の tokenizer.json の取得に失敗しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
