#!/usr/bin/env python3
"""日本語の現行 docs の参照を検査する（stdlib のみ）。

使い方: python3 scripts/check_doc_references.py [repository-root]
対象: README.md / AGENTS.md / docs/**/*.md（docs/records は除外）。
inline code と Markdown link のパス、全行の scripts/、既知 CLI の長い
オプション、inline code の Swift 型名を検査する。完全な Markdown / shell /
Swift parser ではなく、外部 URL・anchor・絶対パス・変数・placeholder は除外。
生成物は下の basename 集合だけ除外し、repo 相対パスには適用しない。
"""
from __future__ import annotations

import argparse
import ast
import os
import pathlib
import re
import sys
from dataclasses import dataclass
from urllib.parse import unquote


SWIFT_SOURCES = "app/MacAmbientJev/Sources"
# Package.swift の executable products と tools の argparse entry points。
CLI_SOURCES = {
    name: (f"{SWIFT_SOURCES}/{name}/main.swift",)
    for name in (
        "MacAmbientJevCaptureSystemAudio", "MacAmbientJevProcessRecording",
        "MacAmbientJevMeasureLiveLatency", "MacAmbientJevEvaluateSession",
        "MacAmbientJevEvaluateASR", "MacAmbientJevEvaluateDiarization",
    )
}
CLI_SOURCES.update({
    "tools/linux-audio/run_suite.py": ("tools/linux-audio/run_suite.py",),
    "tools/linux-audio/prepare_fixture.py": ("tools/linux-audio/prepare_fixture.py",),
    "asr.qwen3_asr": ("tools/linux-audio/asr/qwen3_asr.py",),
    "diarization.nemotron3": ("tools/linux-audio/diarization/nemotron3.py",),
    "common.voicevox_cli": ("tools/linux-audio/common/voicevox_cli.py",),
    "scripts/verify_linux_audio.sh": ("tools/linux-audio/run_suite.py",),
    "scripts/measure_live_latency.sh": (
        f"{SWIFT_SOURCES}/MacAmbientJevMeasureLiveLatency/main.swift",
    ),
})
for module in ("asr.qwen3_asr", "diarization.nemotron3", "common.voicevox_cli"):
    CLI_SOURCES[CLI_SOURCES[module][0]] = CLI_SOURCES[module]

# SessionLayout / DurableAudioWriter / SessionExport / ProcessRecording、
# measure_v1_run.sh、prepare_fixture / run_suite / voicevox_suite の出力。
RUNTIME_BASENAMES = frozenset({
    "session.json", "events.jsonl", "processing_metadata.json", "checkpoint.json",
    "audio-chunks.jsonl", "audio-gaps.jsonl", "transcript.txt", "segments.json", "plan.json",
    "audio.wav", "audio.m4a", "audio.flac", "storage.json", "recording.flac", "run.json", "engine-metrics.json",
    "memory.jsonl", "thermal.jsonl", "reference-verbatim.txt", "reference-content.txt",
    "speaker-reference.json", "fixture.json", "scenario.json", "qwen3-asr.json",
    "nemotron3.json", "diarization-evaluation.json", "nemotron3-current.json",
    "asr-evaluation-verbatim.json", "asr-evaluation-content.json",
    "qwen3-asr-verbatim-current.json", "qwen3-asr-content-current.json",
    "stdout.log", "stderr.log", "source-snapshot.tar.gz", "disk-usage.json",
})
# Apple SDK の型・property wrapper・framework。repo 型は追加しない。
APPLE_IDENTIFIERS = frozenset({
    "AppKit", "AppStorage", "AVFoundation", "CoreAudio", "CoreML", "Foundation",
    "IOKit", "ProcessInfo", "Security", "SwiftUI", "UserDefaults",
})
EXTENSIONS = frozenset({
    ".md", ".swift", ".py", ".sh", ".json", ".jsonl", ".yaml", ".yml",
    ".toml", ".txt", ".plist", ".entitlements", ".resolved", ".wav", ".m4a",
    ".flac", ".mp3", ".app", ".caf", ".f32le", ".log", ".gz",
})
IGNORED_DIRS = {".git", ".build", ".venv", "venv", ".claude", "__pycache__"}
INLINE = re.compile(r"(?<!`)(`+)(?!`)(.+?)\1(?!`)")
LINK = re.compile(r"\]\(\s*(<[^>]+>|[^\s)]+)|^\s*\[[^]]+\]:\s*(<[^>]+>|\S+)")
SCRIPT = re.compile(r"(?<![\w.-])(?:\./)?scripts/[\w.-]+")
FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
URL = re.compile(r"[a-zA-Z][\w+.-]*://[^\s`<>]+")
DECLARATION = re.compile(r"\b(?:struct|enum|class|actor|protocol|typealias|case)\s+([A-Za-z_]\w*)")
SWIFT_NOISE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', re.DOTALL)


