from __future__ import annotations

import os
import platform
import shutil
import stat
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath, PureWindowsPath

import pinned_download


VERSION = "1.31.0"
PACKAGE_NAME = f"microsoft.ml.onnxruntime.{VERSION}.nupkg"
PACKAGE_URL = f"https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/{VERSION}/{PACKAGE_NAME}"
PACKAGE_BYTES = 159626085
PACKAGE_SHA256 = "7e35fdb4f5adb62f01e60798e2e5ed05108f5fbbe1cca03fbcc37903cf7c5e3b"
PLATFORMS = {
    ("linux", "x86_64"): "linux-x64", ("linux", "aarch64"): "linux-arm64", ("linux", "arm64"): "linux-arm64",
    ("windows", "amd64"): "win-x64", ("windows", "x86_64"): "win-x64",
    ("windows", "arm64"): "win-arm64", ("windows", "aarch64"): "win-arm64",
    ("darwin", "arm64"): "osx-arm64",
}
NATIVE_FILES = {
    "linux-x64": (("libonnxruntime.so", "libonnxruntime.so"), ("libonnxruntime_providers_shared.so", "libonnxruntime_providers_shared.so")),
    "linux-arm64": (("libonnxruntime.so", "libonnxruntime.so"), ("libonnxruntime_providers_shared.so", "libonnxruntime_providers_shared.so")),
    "osx-arm64": (("libonnxruntime.dylib", "libonnxruntime.1.dylib"),),
    "win-x64": (("onnxruntime.dll", "onnxruntime.dll"), ("onnxruntime.lib", "onnxruntime.lib"), ("onnxruntime_providers_shared.dll", "onnxruntime_providers_shared.dll"), ("onnxruntime_providers_shared.lib", "onnxruntime_providers_shared.lib")),
    "win-arm64": (("onnxruntime.dll", "onnxruntime.dll"), ("onnxruntime.lib", "onnxruntime.lib"), ("onnxruntime_providers_shared.dll", "onnxruntime_providers_shared.dll"), ("onnxruntime_providers_shared.lib", "onnxruntime_providers_shared.lib")),
}


def choose_platform(system: str, machine: str) -> str:
    try:
        return PLATFORMS[(system.casefold(), machine.casefold())]
    except KeyError as error:
        raise RuntimeError(
            f"未対応の実行環境です: platform.system()={system!r}, platform.machine()={machine!r}。"
            "Linux x86_64/aarch64/arm64、Windows AMD64/x86_64/ARM64/aarch64、macOS arm64 のみ対応します。"
        ) from error


def _validate_tree(root: Path, platform_name: str) -> None:
    for directory in (root, root / "include", root / "lib"):
        try:
            valid = stat.S_ISDIR(directory.lstat().st_mode)
        except FileNotFoundError:
            valid = False
        if not valid:
            raise ValueError(f"必要なディレクトリがありません: {directory}")
    required = [root / "LICENSE", root / "ThirdPartyNotices.txt", root / "include" / "onnxruntime_c_api.h", root / "include" / "onnxruntime_experimental_c_api.inc"]
    required.extend(root / "lib" / output for _, output in NATIVE_FILES[platform_name])
    soname = root / "lib" / "libonnxruntime.so.1"
    if platform_name.startswith("linux-"):
        required.append(soname)
    for entry in root.rglob("*"):
        if entry.is_symlink() and not (platform_name.startswith("linux-") and entry == soname):
            raise ValueError(f"許可されていないシンボリックリンクです: {entry}")
    for path in required:
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError as error:
            raise ValueError(f"必要な ONNX Runtime ファイルがありません: {path}") from error
        if path == soname and platform_name.startswith("linux-"):
            try:
                resolved = path.resolve(strict=True)
                resolved.relative_to(root.resolve())
            except (OSError, ValueError) as error:
                raise ValueError(f"共有ライブラリの SONAME リンクが不正です: {path}") from error
            if not stat.S_ISLNK(mode) or resolved != (root / "lib" / "libonnxruntime.so").resolve() or not resolved.is_file():
                raise ValueError(f"共有ライブラリの SONAME リンクが不正です: {path}")
        elif not stat.S_ISREG(mode):
            raise ValueError(f"必要な ONNX Runtime ファイルが通常ファイルではありません: {path}")


