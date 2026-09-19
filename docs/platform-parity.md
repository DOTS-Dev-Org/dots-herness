# Platform Parity — Bilinen Farklar

## SandboxWorkspace
- `macos/DotsHarness/Sources/DotsHarnessCore/SandboxWorkspace.swift:11` + `AppModel.swift:75` `activeSandbox` macOS `git worktree`.
- iOS `mobile/ios/Sources/SandboxWorkspace.swift:11` + `LocalWorkspaceStore.swift:10` `activeSandbox` file-copy tabanlı soft sandbox — `HerNess/sandboxes/<hash>/<name>` izole kopya, `exit(merge:)` dosyaları geri kopyalar, `discard` siler. Branch `herness/sandbox-<name>` metadata. `ReadLedger` ve `agentFiles` sandbox root üzerinden çalışır, `HerNessMobileApp.swift:64` git client sandbox değişiminde yenilenir.
- Linux/Windows `AppModel.cs` sandbox yok — `git worktree` tabanlı izolasyon macOS-only.
- Ekle: Linux `git worktree` portu istenirse `SandboxWorkspace.swift:31` mantığı port edilecek; şimdilik bilinçli fark.

## Remote Work Location (SSH)
- macOS `ChatComposer.swift` "Şurada çalış" seçicisi `~/.ssh/config` host'larını listeler; seçilen host'ta `WorkspaceTools.executeRemote` + `TerminalSession(remoteTarget:)` sistem `/usr/bin/ssh` ile çalışır (`SSHRunner.swift`, `SSHConfigStore.swift`, `SSHEnrollment.swift`, `SSHHostStore.swift`).
- Faz 1 kapsamı: `run_command` ve interaktif terminal uzakta. `list_files/read_file/write_file/remove_file/grep_files` uzak modda reddedilir — sessizce yerel diske yazmamak için bilinçli. MCP stdio sunucuları ve plugin `shell` aksiyonları yerelde kalır.
- Linux/Windows'ta bu seçici yok; `shared/Localization*.resx` içinde `workLocation.*`/`ssh.*` anahtarı yok. Port istenirse `SSHRunner`/`SSHConfigStore` mantığı C#'a taşınacak; şimdilik bilinçli fark.

## Multi-Account Provider Priority & Conversation Affinity
- macOS-only: kullanım-farkında hesap seçimi + sohbet–hesap affinity + sağlayıcı sıralama UI.
  - `RouterController.orderedRoutes` (`RouterController.swift`) aktif hesapları cooldown → kalan kota (`accountUsage`) → `priority` sırasıyla dizer; `send`/`complete` yeni `preferredAccountID` parametresi ilk turda seçilen hesabı sonraki turlarda sabitler (prompt-cache).
  - Prompt-cache breakpoint'i fiilen konuyor (`NativeAgentClient`): Anthropic gövdesinde son `system` bloğu, son tool ve son mesaja `cache_control: {"type":"ephemeral"}`; OpenAI/Responses gövdesinde `prompt_cache_key` (`AgentBridge.cacheKey` = `herness:<projectID>:<model>:…`). Usage parse'ı Anthropic'te `cache_read_input_tokens`/`cache_creation_input_tokens`, OpenAI/Responses'ta `*_tokens_details` alanlarını `AgentUsage.cachedTokens`/`cacheWriteTokens`'a yazar. Gemini'de açık `cachedContent` yok — implicit caching + affinity pini yeterli (kod içi `ponytail:` notu).
  - `Conversation.stickyAccountID`/`stickyModelID` (`ConversationStore.swift`) + `StoredProviderAccount.cooldownUntil` (`ProviderStore.swift`) persist edilir; `AgentBridge` run başında `router.affinityAccountID` ile doğrular, başarılı turdan sonra yazar. Invalidation: model/sağlayıcı değişimi veya 429 cooldown.
  - Kullanım verisi yalnızca `claude` sağlayıcısı için canlı çekilir (`ClaudeUsageService` → `RouterController.refreshAccountUsage`); diğer abonelik sağlayıcıları `remainingFraction = nil` (bilinmeyen) kalır, `priority` sırası + cooldown korur. Yükseltme yolu: `NativeAgentClient` yanıtından `x-ratelimit-*` başlıklarını yakalamak.
  - Settings › Providers: sağlayıcı grubu başlıklarında sürükle-bırak + ↑/↓ butonları → `RouterController.reorderProviders` (`providerIndex*100 + hesapIndex` → `priority`). `RouterCatalog.groups(from:)` grupları `priority`'ye göre sıralar.