@dataclass(frozen=True, order=True)
class Problem:
    file: str
    line: int
    message: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.message}"


def repo_files(root: pathlib.Path) -> list[pathlib.Path]:
    files = []
    for folder, directories, names in os.walk(root):
        directories[:] = sorted(set(directories) - IGNORED_DIRS)
        files.extend(pathlib.Path(folder) / name for name in sorted(names))
    return files


def documents(root: pathlib.Path) -> list[pathlib.Path]:
    paths = [root / name for name in ("README.md", "AGENTS.md")]
    paths.extend(path for path in (root / "docs").rglob("*.md")
                 if path.relative_to(root / "docs").parts[0] != "records")
    return sorted(path for path in paths if path.is_file())


def declared_flags(path: pathlib.Path) -> set[str]:
    source = path.read_text(encoding="utf-8")
    if path.suffix == ".sh":
        options = re.findall(r"(?:^\s*|\bin\s+|;;\s*)(--[\w|*-]+)\)", source, re.MULTILINE)
        options.extend(re.findall(r'==\s*"(--[\w-]+)"', source))
        return set(FLAG.findall(" ".join(options)))
    if path.suffix != ".py":
        return set(FLAG.findall(source))
    # argparse supplies --help unless explicitly disabled.
    flags = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if node.func.attr == "ArgumentParser":
                if not any(keyword.arg == "add_help" and isinstance(keyword.value, ast.Constant)
                           and keyword.value.value is False for keyword in node.keywords):
                    flags.add("--help")
            if node.func.attr == "add_argument":
                flags.update(arg.value for arg in node.args
                             if isinstance(arg, ast.Constant)
                             and isinstance(arg.value, str) and arg.value.startswith("--"))
    return flags


def swift_identifiers(root: pathlib.Path, files: list[pathlib.Path]) -> set[str]:
    names = set(APPLE_IDENTIFIERS)
    for path in files:
        relative = path.relative_to(root).as_posix()
        if path.suffix == ".swift" and (
            relative.startswith(SWIFT_SOURCES + "/") or relative.startswith("tools/")
        ):
            source = SWIFT_NOISE.sub(" ", path.read_text(encoding="utf-8"))
            names.update(DECLARATION.findall(source))
    package = root / "app/MacAmbientJev/Package.swift"
    if package.is_file():
        # CLI product / module names are not Swift types.
        names.update(re.findall(r'\bname:\s*"([A-Za-z_]\w*)"', package.read_text(encoding="utf-8")))
    return names


def path_candidate(value: str) -> str | None:
    value = unquote(value.strip())
    if not value or value.startswith(("#", "/", "~")) or re.match(r"[\w+.-]+:", value):
        return None
    if any(character in value for character in "$<>*{}|"):
        return None
    value = value.split("#", 1)[0].split("?", 1)[0]
    if not value or re.search(r"\s", value):
        return None
    if "/" in value or pathlib.PurePosixPath(value).suffix.lower() in EXTENSIONS:
        return value
    return None


