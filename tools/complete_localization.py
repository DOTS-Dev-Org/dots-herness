#!/usr/bin/env python3
"""Apply the reviewed translation catalog to every desktop/shared locale."""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "shared"
MAC_RESOURCES = ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_localization import MAC_LOCALES, SHARED_LOCALES, read_resx, read_strings  # noqa: E402
from translation_catalog import MAC_TRANSLATIONS  # noqa: E402

STRINGS_ENTRY = re.compile(r'^(\s*)"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
RESX_DATA = re.compile(
    r'(<data\s+name="(?P<key>[^"]+)"[^>]*>\s*<value>)(?P<value>.*?)(</value>)',
    re.DOTALL,
)
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(?:lld|[dfs@])")


def escape_strings(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def resx_value(value: str) -> str:
    next_index = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal next_index
        explicit = match.group(1)
        index = int(explicit) - 1 if explicit else next_index
        next_index = max(next_index, index + 1)
        return "{" + str(index) + "}"

    return html.escape(PLACEHOLDER.sub(replace, value), quote=False)


def update_strings(locale: str) -> int:
    path = MAC_RESOURCES / f"{locale}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    base = read_strings(MAC_RESOURCES / "en.lproj" / "Localizable.strings")
    existing = read_strings(path)
    missing = [key for key in base if key not in existing]
    changed = 0
    lines: list[str] = []
    for line in text.splitlines():
        match = STRINGS_ENTRY.match(line)
        if not match:
            lines.append(line)
            continue
        indent, key, _ = match.groups()
        if locale != "en" and key in MAC_TRANSLATIONS:
            value = MAC_TRANSLATIONS[key][locale]
            replacement = f'{indent}"{key}" = "{escape_strings(value)}";'
            if replacement != line:
                changed += 1
            lines.append(replacement)
        else:
            lines.append(line)
    if locale != "en" and missing:
        lines.extend(["", "// Completed translations for keys added to the desktop catalog."])
        for key in missing:
            if key not in MAC_TRANSLATIONS:
                raise ValueError(f"{path}: no translation supplied for {key}")
            lines.append(f'"{key}" = "{escape_strings(MAC_TRANSLATIONS[key][locale])}";')
        changed += len(missing)
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changed


def update_resx(locale: str) -> int:
    path = SHARED / f"Localization.{locale}.resx"
    text = path.read_text(encoding="utf-8")
    existing = read_resx(path)
    changed = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal changed
        key = match.group("key")
        if key not in MAC_TRANSLATIONS:
            return match.group(0)
        translated = resx_value(MAC_TRANSLATIONS[key][locale])
        if translated == match.group("value"):
            return match.group(0)
        changed += 1
        return match.group(1) + translated + match.group(4)

    updated = RESX_DATA.sub(replace, text)
    if set(existing) != set(read_resx(path)):
        raise ValueError(f"{path}: source changed while updating")
    if changed:
        path.write_text(updated, encoding="utf-8")
    return changed


def main() -> None:
    mac_changed = sum(update_strings(locale) for locale in MAC_LOCALES if locale != "en")
    shared_changed = sum(update_resx(locale) for locale in SHARED_LOCALES)
    print(f"updated {mac_changed} macOS entries and {shared_changed} shared entries")


if __name__ == "__main__":
    main()
