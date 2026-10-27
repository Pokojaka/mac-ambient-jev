from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

import pinned_download


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "app/MacAmbientJev/Sources/MacAmbientJevPortableRuntime/Resources/clause_tagger_model.json"
)
ROLES = {
    "onnx": ("model", "tokenizer", "export", "license", "modelLicense"),
    "coreml": ("tokenizer", "packageManifest", "model", "weights", "debugMapping", "modelLicense"),
}
DIRECTORIES = {"onnx": "clause-tagger-onnx", "coreml": "clause-tagger"}
CACHE_ROOTS = {"onnx": Path(".build") / "clause-tagger-onnx", "coreml": Path(".build") / "clause-tagger"}


class Source(NamedTuple):
    repository: str
    commit: str


class Member(NamedTuple):
    role: str
    name: str
    path: str
    byte_count: int
    sha256: str


class Manifest(NamedTuple):
    source: Source
    members: list[Member]
    format: str
    directory: str


def _require_format(value: object) -> str:
    if not isinstance(value, str) or value not in ROLES:
        raise ValueError(f"未対応の形式です: {value!r}。onnx または coreml を指定してください")
    return value


def _require_object(value: object, label: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} が object ではありません")
    return value


def _require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError(f"SHA-256 が不正です: {label}")
    return value


def _require_byte_count(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"byteCount が不正です: {label}")
    return value


def _require_relative_posix_path(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value or "\x00" in value:
        raise ValueError(f"{label}が不正です: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", part) for part in parts):
        raise ValueError(f"安全でない {label} です: {value!r}")
    return value


