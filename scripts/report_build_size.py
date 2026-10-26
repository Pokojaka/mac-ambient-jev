"""Print the total size in bytes of the regular files under a directory, without following links or junctions."""

from __future__ import annotations

import os
import sys


def tree_size(root: str) -> int:
    total = 0
    stack = [root]
    while stack:
        with os.scandir(stack.pop()) as entries:
            for entry in entries:
                if entry.is_symlink() or entry.is_junction():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
                elif entry.is_file(follow_symlinks=False):
                    total += entry.stat(follow_symlinks=False).st_size
    return total


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: report_build_size.py <directory>", file=sys.stderr)
        return 2
    if not os.path.isdir(argv[0]):
        print(f"ERROR: not a directory: {argv[0]}", file=sys.stderr)
        return 1
    print(tree_size(argv[0]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