def command_lines(lines: list[str]):
    """Join only explicit shell continuations, retaining each flag's source line."""
    group = []
    for number, line in enumerate(lines, 1):
        group.append((number, URL.sub("", line)))
        if not line.rstrip().endswith("\\"):
            yield group
            group = []
    if group:
        yield group


def check(root: pathlib.Path) -> list[Problem]:
    root = root.resolve()
    files = repo_files(root)
    basenames = {path.name for path in files if path.exists()}
    identifiers = swift_identifiers(root, files)
    cli_sources = dict(CLI_SOURCES)
    # Every real script is a known command, even scripts without long options.
    for path in sorted((root / "scripts").glob("*")):
        if path.suffix in {".sh", ".py"}:
            name = path.relative_to(root).as_posix()
            cli_sources.setdefault(name, (name,))
    allowed_flags = {
        name: set().union(*(declared_flags(root / source) for source in sources
                           if (root / source).is_file()))
        for name, sources in cli_sources.items()
    }
    problems = set()
    for document in documents(root):
        filename = document.relative_to(root).as_posix()
        lines = document.read_text(encoding="utf-8").splitlines()

        def report(number: int, message: str) -> None:
            problems.add(Problem(filename, number, message))

        def check_path(value: str, number: int, *, link: bool = False) -> None:
            candidate = path_candidate(value.strip("<>") if link else value)
            if candidate is None:
                return
            basename = "/" not in candidate
            if not link and basename and candidate in RUNTIME_BASENAMES:
                return
            if (document.parent / candidate).exists() or (root / candidate).exists():
                return
            if not link and basename and candidate in basenames:
                return
            report(number, f"missing path: {candidate}")

        fenced = False
        for number, line in enumerate(lines, 1):
            if re.match(r"^\s*(`{3,}|~{3,})", line):
                fenced = not fenced
                continue
            for match in SCRIPT.finditer(URL.sub("", line)):
                candidate = match.group().removeprefix("./")
                if not (root / candidate).is_file():
                    report(number, f"missing script: {candidate}")
            if fenced:
                continue
            for match in LINK.finditer(line):
                check_path(match.group(1) or match.group(2), number, link=True)
            for match in INLINE.finditer(line):
                code = match.group(2).strip()
                if not code.startswith(("/", "~", "$")):
                    for token in code.split():
                        check_path(token.strip("\"'(),;"), number)
                # A type, qualified member, or signature; not a shell command.
                if path_candidate(code) is None and re.fullmatch(
                    r"[A-Z]\w*(?:\.[\w.]+|\([^\n]*\))?", code
                ):
                    name = re.split(r"[.(]", code, maxsplit=1)[0]
                    if len(name) >= 3 and any(letter.islower() for letter in name):
                        if name not in identifiers:
                            report(number, f"unknown Swift identifier: {name}")

        for group in command_lines(lines):
            text = " ".join(line for _, line in group)
            commands = []
            for name in cli_sources:
                # Allow basename Python invocation and ./script invocation.
                aliases = {name}
                if "/" in name:
                    aliases.add(pathlib.PurePosixPath(name).name)
                for alias in sorted(aliases):
                    match = re.search(r"(?<![\w./-])(?:\./)?" + re.escape(alias)
                                      + r"(?![\w./-])", text)
                    if match:
                        commands.append((match.start(), match.end(), name))
                        break
            commands.sort()
            for index, (_, end, name) in enumerate(commands):
                stop = commands[index + 1][0] if index + 1 < len(commands) else len(text)
                section = text[end:stop]
                # Another shell command must not donate its options to this CLI.
                section = re.split(r"&&|\|\||[;|]", section, maxsplit=1)[0]
                for match in FLAG.finditer(section):
                    flag = match.group()
                    if flag not in allowed_flags[name]:
                        offset = end + match.start()
                        for number, line in group:
                            if offset <= len(line):
                                report(number, f"unknown flag for {name}: {flag}")
                                break
                            offset -= len(line) + 1
    return sorted(problems)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error(f"repository root not found: {args.root}")
    problems = check(args.root)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("Documentation reference check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
