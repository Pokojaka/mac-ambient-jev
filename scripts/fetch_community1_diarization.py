from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import NamedTuple

import pinned_download


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Sources/MacAmbientJevDiarization/Resources/community1_diarization_models.json"
)
ROLES = ("segmentation", "embedding", "plda", "xvector")


class ModelFile(NamedTuple):
    role: str
    repository: str
    revision: str
    name: str
    byte_count: int
    sha256: str

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repository}/resolve/{self.revision}/{self.name}"


def parse_manifest(text: str) -> tuple[list[ModelFile], str]:
    """Returns the four pinned files in role order and the cache key derived from the source revisions."""
    manifest = json.loads(text)
    sources = manifest["sources"]
    by_role: dict[str, ModelFile] = {}
    for file in manifest["files"]:
        role = file["role"]
        if role not in ROLES:
            raise ValueError(f"未対応の role です: {role}")
        if role in by_role:
            raise ValueError(f"role が重複しています: {role}")
        name = file["name"]
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            raise ValueError(f"ファイル名が不正です: {name!r}")
        sha256 = file["sha256"]
        if not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ValueError(f"SHA-256 が不正です: {name}")
        byte_count = file["byteCount"]
        if not isinstance(byte_count, int) or byte_count <= 0:
            raise ValueError(f"byteCount が不正です: {name}")
        source = sources[file["source"]]
        by_role[role] = ModelFile(
            role, source["repository"], source["revision"], name, byte_count, sha256
        )
    missing = [role for role in ROLES if role not in by_role]
    if missing:
        raise ValueError(f"必要な role がありません: {', '.join(missing)}")
    key = "-".join(sources[source_id]["revision"][:12] for source_id in sorted(sources))
    return [by_role[role] for role in ROLES], key


def load_manifest() -> tuple[list[ModelFile], str]:
    return parse_manifest(MANIFEST_PATH.read_text(encoding="utf-8"))


def fetch(files: list[ModelFile], key: str) -> Path:
    repository = Path(__file__).resolve().parent.parent
    directory = pinned_download.ensure_repository_directory(
        repository, repository / ".build" / "community1-diarization" / key
    )
    for file in files:
        downloaded = pinned_download.download_verified(
            file.url, file.sha256, directory / file.name
        )
        actual_size = downloaded.stat().st_size
        if actual_size != file.byte_count:
            raise ValueError(
                f"ファイルサイズが一致しません: {downloaded}。"
                f"期待値 {file.byte_count}、実際 {actual_size}。"
            )
    return directory


def main() -> int:
    if sys.version_info < (3, 12):
        print("エラー: Python 3.12 以上が必要です。", file=sys.stderr)
        return 1
    if len(sys.argv) != 1:
        print("エラー: このコマンドは引数を受け付けません。", file=sys.stderr)
        return 2
    try:
        files, key = load_manifest()
        print(fetch(files, key))
    except Exception as error:
        print(
            f"エラー: Community-1 diarization モデルの取得に失敗しました: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