def _require_repository(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("source.repository が不正です")
    parts = value.split("/")
    if len(parts) != 2 or any(
        not part or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", part)
        for part in parts
    ):
        raise ValueError(f"source.repository が不正です: {value!r}")
    return value


def _parse_members(entries: object, format: str, label: str) -> list[Member]:
    if not isinstance(entries, list):
        raise ValueError(f"{label} が array ではありません")
    by_role: dict[str, Member] = {}
    names: set[str] = set()
    paths: set[str] = set()
    for index, raw_entry in enumerate(entries):
        entry = _require_object(raw_entry, f"{label}[{index}]")
        role = entry.get("role")
        if not isinstance(role, str) or role not in ROLES[format]:
            raise ValueError(f"未対応の {label} role です: {role!r}")
        if role in by_role:
            raise ValueError(f"{label} role が重複しています: {role}")
        name = _require_relative_posix_path(entry.get("name"), f"{label} name")
        if format == "onnx" and "/" in name:
            raise ValueError(f"{label} ONNX name は単一ファイル名である必要があります: {name!r}")
        path = _require_relative_posix_path(entry.get("path"), f"{label} path")
        if name in names:
            raise ValueError(f"{label} name が重複しています: {name}")
        if path in paths:
            raise ValueError(f"{label} path が重複しています: {path}")
        names.add(name)
        paths.add(path)
        expected_path = "LICENSE.md" if role == "modelLicense" else f"{format}/{name}"
        if role == "modelLicense" and name != "LICENSE.md":
            raise ValueError(f"{label} modelLicense name は LICENSE.md である必要があります")
        if path != expected_path:
            raise ValueError(f"{label} path が name から想定される値と一致しません: {path!r}")
        by_role[role] = Member(
            role,
            name,
            path,
            _require_byte_count(entry.get("byteCount"), name),
            _require_sha256(entry.get("sha256"), name),
        )
    missing = [role for role in ROLES[format] if role not in by_role]
    if missing:
        raise ValueError(f"{label} に必要な role がありません: {', '.join(missing)}")
    return [by_role[role] for role in ROLES[format]]


def parse_manifest(text: str, format: str) -> Manifest:
    format = _require_format(format)
    raw_manifest = _require_object(json.loads(text), "manifest")
    schema_version = raw_manifest.get("schemaVersion")
    if not isinstance(schema_version, int) or isinstance(schema_version, bool) or schema_version != 1:
        raise ValueError(f"未対応の schemaVersion です: {schema_version!r}")

    raw_source = _require_object(raw_manifest.get("source"), "source")
    repository = _require_repository(raw_source.get("repository"))
    commit = raw_source.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("source.commit は40桁の小文字16進数である必要があります")
    source = Source(repository, commit)

    raw_model = _require_object(raw_manifest.get("model"), "model")
    if raw_model.get("id") != repository:
        raise ValueError("model.id が source.repository と一致しません")
    _require_sha256(raw_model.get("revision"), "model.revision")
    tokenizer_sha256 = _require_sha256(raw_model.get("tokenizerSHA256"), "model.tokenizerSHA256")

    _require_object(raw_manifest.get("onnx"), "onnx")
    onnx_members = _parse_members(raw_manifest.get("members"), "onnx", "members")
    coreml_members = _parse_members(raw_manifest.get("coremlMembers"), "coreml", "coremlMembers")
    for member in (*onnx_members, *coreml_members):
        if member.role == "tokenizer" and member.sha256 != tokenizer_sha256:
            raise ValueError(f"{member.path} の SHA-256 が model.tokenizerSHA256 と一致しません")

    selected_members = onnx_members if format == "onnx" else coreml_members
    return Manifest(source, selected_members, format, DIRECTORIES[format])


def load_manifest(format: str) -> Manifest:
    return parse_manifest(MANIFEST_PATH.read_text(encoding="utf-8"), format)


def verify_directory(directory: Path, members: list[Member]) -> None:
    """Requires exactly the pinned files and parent directories, with regular-file contents."""
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise ValueError(f"モデル directory を確認できません: {directory}") from error
    if not stat.S_ISDIR(metadata.st_mode):
        raise ValueError(f"モデル directory が通常のディレクトリではありません: {directory}")

    expected_files = {member.name: member for member in members}
    expected_directories: set[str] = set()
    for member in members:
        parts = member.name.split("/")
        expected_directories.update("/".join(parts[:index]) for index in range(1, len(parts)))

    actual_files: set[str] = set()
    actual_directories: set[str] = set()
    pending = [directory]
    while pending:
        current = pending.pop()
        for entry in current.iterdir():
            relative = entry.relative_to(directory).as_posix()
            entry_metadata = entry.lstat()
            if stat.S_ISDIR(entry_metadata.st_mode):
                actual_directories.add(relative)
                pending.append(entry)
            elif stat.S_ISREG(entry_metadata.st_mode):
                actual_files.add(relative)
            else:
                raise ValueError(f"通常ファイルまたは通常ディレクトリではありません: {entry}")

    if actual_directories != expected_directories:
        raise ValueError(
            f"モデル directory の directory 構成が一致しません: {directory}。"
            f"不足 {sorted(expected_directories - actual_directories)}、"
            f"余分 {sorted(actual_directories - expected_directories)}。directory を削除して再実行してください。"
        )
    expected_names = set(expected_files)
    if actual_files != expected_names:
        raise ValueError(
            f"モデル directory のファイル構成が一致しません: {directory}。"
            f"不足 {sorted(expected_names - actual_files)}、余分 {sorted(actual_files - expected_names)}。"
            f"directory を削除して再実行してください。"
        )
    for name, member in expected_files.items():
        path = directory.joinpath(*name.split("/"))
        metadata = path.lstat()
        if metadata.st_size != member.byte_count:
            raise ValueError(
                f"ファイルサイズが一致しません: {path}。期待値 {member.byte_count}、実際 {metadata.st_size}。"
                "directory を削除して再実行してください。"
            )
        actual_sha256 = pinned_download.sha256(path)
        if actual_sha256 != member.sha256:
            raise ValueError(
                f"SHA-256 が一致しません: {path}。期待値 {member.sha256}、実際 {actual_sha256}。"
                "directory を削除して再実行してください。"
            )


def _member_url(source: Source, member: Member) -> str:
    return f"https://huggingface.co/{source.repository}/resolve/{source.commit}/{member.path}"


def fetch(manifest: Manifest) -> Path:
    if not isinstance(manifest, Manifest) or not isinstance(manifest.source, Source):
        raise ValueError("fetch には parse_manifest が返す Manifest が必要です")
    format = _require_format(manifest.format)
    repository_name = _require_repository(manifest.source.repository)
    commit = manifest.source.commit
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("source.commit は40桁の小文字16進数である必要があります")
    if manifest.directory != DIRECTORIES[format]:
        raise ValueError(f"format に対応しない cache directory です: {manifest.directory!r}")
    if not isinstance(manifest.members, list):
        raise ValueError("Manifest members は list である必要があります")
    members = _parse_members(
        [
            {
                "role": member.role,
                "name": member.name,
                "path": member.path,
                "byteCount": member.byte_count,
                "sha256": member.sha256,
            }
            for member in manifest.members
            if isinstance(member, Member)
        ],
        format,
        "members",
    )
    if len(members) != len(manifest.members):
        raise ValueError("Manifest に不正な member があります")
    source = Source(repository_name, commit)
    repository = REPOSITORY_ROOT
    cache = pinned_download.ensure_repository_directory(
        repository, repository / CACHE_ROOTS[format] / commit
    )
    destination = cache / manifest.directory
    if os.path.lexists(destination):
        verify_directory(destination, members)
        return destination

    staging = Path(tempfile.mkdtemp(prefix=".fetch-", dir=cache))
    try:
        for member in members:
            url = _member_url(source, member)
            local_path = staging.joinpath(*member.name.split("/"))
            try:
                local_path.parent.mkdir(parents=True, exist_ok=True)
                downloaded = pinned_download.download_verified(url, member.sha256, local_path)
                actual_size = downloaded.stat().st_size
                if actual_size != member.byte_count:
                    raise ValueError(
                        f"byteCount が一致しません: 期待値 {member.byte_count}、実際 {actual_size}"
                    )
            except Exception as error:
                raise RuntimeError(f"取得または検証に失敗しました: {url} ({member.name}): {error}") from error

        verify_directory(staging, members)
        if os.path.lexists(destination):
            raise RuntimeError(f"公開先 directory が既に存在します: {destination}")
        os.replace(staging, destination)
    finally:
        if os.path.lexists(staging):
            pinned_download.remove_tree(staging)
    return destination


def main() -> int:
    if sys.version_info < (3, 12):
        print("エラー: Python 3.12 以上が必要です。", file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(description="HF から pin 済み発話文タガーを取得します")
    parser.add_argument("--format", choices=tuple(ROLES), required=True)
    arguments = parser.parse_args()
    try:
        print(fetch(load_manifest(arguments.format)))
    except Exception as error:
        print(f"エラー: 発話文タガーの取得に失敗しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