def _extract(archive: Path, staging: Path, platform_name: str) -> None:
    prefix = f"runtimes/{platform_name}/native/"
    native = dict(NATIVE_FILES[platform_name])
    selected: list[tuple[zipfile.ZipInfo, Path]] = []
    with zipfile.ZipFile(archive) as source:
        members = source.infolist()
        for member in members:
            name = member.orig_filename
            posix, windows = PurePosixPath(name), PureWindowsPath(name)
            if "\\" in name or ":" in name or posix.is_absolute() or windows.drive or windows.root or ".." in posix.parts:
                raise ValueError(f"安全でないアーカイブ内パスです: {name!r}")
        for member in members:
            name = member.filename
            target = None
            if name in ("LICENSE", "ThirdPartyNotices.txt"):
                target = staging / platform_name / name
            elif name.startswith("build/native/include/"):
                filename = name.removeprefix("build/native/include/")
                if "/" not in filename and (filename.endswith(".h") or filename == "onnxruntime_experimental_c_api.inc"):
                    target = staging / platform_name / "include" / filename
            elif name.startswith(prefix) and name.removeprefix(prefix) in native:
                target = staging / platform_name / "lib" / native[name.removeprefix(prefix)]
            if target is None:
                continue
            kind = stat.S_IFMT(member.external_attr >> 16)
            if kind not in (0, stat.S_IFREG):
                raise ValueError(f"選択したアーカイブ項目が通常ファイルではありません: {name!r}")
            selected.append((member, target))
        root = staging / platform_name
        (root / "include").mkdir(parents=True)
        (root / "lib").mkdir()
        for member, target in selected:
            with source.open(member) as input_file, target.open("wb") as output_file:
                shutil.copyfileobj(input_file, output_file)
    if platform_name.startswith("linux-"):
        (staging / platform_name / "lib" / "libonnxruntime.so.1").symlink_to("libonnxruntime.so")


def fetch() -> Path:
    platform_name = choose_platform(platform.system(), platform.machine())
    repository = Path(__file__).resolve().parent.parent
    cache = pinned_download.ensure_repository_directory(repository, repository / ".build" / "onnxruntime" / VERSION)
    destination = cache / platform_name
    if os.path.lexists(destination):
        try:
            _validate_tree(destination, platform_name)
        except Exception as error:
            raise RuntimeError(f"展開先ディレクトリを削除してください: {destination}。理由: {error}") from error
        return destination.resolve()
    for stale_staging in cache.glob(".extract-*"):
        pinned_download.remove_tree(stale_staging)
    for temporary in cache.glob(f".{PACKAGE_NAME}.*.download"):
        if not stat.S_ISREG(temporary.lstat().st_mode):
            raise RuntimeError(f"一時アーカイブが通常ファイルではありません: {temporary}")
        temporary.unlink()
    archive = pinned_download.download_verified(PACKAGE_URL, PACKAGE_SHA256, cache / PACKAGE_NAME)
    if archive.stat().st_size != PACKAGE_BYTES:
        raise ValueError(f"NuGet package のサイズが一致しません: {archive.stat().st_size} bytes")
    staging = Path(tempfile.mkdtemp(prefix=".extract-", dir=cache))
    try:
        _extract(archive, staging, platform_name)
        root = staging / platform_name
        _validate_tree(root, platform_name)
        if os.path.lexists(destination):
            raise RuntimeError(f"展開先ディレクトリが既に存在します: {destination}")
        os.replace(root, destination)
        return destination.resolve()
    finally:
        pinned_download.remove_tree(staging)


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
