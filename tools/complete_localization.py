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
from translation_catalog import MAC_ENGLISH, MAC_TRANSLATIONS, SHARED_KEYS, SHARED_TRANSLATIONS  # noqa: E402

STRINGS_ENTRY = re.compile(r'^(\s*)"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')
RESX_DATA = re.compile(
    r'(<data\s+name="(?P<key>[^"]+)"[^>]*>\s*<value>)(?P<value>.*?)(</value>)',
    re.DOTALL,
)
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(?:lld|[dfs@])")
UNTRANSLATED_KEYS: set[str] = set()


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


def update_english() -> int:
    """Append English source values for keys moved out of the native code."""
    mac_path = MAC_RESOURCES / "en.lproj" / "Localizable.strings"
    mac_existing = read_strings(mac_path)
    mac_missing = [key for key in MAC_ENGLISH if key not in mac_existing]
    if mac_missing:
        lines = ["", "// UI copy moved out of the native shells (tools/ui_catalog.py)."]
        lines.extend(f'"{key}" = "{escape_strings(MAC_ENGLISH[key])}";' for key in mac_missing)
        mac_path.write_text(mac_path.read_text(encoding="utf-8").rstrip("\n") + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
    resx_path = SHARED / "Localization.resx"
    text = resx_path.read_text(encoding="utf-8")
    shared_existing = read_resx(resx_path)
    resx_missing = [key for key in SHARED_KEYS if key not in shared_existing]
    if resx_missing:
        additions = []
        for key in resx_missing:
            # Existing macOS strings are reused by the desktop shells even when
            # they were not part of the generated MAC_UI catalog.
            english = MAC_ENGLISH.get(key) or mac_existing.get(key)
            if english is None:
                raise ValueError(f"{resx_path}: no English source supplied for {key}")
            additions.append(f'  <data name="{key}" xml:space="preserve"><value>{resx_value(english)}</value></data>')
        additions = "\n".join(additions)
        resx_path.write_text(text.replace("</root>", additions + "\n</root>"), encoding="utf-8")
    return len(mac_missing) + len(resx_missing)


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
    missing_translations = [key for key in missing if key in MAC_TRANSLATIONS]
    UNTRANSLATED_KEYS.update(key for key in missing if key not in MAC_TRANSLATIONS)
    if locale != "en" and missing_translations:
        lines.extend(["", "// Completed translations for keys added to the desktop catalog."])
        for key in missing_translations:
            lines.append(f'"{key}" = "{escape_strings(MAC_TRANSLATIONS[key][locale])}";')
        changed += len(missing_translations)
    if changed:
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return changed


def update_resx(locale: str) -> int:
    path = SHARED / f"Localization.{locale}.resx"
    text = path.read_text(encoding="utf-8")
    existing = read_resx(path)
    translations = {**MAC_TRANSLATIONS, **SHARED_TRANSLATIONS}
    changed = 0

    def replace(match: re.Match[str]) -> str:
        nonlocal changed
        key = match.group("key")
        if key not in translations:
            return match.group(0)
        translated = resx_value(translations[key][locale])
        if translated == match.group("value"):
            return match.group(0)
        changed += 1
        return match.group(1) + translated + match.group(4)

    updated = RESX_DATA.sub(replace, text)
    if set(existing) != set(read_resx(path)):
        raise ValueError(f"{path}: source changed while updating")
    base = read_resx(SHARED / "Localization.resx")
    mac_base = read_strings(MAC_RESOURCES / "en.lproj" / "Localizable.strings")
    mac_values = read_strings(MAC_RESOURCES / f"{locale}.lproj" / "Localizable.strings")
    missing = [key for key in base if key not in existing]
    additions: list[str] = []
    if missing:
        for key in missing:
            if key in translations:
                raw_value = translations[key][locale]
            elif mac_base.get(key) == base[key] and key in mac_values:
                # Shared desktop shells can reuse an existing macOS value when
                # both English sources are identical.
                raw_value = mac_values[key]
            else:
                UNTRANSLATED_KEYS.add(key)
                continue
            value = resx_value(raw_value)
            additions.append(f'  <data name="{key}" xml:space="preserve"><value>{value}</value></data>')
    if additions:
        updated = updated.replace("</root>", "\n".join(additions) + "\n</root>")
        changed += len(additions)
    if changed:
        path.write_text(updated, encoding="utf-8")
    return changed


def main() -> None:
    english_changed = update_english()
    mac_changed = sum(update_strings(locale) for locale in MAC_LOCALES if locale != "en")
    shared_changed = sum(update_resx(locale) for locale in SHARED_LOCALES)
    print(f"added {english_changed} English entries, updated {mac_changed} macOS entries and {shared_changed} shared entries")
    if UNTRANSLATED_KEYS:
        print(f"skipped keys without reviewed translations: {', '.join(sorted(UNTRANSLATED_KEYS))}", file=sys.stderr)


if __name__ == "__main__":
    main()
