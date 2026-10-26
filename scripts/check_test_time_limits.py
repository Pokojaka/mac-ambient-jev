#!/usr/bin/env python3
"""Enforce the repository's uniform Swift Testing hang guard."""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from pathlib import Path
import sys

HANG_GUARD_MINUTES = 10


@dataclass(frozen=True)
class Token:
    kind: str
    text: str
    line: int


class LexError(Exception):
    def __init__(self, line: int, message: str) -> None:
        super().__init__(message)
        self.line = line


class SwiftLexer:
    """Tokenize enough Swift syntax to find calls outside comments and strings."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.index = 0
        self.line = 1
        self.tokens: list[Token] = []

    def _advance(self, count: int = 1) -> None:
        self.line += self.source[self.index : self.index + count].count("\n")
        self.index += count

    @staticmethod
    def _identifier_start(char: str) -> bool:
        return char == "_" or char.isalpha() or ord(char) >= 128

    @classmethod
    def _identifier_continue(cls, char: str) -> bool:
        return char == "_" or char.isalnum() or ord(char) >= 128

    def _emit(self, kind: str, text: str, line: int) -> None:
        self.tokens.append(Token(kind, text, line))

    def _skip_line_comment(self) -> None:
        self._advance(2)
        while self.index < len(self.source) and self.source[self.index] != "\n":
            self._advance()

    def _skip_block_comment(self) -> None:
        start_line = self.line
        self._advance(2)
        depth = 1
        while self.index < len(self.source):
            if self.source.startswith("/*", self.index):
                depth += 1
                self._advance(2)
            elif self.source.startswith("*/", self.index):
                depth -= 1
                self._advance(2)
                if depth == 0:
                    return
            else:
                self._advance()
        raise LexError(start_line, "unterminated block comment")

    def _string_start(self) -> tuple[int, int] | None:
        end = self.index
        while end < len(self.source) and self.source[end] == "#":
            end += 1
        if end >= len(self.source) or self.source[end] != '"':
            return None
        hashes = end - self.index
        quote_count = 3 if self.source.startswith('"""', end) else 1
        return hashes, quote_count

    def _skip_string(self, hashes: int, quote_count: int) -> None:
        start_line = self.line
        self._advance(hashes + quote_count)
        end_quotes = '"' * quote_count
        end_hashes = "#" * hashes

        while self.index < len(self.source):
            if self.source.startswith(end_quotes, self.index) and self.source.startswith(
                end_hashes, self.index + quote_count
            ):
                self._advance(quote_count + hashes)
                return

            if self.source[self.index] == "\\":
                escape_start = self.index
                marker = self.index + 1
                if self.source.startswith(end_hashes, marker):
                    after_marker = marker + hashes
                    if after_marker < len(self.source) and self.source[after_marker] == "(":
                        interpolation_line = self.line
                        self._advance(after_marker + 1 - self.index)
                        if not self._lex_code(stop_at_interpolation_close=True):
                            raise LexError(interpolation_line, "unterminated string interpolation")
                        continue
                    if after_marker < len(self.source):
                        self._advance(after_marker + 1 - self.index)
                        continue
                if hashes == 0 and self.index + 1 < len(self.source):
                    self._advance(2)
                else:
                    self._advance(1)
                if self.index == escape_start:
                    raise AssertionError("string lexer did not advance")
                continue

            self._advance()

        raise LexError(start_line, "unterminated string literal")

    def _lex_identifier(self) -> None:
        line = self.line
        start = self.index
        if self.source[self.index] == "$":
            self._advance()
        self._advance()
        while self.index < len(self.source) and self._identifier_continue(self.source[self.index]):
            self._advance()
        self._emit("identifier", self.source[start : self.index], line)

    def _lex_backticked_identifier(self) -> None:
        line = self.line
        self._advance()
        start = self.index
        while self.index < len(self.source) and self.source[self.index] != "`":
            if self.source[self.index] == "\n":
                raise LexError(line, "newline in backticked identifier")
            self._advance()
        if self.index == len(self.source):
            raise LexError(line, "unterminated backticked identifier")
        text = self.source[start : self.index]
        if not text:
            raise LexError(line, "empty backticked identifier")
        self._advance()
        self._emit("identifier", text, line)

    def _lex_number(self) -> None:
        line = self.line
        start = self.index
        if self.source.startswith(("0x", "0X", "0o", "0O", "0b", "0B"), self.index):
            self._advance(2)
            while self.index < len(self.source) and (
                self.source[self.index].isalnum() or self.source[self.index] == "_"
            ):
                self._advance()
        else:
            while self.index < len(self.source) and (
                self.source[self.index].isdigit() or self.source[self.index] == "_"
            ):
                self._advance()
            if (
                self.index + 1 < len(self.source)
                and self.source[self.index] == "."
                and self.source[self.index + 1].isdigit()
            ):
                self._advance()
                while self.index < len(self.source) and (
                    self.source[self.index].isdigit() or self.source[self.index] == "_"
                ):
                    self._advance()
            if self.index < len(self.source) and self.source[self.index] in "eE":
                self._advance()
                if self.index < len(self.source) and self.source[self.index] in "+-":
                    self._advance()
                while self.index < len(self.source) and (
                    self.source[self.index].isdigit() or self.source[self.index] == "_"
                ):
                    self._advance()
        self._emit("number", self.source[start : self.index], line)

    def _lex_code(self, stop_at_interpolation_close: bool = False) -> bool:
        paren_depth = 0
        while self.index < len(self.source):
            char = self.source[self.index]
            if char.isspace():
                self._advance()
                continue
            if self.source.startswith("//", self.index):
                self._skip_line_comment()
                continue
            if self.source.startswith("/*", self.index):
                self._skip_block_comment()
                continue
            string_start = self._string_start()
            if string_start is not None:
                self._skip_string(*string_start)
                continue
            if char == "`":
                self._lex_backticked_identifier()
                continue
            if char == "$" and self.index + 1 < len(self.source) and (
                self._identifier_start(self.source[self.index + 1])
                or self.source[self.index + 1].isdigit()
            ):
                self._lex_identifier()
                continue
            if self._identifier_start(char):
                self._lex_identifier()
                continue
            if char.isdigit():
                self._lex_number()
                continue

            line = self.line
            if char == "(" and stop_at_interpolation_close:
                paren_depth += 1
            elif char == ")" and stop_at_interpolation_close:
                if paren_depth == 0:
                    self._advance()
                    return True
                paren_depth -= 1
            self._emit("punctuation", char, line)
            self._advance()

        return not stop_at_interpolation_close

    def tokenize(self) -> list[Token]:
        self._lex_code()
        return self.tokens


