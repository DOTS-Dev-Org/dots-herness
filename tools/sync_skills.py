#!/usr/bin/env python3
"""Copy the cross-platform bundled skills from shared/skills into the macOS bundle.

Windows and Linux link shared/skills straight from their csproj files. SwiftPM
resources must live inside the target directory, so macOS keeps a copy; this
script is what keeps that copy identical. Run it after editing a shared skill:

    python3 tools/sync_skills.py            # rewrite the macOS copy
    python3 tools/sync_skills.py --check    # fail if the macOS copy is stale

Platform-specific skills (device-verification) are not in shared/skills and are
left alone in each platform's own Resources/skills folder.
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "shared" / "skills"
TARGETS = [
    ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources" / "skills",
]


def files(directory: Path) -> dict[str, bytes]:
    if not directory.is_dir():
        return {}
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    skills = sorted(path for path in SOURCE.iterdir() if path.is_dir())
    stale = []
    for target in TARGETS:
        for skill in skills:
            destination = target / skill.name
            if files(skill) == files(destination):
                continue
            stale.append(destination.relative_to(ROOT).as_posix())
            if not check:
                if destination.exists():
                    shutil.rmtree(destination)
                shutil.copytree(skill, destination)

    if check and stale:
        print("Stale skill copies (run python3 tools/sync_skills.py):", file=sys.stderr)
        for path in stale:
            print(f"  {path}", file=sys.stderr)
        return 1
    for path in stale:
        print(f"updated {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