- Linux/Windows: `NativeProviderAccount.Priority` + `.OrderBy(a => a.Priority)` (`shared/NativeProviderRouter.cs`) zaten var; UI, usage ve affinity beklemede (bu makinede dotnet toolchain yok). Port istenirse aynı sıralama comparator'ı + `stickyAccountId` alanı C#'a taşınacak.

## Provider Secrets
- macOS: Keychain (`Security` framework, `ProviderStore.swift:148`).
- Linux `PlatformProviderSecrets.cs` `secret-tool` varsa Secret Service, yoksa `~/.local/share/DotsHarness/provider-secrets/` içinde create sırasında 0700 dizin ve 0600 dosya kullanır; mod doğrulanamazsa işlem fail-closed exception verir (SHA256 id → hex).
- Windows `PlatformProviderSecrets.cs` DPAPI (`CryptProtectData`) ile `provider-secrets/` dosyasını şifreler. Unix chmod uygulanmaz; erişim Windows kullanıcı profilinin ACL’lerine dayanır.
- Voice API key artık `voice.api.key` sabit credential id ile mevcut platform vault’una yazılır. Settings JSON yalnızca provider, endpoint ve model metadata tutar; eski plaintext key read-back doğrulamasından sonra taşınır.

## Localization
- `shared/Localization.resx` 267 key, macOS `en.lproj/Localizable.strings` 893 key tutar; iki platformun kullandığı yüzeyler farklı olduğu için setler kasıtlı olarak aynı değildir. `mcp.*` veya `remote.*` kaynak anahtarı yok; `voice.*` anahtarları vardır.
- Her platform ailesinde locale seti artık tamamdır: shared 29 locale dosyası ve macOS 30 locale dosyası kendi İngilizce kanonik setiyle eşleşir. `tools/check_localization.py --check` eksik/fazla anahtarları, eksik locale dosyalarını ve `{0}`/`%@` placeholder drift’ini CI’da durdurur.

## Resource Skills
- `Package.swift:47` `.copy("Resources/skills")` → `Resources/skills/` genel kaynak işleminden ayrı bundle edilir; `ui-design/SKILL.md` runtime’da okunabilir.

## Plugin composition & lifecycle
- Çekirdek: `CompositionLoader.loadHost` (`macos/.../DotsHarnessCore/AppModel.swift`, `linux/.../DotsHarnessCore/AppModel.cs`) artık katalogdaki her plugin'i (builtin + kurulu) id-sıralı olarak mount edilen `CompositionDocument`'a ekler. `host.patch.yml` yalnızca override katmanı (sıralama, `config` merge, explicit `disable/enable`). Eski davranış: sadece `dots.vision-fallback` özel-case'i mount oluyordu. Her iki platformda paritedir.
  - **`isolate:` şu an inert.** `PluginHost.mount`/`Mount` `isolate` anahtarını yalnızca `plane: session` dokümanında onurlandırıyor; bu yol her zaman `.host` düzlemli doküman kuruyor, dolayısıyla `host.patch.yml` içindeki `isolate` parse ediliyor ama etkisi yok. Gerçek session izolasyonu için konuşma başına ayrı `plane: session` `PluginHost` gerekir (opsiyonel yükseltme).
- `install_plugin` agent tool'u (`InstallPluginTool.swift`) ve üç platformdaki katalog yalnızca native manifest + derlenmiş library kabul eder; JavaScript ve manifest-only/declarative pluginler artık yüklenmez. Kullanıcı kaynakları Marketplace/CI dışından çalıştırılmadan önce untrusted tutulur.
- macOS Settings › Plugins/Marketplace — signed `.dotsplugin` indirir, hash + DOTS Ed25519 imzasını doğrular, native-code uyarısı sonrası trusted mount eder; HerNess OAuth/email oturumu ile plugin publish, immutable release geçmişi, build durumları, source preview ve soft-unpublish yönetilir. Yerel fork upstream'den ayrı kimlikle saklanır ve otomatik ezilmez.
- Windows WPF ve Linux Avalonia aynı public `https://dots.net.tr/harness/registry.json` sözleşmesini kullanır; platform/architecture artifact durumunu gösterir, imza/hash doğrulamasından sonra açık native-code onayıyla mount eder. Publisher yönetimi şu an macOS akışındadır; ortak Cloudflare API Windows/Linux istemcilerinin ileride aynı publish UI'ını kullanmasına hazırdır.
- Cloudflare Worker `/api/marketplace/*` + D1/R2 + GitHub Actions matrix build akışı global plugin ownership, immutable SemVer release, zorunlu lisans, public/private source, `pending/ready/failed` artifact durumu ve `unverified` başlangıç durumunu uygular. CI callback'i scoped GitHub OIDC token veya sınırlı CI secret ile korunur; imzalama private key build job'larına verilmez.
- `plugin.ir.json` ortak yüzeyi prompt, typed tools, events, settings ve desteklenen panel slotlarını taşır. Native generator üç platform için ortak contract scaffold üretir; arbitrary SwiftUI/WPF/Avalonia kodunu otomatik çevirmediği için platforma özel davranış publish öncesi kaynakta tamamlanmalıdır.
- `harness.host("<topic>")`: sandbox'lı plugin'in native app verisini **salt-okunur** aldığı köprü. `HostDataRegistry` (`HarnessPluginKit/HostData.{swift,cs}`) root realm'de `host.data` servisi; app `AppModel.registerHostDataTopics()` ile topic yayınlar (`app`, `workspace`, `model`). Yazma yolu yok. Her iki platformda paritedir.

