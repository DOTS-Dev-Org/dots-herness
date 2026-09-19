#!/usr/bin/env python3
"""Check parity between all native mobile localization catalogs."""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "mobile/localization/languages.json"
IOS = ROOT / "mobile/ios/Resources"
ANDROID = ROOT / "mobile/android/app/src/main/res"
ENTRY = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|[dfs@])")

REQUIRED = {
    "intro.eyebrow.connect", "intro.title.connect", "intro.description.connect",
    "intro.eyebrow.agent", "intro.title.agent", "intro.description.agent",
    "intro.eyebrow.ship", "intro.title.ship", "intro.description.ship",
    "intro.skip", "intro.back", "intro.continue", "intro.start", "intro.language",
    "intro.languageAccessibility", "intro.languageSystem", "intro.page",
    "mobile.splash.logo", "mobile.splash.buildLine", "mobile.connection.title", "app.ok",
}


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


def read_strings(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("/*") or line.endswith("*/"):
            continue
        match = ENTRY.match(raw_line)
        if not match:
            raise ValueError(f"{path}:{number}: malformed .strings entry")
        key, value = (unescape(part) for part in match.groups())
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    return values


def read_android(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for item in ET.parse(path).getroot().findall("string"):
        name = item.get("name")
        if not name:
            raise ValueError(f"{path}: string without name")
        if name in values:
            raise ValueError(f"{path}: duplicate resource {name}")
        values[name] = "".join(item.itertext())
    return values


def android_name(key: str) -> str:
    camel = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", key)
    return re.sub(r"[^A-Za-z0-9_]", "_", camel).lower()


def main() -> int:
    if sys.argv[1:] != ["--check"]:
        print("usage: check_mobile_localization.py --check", file=sys.stderr)
        return 2
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    locales = [item["code"] for item in manifest["languages"]]
    errors: list[str] = []
    ios_values: dict[str, dict[str, str]] = {}
    android_values: dict[str, dict[str, str]] = {}

    for locale in locales:
        ios_path = IOS / f"{locale}.lproj" / "Localizable.strings"
        android_dir = "values" if locale == "en" else "values-b+zh+Hans" if locale == "zh-Hans" else f"values-{locale}"
        android_path = ANDROID / android_dir / "strings.xml"
        if not ios_path.is_file(): errors.append(f"missing iOS catalog: {ios_path.relative_to(ROOT)}")
        if not android_path.is_file(): errors.append(f"missing Android catalog: {android_path.relative_to(ROOT)}")
        if not ios_path.is_file() or not android_path.is_file(): continue
        try: ios_values[locale] = read_strings(ios_path)
        except (OSError, ValueError) as error: errors.append(str(error)); continue
        try: android_values[locale] = read_android(android_path)
        except (OSError, ET.ParseError, ValueError) as error: errors.append(str(error)); continue

    if len(ios_values) != len(locales): errors.append(f"expected {len(locales)} iOS locales, got {len(ios_values)}")
    if len(android_values) != len(locales): errors.append(f"expected {len(locales)} Android locales, got {len(android_values)}")

    base = ios_values.get("en", {})
    base_android = android_values.get("en", {})
    for locale, values in ios_values.items():
        missing = sorted(set(base) - set(values)); extra = sorted(set(values) - set(base))
        if missing: errors.append(f"iOS {locale}: missing keys: {', '.join(missing)}")
        if extra: errors.append(f"iOS {locale}: unexpected keys: {', '.join(extra)}")
        for key in set(base) & set(values):
            if Counter(PLACEHOLDER.findall(base[key])) != Counter(PLACEHOLDER.findall(values[key])):
                errors.append(f"iOS {locale}: placeholder mismatch for {key}")
    for locale, values in android_values.items():
        expected = {android_name(key): value for key, value in base.items()}
        missing = sorted(set(expected) - set(values)); extra = sorted(set(values) - set(expected))
        if missing: errors.append(f"Android {locale}: missing keys: {', '.join(missing)}")
        if extra: errors.append(f"Android {locale}: unexpected keys: {', '.join(extra)}")
        for key in set(expected) & set(values):
            if Counter(PLACEHOLDER.findall(expected[key])) != Counter(PLACEHOLDER.findall(values[key])):
                errors.append(f"Android {locale}: placeholder mismatch for {key}")

    for key in sorted(REQUIRED):
        if key not in base: errors.append(f"English iOS catalog: missing required key {key}")
        if android_name(key) not in base_android: errors.append(f"English Android catalog: missing required key {android_name(key)}")

    if errors:
        print("mobile localization check failed:")
        print("\n".join(f"  {error}" for error in errors))
        return 1
    print(f"mobile localization in sync: {len(locales)} locales, {len(base)} keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
