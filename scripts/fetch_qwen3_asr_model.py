from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

import pinned_download


MODEL_METADATA = json.loads(
    (
        Path(__file__).resolve().parent.parent
        / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/qwen3_asr_models.json"
    ).read_text(encoding="utf-8")
)
FILE_ROLES = (
    "encoder",
    "decoder_init",
    "decoder_step",
    "decoder_weights",
    "embed_tokens",
    "tokenizer",
)


def files_by_role(metadata: dict) -> dict[str, dict[str, tuple[str, int, str]]]:
    files: dict[str, dict[str, tuple[str, int, str]]] = {}
    supported_roles = set(FILE_ROLES)
    for size, model in metadata.items():
        role_files: dict[str, tuple[str, int, str]] = {}
        for file in model["files"]:
            if "role" not in file:
                raise ValueError(f"モデルサイズ {size} のファイルに role がありません")
            role = file["role"]
            if not isinstance(role, str):
                raise ValueError(
                    f"モデルサイズ {size} の role は文字列である必要があります: {role!r}"
                )
            if role not in supported_roles:
                raise ValueError(f"モデルサイズ {size} の未対応 role です: {role}")
            if role in role_files:
                raise ValueError(f"モデルサイズ {size} の role が重複しています: {role}")
            role_files[role] = (file["name"], file["byteCount"], file["sha256"])

        missing_roles = [role for role in FILE_ROLES if role not in role_files]
        if missing_roles:
            raise ValueError(
                f"モデルサイズ {size} に必要な role がありません: "
                f"{', '.join(missing_roles)}"
            )
        files[size] = {role: role_files[role] for role in FILE_ROLES}
    return files


REPOSITORIES: dict[str, str] = {
    size: model["repository"] for size, model in MODEL_METADATA.items()
}
COMMITS: dict[str, str] = {
    size: model["commit"] for size, model in MODEL_METADATA.items()
}
FILES: dict[str, dict[str, tuple[str, int, str]]] = files_by_role(MODEL_METADATA)


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

    for role in FILE_ROLES:
        filename, expected_size, sha256 = FILES[size][role]
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
