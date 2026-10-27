#!/usr/bin/env python3
"""Move every language but English and Turkish out of a Windows/Linux publish folder.

Each language becomes one JSON file of key -> text, named by its sha256, in the
packs folder; upload those to R2 under downloads/languages/. The publish folder gets
`language-packs.json` (code -> sha256) and loses the language's satellite assembly,
so the app downloads the pack the first time the language is chosen
(LanguagePacks in shared/Localization.cs). The macOS counterpart is in
macos/DotsHarness/scripts/package-dmg.sh.

    python3 tools/build_language_packs.py <publish dir> <packs dir>
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_localization import read_resx  # noqa: E402

SHARED = Path(__file__).resolve().parent.parent / "shared"
BUNDLED = {"tr"}
SATELLITE = "DotsHarnessCore.resources.dll"


def pack(resx: Path) -> bytes:
    # Sorted and compact, so the same copy hashes the same on every platform.
    return json.dumps(dict(sorted(read_resx(resx).items())), ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def main(publish: Path, packs: Path) -> int:
    packs.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, str] = {}
    for resx in sorted(SHARED.glob("Localization.*.resx")):
        code = resx.name[len("Localization."):-len(".resx")]
        if code in BUNDLED:
            continue
        data = pack(resx)
        sha = hashlib.sha256(data).hexdigest()
        (packs / f"{sha}.json").write_bytes(data)
        manifest[code] = sha
        satellite = publish / code / SATELLITE
        satellite.unlink(missing_ok=True)
        if satellite.parent.is_dir() and not any(satellite.parent.iterdir()):
            satellite.parent.rmdir()
    (publish / "language-packs.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"{len(manifest)} language packs -> {packs}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
