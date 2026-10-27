#!/usr/bin/env python3
"""Create a compact, broadly compatible Deflate ZIP for a release directory."""

from __future__ import annotations

import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: create_release_zip.py <source-directory> <destination.zip>", file=sys.stderr)
        return 2

    source = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    if not source.is_dir():
        print(f"source directory does not exist: {source}", file=sys.stderr)
        return 2

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()

    files = sorted(path for path in source.rglob("*") if path.is_file() and path.resolve() != destination)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            archive.write(path, path.relative_to(source).as_posix())

    print(f"ZIP compression: Deflate level 9; files: {len(files)}")
    print(f"ZIP size: {destination.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
