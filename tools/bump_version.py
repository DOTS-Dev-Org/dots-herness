#!/usr/bin/env python3
"""Manage and synchronize DOTS HerNess application versions across all platforms."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
VERSION_TS = ROOT / "cloudflare" / "src" / "routes" / "api" / "version.ts"

SEMVER_PATTERN = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")


def read_current_version() -> str:
    if not VERSION_FILE.exists():
        return "0.1.0"
    return VERSION_FILE.read_text(encoding="utf-8").strip()


def parse_semver(version: str) -> tuple[int, int, int, str]:
    match = SEMVER_PATTERN.match(version)
    if not match:
        raise ValueError(f"Geçersiz SemVer biçimi: '{version}'. Beklenen: X.Y.Z")
    major, minor, patch, pre = match.groups()
    return int(major), int(minor), int(patch), pre or ""


def bump_version(current: str, part: str) -> str:
    major, minor, patch, _ = parse_semver(current)
    if part == "major":
        return f"{major + 1}.0.0"
    elif part == "minor":
        return f"{major}.{minor + 1}.0"
    elif part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    else:
        raise ValueError(f"Geçersiz sürüm artırma tipi: '{part}'. Seçenekler: patch, minor, major")


# (path, regex with 2 groups around the version, applies to whole file)
_SH = r'(VERSION="\$\{VERSION:-)[^}]+(\}")'
_PROPS = r"(<Version>)[^<]+(</Version>)"
TARGETS = [
    (ROOT / "macos/DotsHarness/scripts/package-dmg.sh", _SH),
    (ROOT / "linux/DotsHarness/scripts/package-tar.sh", _SH),
    (ROOT / "windows/DotsHarness/scripts/package-zip.sh", _SH),
    (ROOT / "linux/DotsHarness/Directory.Build.props", _PROPS),
    (ROOT / "windows/DotsHarness/Directory.Build.props", _PROPS),
    # CFBundleVersion / build numbers are integers and are NOT synced here.
    (ROOT / "macos/DotsHarness/run.sh", r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)"),
    (ROOT / "mobile/ios/Info.plist", r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)"),
    (ROOT / "mobile/android/app/build.gradle.kts", r'(versionName = ")[^"]+(")'),
    (VERSION_TS, r'((?:export\s+)?const DEFAULT_APP_VERSION = ")[^"]+(";)'),
]


def sync_version(version: str) -> list[str]:
    VERSION_FILE.write_text(f"{version}\n", encoding="utf-8")
    updated = [str(VERSION_FILE.relative_to(ROOT))]
    for path, pattern in TARGETS:
        if not path.exists():
            print(f"UYARI: bulunamadı: {path.relative_to(ROOT)}", file=sys.stderr)
            continue
        content = path.read_text(encoding="utf-8")
        new_content, n = re.subn(pattern, lambda m: f"{m.group(1)}{version}{m.group(2)}", content)
        if n == 0:
            print(f"UYARI: desen eşleşmedi: {path.relative_to(ROOT)}", file=sys.stderr)
        if new_content != content:
            path.write_text(new_content, encoding="utf-8")
            updated.append(str(path.relative_to(ROOT)))
    return updated


def main() -> None:
    parser = argparse.ArgumentParser(description="DOTS HerNess sürüm yönetimi")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--show", action="store_true", help="Mevcut sürümü göster")
    group.add_argument("--bump", choices=["patch", "minor", "major"], help="Sürümü artır ve senkronize et")
    group.add_argument("--set", dest="set_version", help="Belirli bir sürüm ayarla ve senkronize et")
    group.add_argument("--sync", action="store_true", help="Mevcut sürümü tüm platform dosyalarına uygula")

    args = parser.parse_args()
    current = read_current_version()

    if args.show or (not args.bump and not args.set_version and not args.sync):
        print(f"Mevcut Sürüm: {current}")
        return

    if args.bump:
        new_version = bump_version(current, args.bump)
        print(f"Sürüm yükseltiliyor: {current} -> {new_version} ({args.bump})")
    elif args.set_version:
        parse_semver(args.set_version)  # validate
        new_version = args.set_version
        print(f"Sürüm ayarlanıyor: {current} -> {new_version}")
    else:
        new_version = current
        print(f"Sürüm senkronize ediliyor: {new_version}")

    updated = sync_version(new_version)
    print(f"Senkronize edilen dosyalar ({len(updated)}):")
    for f in updated:
        print(f"  - {f}")


if __name__ == "__main__":
    main()
