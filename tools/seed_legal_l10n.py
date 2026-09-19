#!/usr/bin/env python3
"""Seed the `legal.*` UI string keys into every shared .resx and macOS .strings
locale file. TR and EN get real translations; the other 28 locales get the EN
value as a fallback (translate later). Idempotent: existing keys are left alone.

Run once after changing STRINGS below, then `tools/check_localization.py --check`.
"""

from __future__ import annotations

import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ROOT / "shared"
MAC_RES = ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources"

SHARED_LOCALES = (
    "tr", "de", "es", "fr", "it", "ja", "ko", "nl", "pt", "ru", "zh-Hans",
    "ar", "bn", "hi", "id", "vi", "ur", "mr", "te", "ta", "fa", "pl", "uk",
    "th", "ms", "ro", "el", "cs", "hu",
)

# key -> (en, tr)
STRINGS: dict[str, tuple[str, str]] = {
    "legal.title": ("Legal & Privacy", "Yasal ve Gizlilik"),
    "legal.gateHeading": ("Before you start", "Başlamadan önce"),
    "legal.gateIntro": (
        "Please review the User Agreement and the Privacy Policy. Your conversation "
        "and workspace content is sent to the AI provider you choose, which may be "
        "located outside your country.",
        "Lütfen Kullanıcı Sözleşmesi'ni ve Gizlilik Politikası'nı inceleyin. "
        "Konuşma ve çalışma alanı içeriğiniz, seçtiğiniz ve yurt dışında bulunabilecek "
        "yapay zeka sağlayıcısına iletilir.",
    ),
    "legal.termsTab": ("User Agreement", "Kullanıcı Sözleşmesi"),
    "legal.privacyTab": ("Privacy Policy", "Gizlilik Politikası"),
    "legal.acceptRequired": (
        "I have read and accept the User Agreement and the Privacy Policy.",
        "Kullanıcı Sözleşmesi'ni ve Gizlilik Politikası'nı okudum, kabul ediyorum.",
    ),
    "legal.accept": ("Continue", "İleri"),
    "legal.acceptHint": (
        "By pressing Continue, you accept the User Agreement and Privacy Policy.",
        "İleri'ye basarak Kullanıcı Sözleşmesi'ni ve Gizlilik Politikası'nı kabul etmiş olursunuz.",
    ),
    "legal.openWeb": ("Open on the web", "Web'de aç"),
    "legal.consentHeading": ("Optional permissions", "İsteğe bağlı izinler"),
    "legal.consentPrefs": ("Consent preferences", "Rıza tercihleri"),
    "legal.consent.aiTransfer": (
        "Send my prompts and the files I choose to the AI provider so AI features "
        "work (required; involves transfer abroad).",
        "Yapay zeka özelliklerinin çalışması için istemlerimin ve seçtiğim dosyaların "
        "yapay zeka sağlayıcısına gönderilmesi (gereklidir; yurt dışına aktarım içerir).",
    ),
    "legal.consent.github": (
        "Allow GitHub integration to transfer my repository data when I connect it.",
        "GitHub hesabımı bağladığımda depo verilerimin GitHub'a aktarılmasına izin veriyorum.",
    ),
    "legal.consent.voice": (
        "Allow voice input processing and speech-to-text conversion.",
        "Ses girişinin işlenmesine ve konuşma-metin dönüşümüne izin veriyorum.",
    ),
    "legal.consent.marketing": (
        "Send me product news and campaigns by email.",
        "E-posta ile ürün duyuruları ve kampanyalar gönderilmesini istiyorum.",
    ),
    "legal.updated": (
        "The legal documents have been updated. Please review and accept them again.",
        "Yasal metinler güncellendi. Lütfen tekrar inceleyip onaylayın.",
    ),
    "legal.loadError": (
        "Could not load the legal documents. Check your connection and try again.",
        "Yasal metinler yüklenemedi. Bağlantınızı kontrol edip tekrar deneyin.",
    ),
    "legal.retry": ("Try again", "Tekrar dene"),
}


def val_for(locale: str, en: str, tr: str) -> str:
    return tr if locale == "tr" else en


def seed_resx(path: Path, locale: str) -> int:
    text = path.read_text(encoding="utf-8")
    added = 0
    lines = []
    for key, (en, tr) in STRINGS.items():
        if f'name="{key}"' in text:
            continue
        v = html.escape(val_for(locale, en, tr), quote=False)
        lines.append(
            f'  <data name="{key}" xml:space="preserve"><value>{v}</value></data>'
        )
        added += 1
    if added:
        text = text.replace("</root>", "\n".join(lines) + "\n</root>")
        path.write_text(text, encoding="utf-8")
    return added


def esc_strings(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def seed_strings(path: Path, locale: str) -> int:
    text = path.read_text(encoding="utf-8")
    added = 0
    out = []
    for key, (en, tr) in STRINGS.items():
        if re.search(rf'^\s*"{re.escape(key)}"\s*=', text, re.M):
            continue
        v = esc_strings(val_for(locale, en, tr))
        out.append(f'"{key}" = "{v}";')
        added += 1
    if added:
        if not text.endswith("\n"):
            text += "\n"
        path.write_text(text + "\n".join(out) + "\n", encoding="utf-8")
    return added


def main() -> None:
    total = 0
    total += seed_resx(SHARED / "Localization.resx", "en")
    for loc in SHARED_LOCALES:
        total += seed_resx(SHARED / f"Localization.{loc}.resx", loc)
    for loc in ("en",) + SHARED_LOCALES:
        total += seed_strings(MAC_RES / f"{loc}.lproj" / "Localizable.strings", loc)
    print(f"seeded {total} entries across locale files")


if __name__ == "__main__":
    main()
