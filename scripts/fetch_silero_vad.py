from __future__ import annotations

import sys
from pathlib import Path

import pinned_download


COMMIT = "5cd7945676eb32225748052e2e6a0580e4686a08"
MODEL_FILENAME = "silero_vad_16k_op15.onnx"
SHA256 = "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"
MODEL_URL = f"https://raw.githubusercontent.com/snakers4/silero-vad/{COMMIT}/src/silero_vad/data/{MODEL_FILENAME}"


def fetch() -> Path:
    repository = Path(__file__).resolve().parent.parent
    cache = pinned_download.ensure_repository_directory(
        repository, repository / ".build" / "silero-vad" / COMMIT
    )
    return pinned_download.download_verified(MODEL_URL, SHA256, cache / MODEL_FILENAME)


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
        print(f"エラー: Silero VAD モデルの取得に失敗しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
