from __future__ import annotations

import stat
import sys
from pathlib import Path

import pinned_download


REPOSITORIES: dict[str, str] = {
    "0.6b": "andrewleech/qwen3-asr-0.6b-onnx",
    "1.7b": "andrewleech/qwen3-asr-1.7b-onnx",
}
COMMITS: dict[str, str] = {
    "0.6b": "4fc24a1402e74db89c4d2ef256875e71680128c4",
    "1.7b": "df916193ac67e59347769891a21e10d81d12acdd",
}
FILES: dict[str, tuple[tuple[str, int, str], ...]] = {
    "0.6b": (
        ("encoder.onnx", 745762694, "3c027f880f677615de85e1f6934906e1d5d77624b724096d33accef99c753eed"),
        ("decoder_init.int4.onnx", 355390, "6d54633bbb9e6b1ecf372f218d04adb3bf6f2bfc442ce55c988526d532896faa"),
        ("decoder_step.int4.onnx", 354888, "7eaa4f31d5eb6ae2937ff45222c32f692f2d5ac29b46cbae9046da332a9f317d"),
        ("decoder_weights.int4.data", 962460672, "d68cd1c0695a7ba42651d06b1bc1158e2e58af5f9adbb6dba874fbbb8a4f22cf"),
        ("embed_tokens.bin", 311164928, "e80150119fa5f7e56e85aed64c3a02d5c78eb7a37cfdcb973d0987316f15bee2"),
        ("tokenizer.json", 11429377, "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"),
    ),
    "1.7b": (
        ("encoder.onnx", 1270241779, "c19ff8d702707693877a509ba1867472b0ad964593b93751091891a143edffec"),
        ("decoder_init.int4.onnx", 356165, "c638585ada629b3cf65ce9cb068b7b980fccc9454a7f05e2333b8813730c1999"),
        ("decoder_step.int4.onnx", 355662, "fa138c025c26f6559e12be51cfbba5204a0b6993a1f3bb1177f80a0a65873bb5"),
        ("decoder_weights.int4.data", 2226321408, "3f8d8fb695bcffc20ce8d8e823471e011404420785adf7678aac31057ef67333"),
        ("embed_tokens.bin", 622329856, "1489075dbd08fcd6b87bc69c5feca278014d29fa5693bd4aa61e47c1a3a160d4"),
        ("tokenizer.json", 11429377, "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"),
    ),
}


def validate_destination(destination: Path) -> Path:
    if not destination.is_absolute():
        raise ValueError(f"保存先は絶対パスで指定してください: {destination}")
    try:
        metadata = destination.stat()
    except (FileNotFoundError, NotADirectoryError) as error:
        raise ValueError(f"保存先ディレクトリがありません: {destination}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"保存先がディレクトリではありません: {destination}")
    return destination.resolve(strict=True)


def fetch(size: str, destination: Path) -> Path:
    if size not in FILES:
        raise ValueError(f"未対応の Qwen3-ASR モデルサイズです: {size}")
    canonical_destination = validate_destination(destination)
    model_name = f"qwen3-asr-{size}-int4-{COMMITS[size]}"
    model_directory = pinned_download.ensure_repository_directory(
        canonical_destination, canonical_destination / model_name
    )

    for filename, expected_size, sha256 in FILES[size]:
        url = (
            f"https://huggingface.co/{REPOSITORIES[size]}/resolve/"
            f"{COMMITS[size]}/{filename}"
        )
        downloaded = pinned_download.download_verified(
            url, sha256, model_directory / filename
        )
        actual_size = downloaded.stat().st_size
        if actual_size != expected_size:
            raise ValueError(
                f"ファイルサイズが一致しません: {downloaded}。"
                f"期待値 {expected_size}、実際 {actual_size}。"
            )
    return model_directory


def main() -> int:
    if sys.version_info < (3, 12):
        print("エラー: Python 3.12 以上が必要です。", file=sys.stderr)
        return 1
    if len(sys.argv) != 3:
        print(
            "使い方: fetch_qwen3_asr_model.py <0.6b|1.7b> <保存先ディレクトリ>",
            file=sys.stderr,
        )
        return 2

    size = sys.argv[1]
    try:
        if size not in FILES:
            raise ValueError(f"未対応の Qwen3-ASR モデルサイズです: {size}")
        destination = validate_destination(Path(sys.argv[2]))
    except ValueError as error:
        print(f"エラー: {error}", file=sys.stderr)
        return 2
    except Exception as error:
        print(
            f"エラー: Qwen3-ASR モデルの取得に失敗しました: {error}",
            file=sys.stderr,
        )
        return 1

    try:
        model_directory = fetch(size, destination)
    except Exception as error:
        print(
            f"エラー: Qwen3-ASR モデルの取得に失敗しました: {error}",
            file=sys.stderr,
        )
        return 1
    print(model_directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
