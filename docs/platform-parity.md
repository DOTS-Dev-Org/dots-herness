# Platform Parity — Bilinen Farklar

## SandboxWorkspace
- `macos/DotsHarness/Sources/DotsHarnessCore/SandboxWorkspace.swift:11` + `AppModel.swift:75` `activeSandbox` sadece macOS.
- Linux/Windows `AppModel.cs` sandbox yok — `git worktree` tabanlı izolasyon macOS-only.
- Ekle: Linux `git worktree` portu istenirse `SandboxWorkspace.swift:31` mantığı port edilecek; şimdilik bilinçli fark.

## Provider Secrets
- macOS: Keychain (`Security` framework, `MCPClient.swift:224`).
- Linux `PlatformProviderSecrets.cs:15` `secret-tool` varsa Secret Service, yoksa `~/.local/share/DotsHarness/provider-secrets/` 700/600 fallback (SHA256 id → hex). `TrySetMode:66` best-effort, race ~ms ama chmod verify ediliyor.
- Windows `PlatformProviderSecrets.cs:10` DPAPI `CryptProtectData` ile `provider-secrets/` dosyası şifreli.
- Voice API key (`voice.api.key`) her platformda `settings.json` içinde plaintext — `AppModel.cs:PersistSettings` 600 ile yazılıyor (Unix). Home 755 ise fallback dir 700 korur ama `settings.json` 600 şart.

## Localization
- `shared/Localization.resx:7` 267 key, `macos/.../en.lproj/Localizable.strings` 868 key → farklı key setleri, kasıtlı. `shared` sadece Windows/Linux `L()` (148 key) kullanır, `macos` sadece `AppCopy.text()`. Cross-check: `shared` makos anahtarlarını içermez, tersi de öyle — bug değil.
- Gerçek bug: `shared/Localization.*.resx` HEAD 200 key iken `L()` 148'in 39'u eksikti (örn `ask.*`, `voice.*`, `vision.*`). Diğer diller 221 key ile 25 `L()` eksikti → ilgili dilde English fallback. Fix: tüm `shared/Localization*.resx` 267'ye eşitlendi (46 eksik eklendi, English fallback). `LocalizationTests:4` artık geçiyor.

## Resource Skills
- `Package.swift:47` `.copy("Resources/skills")` → `macos/.../Resources/skills/ui-design/` commitli olmalı, yoksa runtime 0 skill.
