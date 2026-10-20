from __future__ import annotations

import os
import platform
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PureWindowsPath

import pinned_download


VERSION = "1.31.0"
RELEASE_URL = f"https://github.com/microsoft/onnxruntime/releases/download/v{VERSION}"
LINUX_X64 = ("linux-x64", f"onnxruntime-linux-x64-{VERSION}.tgz", "cc5c72baf5ae5c8238a6841f0897227be2d02826b9cf98eaf02fdefaeeb03a57")
LINUX_ARM64 = ("linux-aarch64", f"onnxruntime-linux-aarch64-{VERSION}.tgz", "c5b8b3cca31f3d643a3b313b8f42e2d0f16a4fcefd02cda343d97bd5306afaab")
WINDOWS_X64 = ("win-x64", f"onnxruntime-win-x64-{VERSION}.zip", "3958d8a44984160692c1b4ffd0de3cb48f8c39f9d34bb31e433db06e30b82195")
WINDOWS_ARM64 = ("win-arm64", f"onnxruntime-win-arm64-{VERSION}.zip", "ef6206fa8d6975878d93a97035d280240ce5764c126a7430e5427e18923316d5")
ASSETS = {
    ("linux", "x86_64"): LINUX_X64, ("linux", "aarch64"): LINUX_ARM64, ("linux", "arm64"): LINUX_ARM64,
    ("windows", "amd64"): WINDOWS_X64, ("windows", "x86_64"): WINDOWS_X64,
    ("windows", "arm64"): WINDOWS_ARM64, ("windows", "aarch64"): WINDOWS_ARM64,
}


def choose_asset(system: str, machine: str) -> tuple[str, str, str]:
    try:
        return ASSETS[(system.casefold(), machine.casefold())]
    except KeyError as error:
        raise RuntimeError(
            f"未対応の実行環境です: platform.system()={system!r}, platform.machine()={machine!r}。"
            "Linux x86_64/aarch64/arm64、Windows AMD64/x86_64/ARM64/aarch64 のみ対応します。"
        ) from error


def _assert_within(parent: Path, path: Path) -> None:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError as error:
        raise RuntimeError(f"対象パスが許可されたディレクトリ外です: {path}") from error


def _require_directory(path: Path) -> None:
    try:
        is_directory = stat.S_ISDIR(path.lstat().st_mode)
    except FileNotFoundError as error:
        raise ValueError(f"必要なディレクトリがありません: {path}") from error
    if not is_directory:
        raise ValueError(f"必要なディレクトリがありません: {path}")


def _require_file(path: Path, root: Path, allow_symlink: bool) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise ValueError(f"必要な ONNX Runtime ファイルがありません: {path}") from error
    if stat.S_ISREG(metadata.st_mode):
        return
    if allow_symlink and stat.S_ISLNK(metadata.st_mode):
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(root.resolve())
        except (OSError, ValueError) as error:
            raise ValueError(f"共有ライブラリのリンク先が不正です: {path}") from error
        if resolved.is_file():
            return
        raise ValueError(f"共有ライブラリのリンク先が通常ファイルではありません: {path}")
    raise ValueError(f"必要な ONNX Runtime ファイルが通常ファイルではありません: {path}")


def _validate_tree(root: Path, is_zip: bool) -> None:
    for directory in (root, root / "include", root / "lib"):
        _require_directory(directory)
    if not is_zip:
        for entry in root.rglob("*"):
            if stat.S_ISLNK(entry.lstat().st_mode):
                _require_file(entry, root, True)
    required = [root / "LICENSE", root / "ThirdPartyNotices.txt", root / "include" / "onnxruntime_c_api.h"]
    if is_zip:
        required.extend((root / "lib" / "onnxruntime.lib", root / "lib" / "onnxruntime.dll"))
    else:
        required.extend(root / "lib" / f"libonnxruntime.so{suffix}" for suffix in (f".{VERSION}", ".1", ""))
    for path in required:
        _require_file(path, root, not is_zip and path.parent == root / "lib")


def _extract(archive: Path, staging: Path, root_name: str, is_zip: bool) -> None:
    if is_zip:
        with zipfile.ZipFile(archive) as source:
            for member in source.infolist():
                name = member.filename
                windows_name = PureWindowsPath(name)
                if name.startswith(("/", "\\")) or Path(name).is_absolute() or windows_name.drive or windows_name.root:
                    raise ValueError(f"安全でないアーカイブ内パスです: {name!r}")
            source.extractall(staging)
    else:
        with tarfile.open(archive, mode="r:gz", errorlevel=2) as source:
            source.extractall(staging, filter="data")
    entries = list(staging.iterdir())
    if len(entries) != 1 or entries[0].name != root_name:
        raise ValueError(f"アーカイブのルートディレクトリが不正です: {root_name}")
    _validate_tree(staging / root_name, is_zip)


def _remove_tree(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(metadata.st_mode):
        raise RuntimeError(f"削除対象が通常のディレクトリではありません: {path}")
    shutil.rmtree(path)


def fetch() -> Path:
    platform_name, asset_name, expected = choose_asset(platform.system(), platform.machine())
    repository = Path(__file__).resolve().parent.parent
    cache = pinned_download.ensure_repository_directory(repository, repository / ".build" / "onnxruntime" / VERSION)
    root_name = f"onnxruntime-{platform_name}-{VERSION}"
    destination = cache / root_name
    is_zip = asset_name.endswith(".zip")
    if os.path.lexists(destination):
        try:
            _validate_tree(destination, is_zip)
        except Exception as error:
            raise RuntimeError(f"展開先ディレクトリを削除してください: {destination}。理由: {error}") from error
        return destination.resolve()

    for stale_staging in cache.glob(".extract-*"):
        _remove_tree(stale_staging)
    for cached_asset_name in {asset[1] for asset in ASSETS.values()}:
        for temporary in cache.glob(f".{cached_asset_name}.*.download"):
            if not stat.S_ISREG(temporary.lstat().st_mode):
                raise RuntimeError(f"一時アーカイブが通常ファイルではありません: {temporary}")
            temporary.unlink()

    archive = pinned_download.download_verified(f"{RELEASE_URL}/{asset_name}", expected, cache / asset_name)
    staging = Path(tempfile.mkdtemp(prefix=".extract-", dir=cache))
    try:
        _assert_within(cache, staging)
        _extract(archive, staging, root_name, is_zip)
        if os.path.lexists(destination):
            raise RuntimeError(f"展開先ディレクトリが既に存在します: {destination}")
        os.replace(staging / root_name, destination)
        return destination.resolve()
    finally:
        _remove_tree(staging)


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
        print(f"エラー: ONNX Runtime の取得に失敗しました: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
