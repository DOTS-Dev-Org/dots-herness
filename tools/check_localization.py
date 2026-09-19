#!/usr/bin/env python3
"""Validate desktop localization key sets and format placeholders."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "shared"
MAC_RESOURCES = ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources"

SHARED_LOCALES = (
    "tr", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-Hans",
    "ar", "bn", "hi", "id", "vi", "ur", "mr", "te", "ta", "fa", "pl", "uk",
    "th", "ms", "ro", "el", "cs", "hu",
)
MAC_LOCALES = ("en",) + SHARED_LOCALES

STRINGS_ENTRY = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
RESX_PLACEHOLDER = re.compile(r"\{(\d+)\}")
STRINGS_PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|[dfs@])")


def unescape(value: str) -> str:
    result: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
    while index < len(value):
        if value[index] != "\\" or index + 1 == len(value):
            result.append(value[index])
            index += 1
            continue
        index += 1
        result.append(escapes.get(value[index], value[index]))
        index += 1
    return "".join(result)


def read_resx(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for data in ET.parse(path).getroot().findall("data"):
        key = data.get("name")
        if not key:
            continue
        if key in values:
            raise ValueError(f"{path}: duplicate key {key}")
        values[key] = data.findtext("value") or ""
    return values


def read_strings(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    in_comment = False
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if in_comment:
            if "*/" in line:
                in_comment = False
            continue
        if line.startswith("/*"):
            if "*/" not in line[2:]:
                in_comment = True
            continue
        if not line or line.startswith("//"):
            continue
        match = STRINGS_ENTRY.match(raw_line)
        if not match:
            raise ValueError(f"{path}:{number}: malformed .strings entry")
        key, value = (unescape(item) for item in match.groups())
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    if in_comment:
        raise ValueError(f"{path}: unterminated block comment")
    return values


def compare(
    label: str,
    base_path: Path,
    base: dict[str, str],
    path: Path,
    values: dict[str, str],
    placeholder_pattern: re.Pattern[str],
    errors: list[str],
) -> None:
    missing = sorted(base.keys() - values.keys())
    extra = sorted(values.keys() - base.keys())
    if missing:
        errors.append(f"{label}: missing keys: {', '.join(missing)}")
    if extra:
        errors.append(f"{label}: unexpected keys: {', '.join(extra)}")
    for key in sorted(base.keys() & values.keys()):
        expected = Counter(placeholder_pattern.findall(base[key]))
        actual = Counter(placeholder_pattern.findall(values[key]))
        if expected != actual:
            errors.append(
                f"{label}: placeholder mismatch for {key}: "
                f"expected {dict(expected)}, got {dict(actual)}"
            )


def check_resx(errors: list[str]) -> None:
    base_path = SHARED / "Localization.resx"
    try:
        base = read_resx(base_path)
    except (OSError, ET.ParseError, ValueError) as error:
        errors.append(str(error))
        return
    for locale in SHARED_LOCALES:
        path = SHARED / f"Localization.{locale}.resx"
        if not path.is_file():
            errors.append(f"shared/{path.name}: supported locale file is missing")
            continue
        try:
            values = read_resx(path)
        except (OSError, ET.ParseError, ValueError) as error:
            errors.append(str(error))
            continue
        compare(path.name, base_path, base, path, values, RESX_PLACEHOLDER, errors)


def check_strings(errors: list[str]) -> None:
    base_path = MAC_RESOURCES / "en.lproj" / "Localizable.strings"
    try:
        base = read_strings(base_path)
    except (OSError, ValueError) as error:
        errors.append(str(error))
        return
    for locale in MAC_LOCALES:
        path = MAC_RESOURCES / f"{locale}.lproj" / "Localizable.strings"
        if not path.is_file():
            errors.append(f"macos/{locale}.lproj/Localizable.strings: supported locale file is missing")
            continue
        if locale == "en":
            continue
        try:
            values = read_strings(path)
        except (OSError, ValueError) as error:
            errors.append(str(error))
            continue
        compare(str(path.relative_to(ROOT)), base_path, base, path, values, STRINGS_PLACEHOLDER, errors)


def main() -> int:
    if sys.argv[1:] != ["--check"]:
        print("usage: check_localization.py --check", file=sys.stderr)
        return 2
    errors: list[str] = []
    check_resx(errors)
    check_strings(errors)
    if errors:
        print("localization check failed:")
        print("\n".join(f"  {error}" for error in errors))
        return 1
    print("localization in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