def _is_canonical_time_limit(tokens: list[Token], name_index: int) -> bool:
    # Check the member dot as well as the complete call shape. Tokenization
    # removes comments and whitespace, so either may occur between every token.
    expected = (
        ("punctuation", "("),
        ("punctuation", "."),
        ("identifier", "minutes"),
        ("punctuation", "("),
        ("number", str(HANG_GUARD_MINUTES)),
        ("punctuation", ")"),
        ("punctuation", ")"),
    )
    if name_index == 0 or (tokens[name_index - 1].kind, tokens[name_index - 1].text) != (
        "punctuation",
        ".",
    ):
        return False
    call_tokens = tokens[name_index + 1 : name_index + 1 + len(expected)]
    return len(call_tokens) == len(expected) and all(
        (token.kind, token.text) == item for token, item in zip(call_tokens, expected)
    )


def _scan_file(path: Path) -> list[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        return [f"{path}:1: cannot read Swift source: {error}"]

    try:
        tokens = SwiftLexer(source).tokenize()
    except LexError as error:
        return [f"{path}:{error.line}: {error}"]

    diagnostics = []
    for index, token in enumerate(tokens):
        if token.kind != "identifier" or token.text != "timeLimit":
            continue
        if index + 1 >= len(tokens) or tokens[index + 1].text != "(":
            continue
        if index > 0 and tokens[index - 1].text == "func":
            continue
        if not _is_canonical_time_limit(tokens, index):
            diagnostics.append(
                f"{path}:{token.line}: timeLimit call must be .timeLimit(.minutes({HANG_GUARD_MINUTES}))"
            )
    return diagnostics


def scan(root: Path) -> list[str]:
    """Return diagnostics as `path:line: message` strings for a repository root."""
    root = Path(root)
    if not root.is_dir():
        return [f"{root}:1: repository root does not exist or is not a directory"]

    tests_root = root / "app" / "MacAmbientJev" / "Tests"
    if not tests_root.is_dir():
        return [f"{tests_root}:1: no Swift files found"]

    def raise_walk_error(error: OSError) -> None:
        raise error

    swift_files: list[Path] = []
    try:
        for directory, _, filenames in os.walk(tests_root, onerror=raise_walk_error):
            swift_files.extend(Path(directory) / name for name in filenames if name.endswith(".swift"))
    except OSError as error:
        error_path = error.filename or tests_root
        return [f"{error_path}:1: cannot scan Swift tests: {error}"]

    swift_files.sort()
    if not swift_files:
        return [f"{tests_root}:1: no Swift files found"]

    diagnostics: list[str] = []
    for path in swift_files:
        diagnostics.extend(_scan_file(path))
    return diagnostics


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository_root", nargs="?", type=Path, help="repository root to scan")
    arguments = parser.parse_args(argv)
    root = arguments.repository_root or Path(__file__).resolve().parents[1]

    diagnostics = scan(root)
    if diagnostics:
        for diagnostic in diagnostics:
            print(diagnostic, file=sys.stderr)
        return 1
    print("Swift Testing time-limit checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
