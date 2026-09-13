#!/usr/bin/env python3
"""Enforce the 500-line limit, counting comments and blank lines too."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 500
CODE_SUFFIXES = {".swift", ".py", ".sh", ".js", ".json", ".yml", ".yaml"}
CODE_ROOTS = ("Sources", "hooks", "scripts", "companion", "tests", ".github")
EXCLUDED_PARTS = {"__pycache__", "node_modules", "fixtures"}


def code_files(root=ROOT):
    yield root / "Package.swift"
    for directory in CODE_ROOTS:
        for path in sorted((root / directory).rglob("*")):
            if not path.is_file() or EXCLUDED_PARTS.intersection(path.relative_to(root).parts):
                continue
            if path.suffix in CODE_SUFFIXES or path.name == "postinstall":
                yield path


def main():
    counts = [(len(path.read_text().splitlines()), path) for path in code_files()]
    oversized = [(count, path) for count, path in counts if count > LIMIT]
    for count, path in oversized:
        print("%s: %d lines (limit %d)" % (path.relative_to(ROOT), count, LIMIT))
    largest = max(counts, key=lambda item: item[0])
    print("Checked %d code/config files; largest: %s (%d lines)." % (
        len(counts), largest[1].relative_to(ROOT), largest[0]
    ))
    return bool(oversized)


if __name__ == "__main__":
    sys.exit(main())
