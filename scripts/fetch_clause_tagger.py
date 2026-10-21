from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import NamedTuple

import pinned_download


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json"
)
ROLES = ("model", "tokenizer", "export", "license")
CACHE_ROOT = Path(".build") / "clause-tagger-onnx"
CHUNK = 1024 * 1024


class Release(NamedTuple):
    repository: str
    tag: str
    asset: str
    byte_count: int
    sha256: str
    directory: str

    @property
    def url(self) -> str:
        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{self.asset}"


class Member(NamedTuple):
    role: str
    name: str
    byte_count: int
    sha256: str


class Manifest(NamedTuple):
    release: Release
    members: list[Member]


def _require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError(f"SHA-256 が不正です: {label}")
    return value


def _require_byte_count(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"byteCount が不正です: {label}")
    return value


def _require_plain_name(name: object, label: str) -> str:
    if (
        not isinstance(name, str)
        or not name
        or name in (".", "..")
        or "/" in name
        or "\\" in name
    ):
        raise ValueError(f"{label}が不正です: {name!r}")
    return name


def parse_manifest(text: str) -> Manifest:
    manifest = json.loads(text)
    if manifest["schemaVersion"] != 1:
        raise ValueError(f"未対応の schemaVersion です: {manifest['schemaVersion']}")
    source = manifest["release"]
    repository, tag = source["repository"], source["tag"]
    if not isinstance(repository, str) or not repository or not isinstance(tag, str) or not tag:
        raise ValueError("release の repository と tag が不正です")
    release = Release(
        repository,
        tag,
        _require_plain_name(source["asset"], "asset 名"),
        _require_byte_count(source["byteCount"], "release"),
        _require_sha256(source["sha256"], "release"),
        _require_plain_name(source["directory"], "directory 名"),
    )
    by_role: dict[str, Member] = {}
    names: set[str] = set()
    for entry in manifest["members"]:
        role = entry["role"]
        if role not in ROLES:
            raise ValueError(f"未対応の role です: {role}")
        if role in by_role:
            raise ValueError(f"role が重複しています: {role}")
        name = _require_plain_name(entry["name"], "ファイル名")
        if name in names:
            raise ValueError(f"ファイル名が重複しています: {name}")
        names.add(name)
        by_role[role] = Member(
            role,
            name,
            _require_byte_count(entry["byteCount"], name),
            _require_sha256(entry["sha256"], name),
        )
    missing = [role for role in ROLES if role not in by_role]
    if missing:
        raise ValueError(f"必要な role がありません: {', '.join(missing)}")
    model = manifest["model"]
    _require_sha256(model["revision"], "model.revision")
    tokenizer_sha256 = _require_sha256(model["tokenizerSHA256"], "model.tokenizerSHA256")
    if by_role["tokenizer"].sha256 != tokenizer_sha256:
        raise ValueError("tokenizer の SHA-256 が model.tokenizerSHA256 と一致しません")
    return Manifest(release, [by_role[role] for role in ROLES])


def load_manifest() -> Manifest:
    return parse_manifest(MANIFEST_PATH.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_directory(directory: Path, members: list[Member]) -> None:
    """Requires exactly the pinned members as regular files with the pinned sizes and hashes."""
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise ValueError(f"モデル directory を確認できません: {directory}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"モデル directory が通常のディレクトリではありません: {directory}")
    expected = {member.name for member in members}
    actual = {entry.name for entry in directory.iterdir()}
    if actual != expected:
        raise ValueError(
            f"モデル directory の内容が一致しません: {directory}。"
            f"不足 {sorted(expected - actual)}、余分 {sorted(actual - expected)}。"
            f"directory を削除して再実行してください。"
        )
    for member in members:
        path = directory / member.name
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f"通常ファイルではありません: {path}。directory を削除して再実行してください。")
        if metadata.st_size != member.byte_count:
            raise ValueError(
                f"ファイルサイズが一致しません: {path}。"
                f"期待値 {member.byte_count}、実際 {metadata.st_size}。directory を削除して再実行してください。"
            )
        actual_sha256 = _sha256(path)
        if actual_sha256 != member.sha256:
            raise ValueError(
                f"SHA-256 が一致しません: {path}。期待値 {member.sha256}、実際 {actual_sha256}。"
                "directory を削除して再実行してください。"
            )


def _checked_member_path(name: str, directory: str) -> str:
    """Returns the member's file name inside `directory`, or raises for any unsafe archive path."""
    if not name or "\\" in name or name.startswith("/") or "\x00" in name:
        raise ValueError(f"安全でないアーカイブ内パスです: {name!r}")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts) or len(parts) != 2 or parts[0] != directory:
        raise ValueError(f"想定外のアーカイブ内パスです: {name!r}")
    return parts[1]