## Skill Suggestion
- `shared/SkillSuggestionEngine.cs` + `shared/MemEventStore.cs` + `shared/SkillSuggestionMonitor.cs`: tekrar eden tool-call'ları (`.mem/events/*.json` `commandSummary`) ve tekrar eden kullanıcı prompt'larını (token-set Jaccard benzerliği) algılayıp bir `SkillSuggestion` önerir. Hiçbir zaman kendiliğinden `SKILL.md` yazmaz — `SkillCatalog.Create` yalnızca kullanıcının banner'daki "Create Skill" tıklamasından çağrılır, agent tool-call yolundan değil.
- `skill.suggest` agent tool'u (`SkillCatalog.cs` `SkillTools`, read-only): ajan sohbet sırasında fark ettiği bir kalıbı (arka plan tarayıcılarının yakalayamayacağı bir şey) kendisi önerebilir — sadece `SkillSuggestionMonitor.Pending`'i doldurur, dosya yazmaz; kart yine kullanıcı onayı bekler. Aynı ad+açıklama daha önce kabul/red edildiyse tekrar göstermez.
- Windows/Linux (C#): `AppModel` içine `SkillSuggestions` (`SkillSuggestionMonitor`) wire edildi, `Bridge.RunSummaryReceived` sonrası taranır; `AgentBridge` yapıcısına `SkillSuggestionMonitor` parametresi eklendi, `skill.suggest` çağrısını oraya yönlendirir. Hem Linux Avalonia hem Windows WPF `ConversationView`'da referans UI (composer üstü banner, "Create Skill"/"Not now") mevcut.
- macOS (Swift): `SkillCatalog.swift`, `MemEventStore.swift`, `SkillSuggestionEngine.swift`, `SkillSuggestionMonitor.swift` portlandı; `AgentBridge.swift`'e `skill.suggest` tool'u ve `AppModel.swift`'e wiring eklendi; SwiftUI banner `DotsHarnessUI/ChatComposer.swift`'te (diğer composer banner'larıyla aynı yerde, `voiceIntroBanner`'ın hemen yanında).

## Agent Runtime
- `macos/.../WorkspaceTools.swift:417` `Process /bin/zsh -lc` real shell, `MobileAgent.swift:122` önceden 100k context → 200k yükseltildi, `compactContextIfNeeded:747` 12 mesaj keep — desktop ile parity arttı ama desktop limitsiz değil gibi: iOS hala daha agresif keser.
- `mobile/ios/Sources/AgentTools.swift:121` `run_command` hybrid: virtual (`LocalShell.commands`) on-phone, heavy (`npm|swift|dotnet|cargo|pytest|gradle|xcodebuild|make|cmake`) paired desktop varsa `RemoteControlClient.swift:270` `command(kind:"run_command")` → `shared/RemoteControl.cs:812` `ExecuteSensitiveAsync` + artifact; yoksa local fallback `unsupported_on_mobile` değil.
- `mobile/ios/Sources/ReadLedger.swift:1` `WorkspaceTools.ReadLedger:505` port — `write_file` artık fresh/stale/unread guard.
- `mobile/ios/project.yml:10` `HERNESS_HAS_LIBGIT2=1` — header yoksa `MobileGitClient.c:16` stub `HERNESS_GIT_UNAVAILABLE`, XCFramework vendored olunca real libgit2.
