from __future__ import annotations

import hashlib
import os
import shutil
import stat
import tempfile
import urllib.request
from pathlib import Path


def ensure_repository_directory(root: Path, directory: Path) -> Path:
    if not root.is_absolute():
        raise RuntimeError(f"リポジトリパスが絶対パスではありません: {root}")
    try:
        root_metadata = root.lstat()
    except FileNotFoundError as error:
        raise RuntimeError(f"リポジトリディレクトリがありません: {root}") from error
    except OSError as error:
        raise RuntimeError(f"リポジトリパスを確認できません: {root}") from error
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise RuntimeError(f"リポジトリパスが通常のディレクトリではありません: {root}")
    try:
        canonical_root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise RuntimeError(f"リポジトリパスを解決できません: {root}") from error

    if not directory.is_absolute():
        raise RuntimeError(f"対象ディレクトリが絶対パスではありません: {directory}")
    if ".." in directory.parts:
        raise RuntimeError(f"対象ディレクトリに親参照が含まれています: {directory}")
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise RuntimeError(f"対象ディレクトリがリポジトリ外です: {directory}") from error

    current = canonical_root
    for component in relative.parts:
        current = current / component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            try:
                current.mkdir()
            except OSError as error:
                raise RuntimeError(f"対象ディレクトリを作成できません: {current}") from error
            try:
                metadata = current.lstat()
            except OSError as error:
                raise RuntimeError(f"対象ディレクトリを確認できません: {current}") from error
        except OSError as error:
            raise RuntimeError(f"対象ディレクトリを確認できません: {current}") from error
        if not stat.S_ISDIR(metadata.st_mode):
            raise RuntimeError(f"対象ディレクトリの構成要素が通常のディレクトリではありません: {current}")
    return current


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def remove_tree(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeError(f"削除対象が通常のディレクトリではありません: {path}")
    shutil.rmtree(path)


def download_verified(url: str, expected_sha256: str, destination: Path) -> Path:
    if not destination.is_absolute():
        raise RuntimeError(f"ダウンロード先が絶対パスではありません: {destination}")

    try:
        metadata = destination.lstat()
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISREG(metadata.st_mode):
            raise RuntimeError(f"既存のダウンロード先が通常ファイルではありません: {destination}")
        actual = sha256(destination)
        if actual != expected_sha256:
            raise ValueError(
                f"SHA-256 が一致しません: {destination}。期待値 {expected_sha256}、実際 {actual}。"
            )
        return destination

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".download", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            with urllib.request.urlopen(url, timeout=60) as response:
                shutil.copyfileobj(response, output, length=1024 * 1024)
        actual = sha256(temporary)
        if actual != expected_sha256:
            raise ValueError(
                f"SHA-256 が一致しません: {temporary}。期待値 {expected_sha256}、実際 {actual}。"
            )
        os.replace(temporary, destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)