def extract_archive(archive: Path, staging: Path, release: Release, members: list[Member]) -> Path:
    """Extracts only the pinned regular files into staging/<directory> and returns that directory."""
    expected = {member.name: member for member in members}
    target = staging / release.directory
    target.mkdir()
    seen: set[str] = set()
    seen_directory = False
    with tarfile.open(archive, mode="r:gz") as source:
        for entry in source:
            if entry.isdir():
                if entry.name.rstrip("/") != release.directory or seen_directory:
                    raise ValueError(f"想定外のアーカイブ内ディレクトリです: {entry.name!r}")
                seen_directory = True
                continue
            if not entry.isreg():
                raise ValueError(f"通常ファイル以外のアーカイブ内エントリです: {entry.name!r}")
            name = _checked_member_path(entry.name, release.directory)
            member = expected.get(name)
            if member is None:
                raise ValueError(f"想定外のアーカイブ内ファイルです: {entry.name!r}")
            if name in seen:
                raise ValueError(f"アーカイブ内ファイルが重複しています: {entry.name!r}")
            seen.add(name)
            if entry.size != member.byte_count:
                raise ValueError(
                    f"アーカイブ内ファイルのサイズが一致しません: {entry.name!r}。"
                    f"期待値 {member.byte_count}、実際 {entry.size}。"
                )
            stream = source.extractfile(entry)
            if stream is None:
                raise ValueError(f"アーカイブ内ファイルを読めません: {entry.name!r}")
            remaining = entry.size
            with stream, (target / name).open("xb") as output:
                while remaining:
                    chunk = stream.read(min(CHUNK, remaining))
                    if not chunk:
                        raise ValueError(f"アーカイブ内ファイルが途中で終わっています: {entry.name!r}")
                    output.write(chunk)
                    remaining -= len(chunk)
    missing = sorted(set(expected) - seen)
    if missing:
        raise ValueError(f"アーカイブに必要なファイルがありません: {missing}")
    verify_directory(target, members)
    return target


def _remove_tree(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeError(f"削除対象が通常のディレクトリではありません: {path}")
    shutil.rmtree(path)


def fetch(manifest: Manifest) -> Path:
    release, members = manifest
    repository = Path(__file__).resolve().parent.parent
    cache = pinned_download.ensure_repository_directory(
        repository, repository / CACHE_ROOT / release.tag
    )
    destination = cache / release.directory
    if os.path.lexists(destination):
        verify_directory(destination, members)
        return destination

    for stale in cache.glob(".extract-*"):
        _remove_tree(stale)
    archive = pinned_download.download_verified(release.url, release.sha256, cache / release.asset)
    actual_size = archive.stat().st_size
    if actual_size != release.byte_count:
        raise ValueError(
            f"アーカイブのサイズが一致しません: {archive}。期待値 {release.byte_count}、実際 {actual_size}。"
        )
    staging = Path(tempfile.mkdtemp(prefix=".extract-", dir=cache))
    try:
        extracted = extract_archive(archive, staging, release, members)
        if os.path.lexists(destination):
            raise RuntimeError(f"展開先ディレクトリが既に存在します: {destination}")
        os.replace(extracted, destination)
    finally:
        _remove_tree(staging)
    archive.unlink()
    return destination


def main() -> int:
    if sys.version_info < (3, 12):
        print("エラー: Python 3.12 以上が必要です。", file=sys.stderr)
        return 1
    if len(sys.argv) != 1:
        print("エラー: このコマンドは引数を受け付けません。", file=sys.stderr)
        return 2
    try:
        print(fetch(load_manifest()))
    except Exception as error:
        print(
            f"エラー: 発話文タガーの ONNX モデルの取得に失敗しました: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
