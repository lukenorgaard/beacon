#!/usr/bin/env python3
"""Create a reproducible source handoff without local builds or session logs."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
FILES = (
    "Package.swift", "README.md", "CONTRIBUTING.md", "CHANGELOG.md", "SECURITY.md",
    "LICENSE", ".gitignore", "START-HERE.md", "docs/README.md", "docs/SOURCE-MAP.md",
    "docs/INSTALL.md", "docs/SENTINEL.md", "docs/REPORTER.md",
)
DIRECTORIES = (
    "Sources", "hooks", "scripts", "companion", "tests", ".github",
    "docs/screenshots", "docs/history",
)
EXCLUDED_PARTS = {"__pycache__", "node_modules", ".DS_Store"}


def source_files():
    paths = {ROOT / name for name in FILES}
    for directory in DIRECTORIES:
        paths.update(path for path in (ROOT / directory).rglob("*") if path.is_file())
    # A checkout may contain private scratch files under source folders. Never silently ship them.
    inventory = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                               capture_output=True, check=False)
    tracked = set(inventory.stdout.decode().split("\0")) if inventory.returncode == 0 else None
    result = []
    for path in sorted(paths):
        relative = path.relative_to(ROOT)
        if EXCLUDED_PARTS.intersection(relative.parts) or path.suffix in {".pyc", ".pyo"}:
            continue
        if tracked is not None and relative.as_posix() not in tracked:
            raise ValueError("Review and track source before packaging: %s" % relative)
        if path.is_symlink() or not path.is_file():
            raise ValueError("Expected a regular source file: %s" % relative)
        result.append(path)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/Beacon-1.4-source.zip")
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / "scripts/check-code-size.py")], check=True)
    files = source_files()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checksum_lines = []
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            name = "Beacon/" + path.relative_to(ROOT).as_posix()
            data = path.read_bytes()
            # Fixed timestamps and explicit permissions make identical sources reproducible.
            info = zipfile.ZipInfo(name, (2026, 9, 10, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100000 | (path.stat().st_mode & 0o777)) << 16
            archive.writestr(info, data)
            checksum_lines.append("%s  %s" % (hashlib.sha256(data).hexdigest(), path.relative_to(ROOT).as_posix()))
        info = zipfile.ZipInfo("Beacon/SHA256SUMS", (2026, 9, 10, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, "\n".join(checksum_lines) + "\n")
    with zipfile.ZipFile(args.output) as archive:
        if archive.testzip() is not None:
            raise ValueError("Archive integrity check failed")
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.output.with_suffix(args.output.suffix + ".sha256").write_text(
        "%s  %s\n" % (digest, args.output.name)
    )
    print("Packed %d source files: %s" % (len(files), args.output))
    print("SHA-256: %s" % digest)


if __name__ == "__main__":
    main()
