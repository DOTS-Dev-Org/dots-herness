---
id: map
title: Project map
type: map
updated: 2026-10-27T11:29:41Z
tags: [map]
links: ["index"]
---
# Project Map

## Workspace

- Stack: .NET, Android, Cloudflare Workers, Hono, Python, Swift, TypeScript

## Top-level

- `.codex/`
- `.github/`
- `.gitignore`
- `AGENTS.md`
- `CLAUDE.md`
- `LICENSE`
- `README.md`
- `VERSION`
- `browser-extension/`
- `cloudflare/`
- `docs/`
- `ios/`
- `linux/`
- `macos/`
- `mobile/`
- `native/`
- `output/`
- `shared/`
- `tools/`
- `windows/`

## Important files

- `README.md`

## Structure
Folders two levels deep: what each holds, the files to open first. Start from these instead of listing or searching the workspace.
- root - open: README.md
- `.codex/` - mostly .md
  - `.codex/skills/` - mostly .md
- `.github/` - mostly .yml
  - `.github/workflows/` - mostly .yml
- `browser-extension/` - This MV3 extension is the explicit `Extension` backend. It owns only tabs - open: README.md
- `cloudflare/` - Node package, mostly .ts, .sql - open: package.json, wrangler.jsonc
  - `cloudflare/src/` - mostly .ts - open: index.ts
  - `cloudflare/migrations/` - mostly .sql, .md
  - `cloudflare/scripts/` - mostly .mjs, .sh
  - `cloudflare/help-page/` - Cloudflare Worker, mostly .json, .jsonc - open: wrangler.jsonc
- `docs/` - mostly .md, .json
  - `docs/legal/` - Uygulamanın Gizlilik Politikası ve Kullanıcı Sözleşmesi metinleri **uygulamaya - open: README.md
- `ios/` - mostly .sh
- `linux/` - mostly .png, .cs
  - `linux/DotsHarness/` - The Avalonia shell uses the same shared .NET 8 native provider core as the - open: README.md, DotsHarness.sln
  - `linux/scripts/` - mostly .sh
- `macos/` - mostly .swift, .strings
  - `macos/DotsHarness/` - The macOS app is a native SwiftUI application. Provider accounts, direct - open: README.md, Package.swift
  - `macos/scripts/` - mostly .sh
- `mobile/` - The mobile app is local-first. After onboarding it opens the local workspace - open: README.md
  - `mobile/ios/` - XcodeGen project, mostly .png, .swift - open: project.yml
  - `mobile/android/` - Gradle project, mostly .kt, .xml - open: build.gradle.kts, settings.gradle.kts
  - `mobile/native/` - mostly .c, .h
  - `mobile/localization/` - mostly .json
- `native/` - mostly .cpp, .h
  - `native/vision-runtime/` - This is the only native code loaded by `dots.vision-fallback`. It links - open: README.md, CMakeLists.txt
- `output/` - mostly .png, .aiff
  - `output/herness-promo-2026-10-14/` - Three Turkish, vertical 9:16 promotional-video variations for HerNess. - open: README.md, requirements.txt
  - `output/brand-validation/` - mostly .log, .car
  - `output/herness-reel-2026-10-14-social/` - mostly .html, .md - open: index.html
  - `output/imagegen/` - mostly .md5, .png
  - `output/herness-reel-2026-10-14/` - mostly .html, .mjs - open: index.html
- `shared/` - mostly .cs, .png
  - `shared/provider-marks/` - mostly .png, .md
  - `shared/branding/` - the built-in Imagegen tool and stored losslessly at 1254 × 1254 with transparency. - open: README.md
  - `shared/prompts/` - mostly .txt, .jsonl
  - `shared/skills/` - mostly .md, .css
- `tools/` - mostly .py, .sh
- `windows/` - mostly .cs, .png
  - `windows/DotsHarness/` - The WPF shell uses the shared .NET 8 native provider core. It stores provider - open: README.md, DotsHarness.sln
  - `windows/scripts/` - mostly .cmd, .ps1

## Documents

Each with its headings. Read the one that covers the request before searching the code.
- `README.md` - dots-herness; Workspace scanning
- `browser-extension/README.md` - HerNess Chrome Extension backend
- `docs/cache-hit-audit-2026-09-30.md` - HerNess cache hit araştırması — 30 Eylül 2026; Ölçüm ve kapsam; Mevcut altyapının güçlü tarafları; Doğrulanan ölçüm sorunları; Cache sürekliliği hakkında eldeki
- `docs/cache-residual-diagnosis-2026-10-04.md` - Luna cache disinda kalan tokenlarin teshisi; Kanitlanan sonuc; Wire ve provider kaniti; Cache hit artirma deneyleri; Bulunan ve duzeltilen uygulama hatasi; Kaps
- `docs/cache-reuse-implementation-2026-10-04.md` - Cache tekrar kullanımı: uygulama ve kabul durumu; Uygulanan davranış; Yerel doğrulama; Canlı kabul deneyi
- `docs/cache-reuse-live-acceptance-2026-10-04-rerun.md` - Cache tekrar kullanımı canlı kabul yeniden denemesi; Sürüm ve kapsam; Canlı sonuç özeti; ChatGPT; Claude; Kayıp ve kabul kararı; Sonraki işlem
- `docs/cache-reuse-live-light-models-2026-10-04.md` - Dusuk modellerle canli cache kontrolu; Kapsam ve model secimi; Sonuclar; Keychain engeli; Butce ve loglar; Dokuman kontrolu
- `docs/computer-use.md` - Desktop application inspection and control; Enable; Tool sequence; Validation
- `docs/native-marketplace.md` - Native Plugin Marketplace; Beceriler ve proje altyapıları; Yayın akışı; Moderasyon durumları; Üretim kurulumu; Güven modeli
- `docs/platform-parity.md` - Platform Parity — Bilinen Farklar; Kapatılan macOS boşlukları (Windows/Linux); Desktop shell (macOS referansıyla ilerletildi); Tray / menü çubuğu varlığı; Yanıt
- `docs/prompt-cache-history.md` - Provider-independent prompt history; Compaction (macOS); Reuse measurement (all platforms); Cache key scope
- `docs/security-audit-2026-10-20.md` - Güvenlik Denetimi — 2026-10-20; Özet tablo; KRİTİK; YÜKSEK; ORTA (seçilmiş); DÜŞÜK (seçilmiş); DOĞRULANMASI GEREKEN NOKTALAR; DOĞRU YAPILANLAR (dokunmayın)
- `docs/system-prompt.md` - HerNess Sistem Promptu — Mevcut Durum, Öneri, Güvenlik; 1. Önerilen çekirdek prompt (tek kanonik metin); 2. Modele ne gidiyor?; 3. Modelden ne geliyor?; 4. Güve
- `docs/token-economy.md` - Token ekonomisi ve araç keşfi; Sağlayıcıya giden araçlar; Plan ve effort; Çıktı ve geçmiş; Prompt ve doğrulama
- `docs/versioning-and-updates.md` - Sürüm Yönetimi ve Otomatik Güncelleme Mimarisi; 1. Sürüm Numaralandırma Standardı (SemVer); 2. Güncelleme Kontrol API'si (Cloudflare Worker); 3. İstemci Tarafı 
- `docs/workspace-scanning.md` - Workspace scan policy; Defaults; Project exclusions; Selectively include Git-ignored files; First prompt
- `mobile/README.md` - HerNess mobile; Onboarding; On-device runtime; Workspace and Git; Tasks, memory, MCP, and plugins; Media, bots, and Marketplace; Build and test
- `cloudflare/migrations/schema-reference.md` - D1 schema reference — dotsherness-db; Tables; Apply
- `docs/legal/README.md` - Yasal Metinler — DOTS Herness; Kaynak; Uygulamanın çektiği URL'ler; Uygulama içi davranış
- `linux/DotsHarness/CONTRACT.md` - Native provider contract
- `linux/DotsHarness/README.md` - Dots Harness for Linux; Runtime requirements
- `macos/DotsHarness/CONTRACT.md` - Native provider contract
- `macos/DotsHarness/README.md` - Dots Harness for macOS; Provider connections; Local models and sharing; Turkish speech runtime and signing
- `native/vision-runtime/README.md` - DOTS Vision native runtime

## Guidance

- Source files and task history are selected by the native host as needed.
- The private project context is not exposed through workspace file tools.

Back to [[index]]
