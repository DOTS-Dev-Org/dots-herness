# Cache tekrar kullanımı: uygulama ve kabul durumu

4 Ekim 2026. Bu rapor önceki [baseline araştırmasından](cache-hit-audit-2026-09-30.md) ayrıdır; eski yüzdeler yeni sürümün sonucu değildir.

**Cache okuması canlı olarak çalışıyor. %99,9 tekrar kullanım ve %95 ölçüm kapsamı kabulü henüz doğrulanamadı.** ChatGPT devam isteği 14.080 cached token raporladı. Önceki isteğin cache'e yazılan kesin token sınırı raporlanmadığı için bu sonuçtan uygun geçmişin tekrar kullanım yüzdesi çıkarılmadı. Claude deneyleri, iptal edilmiş OAuth access token nedeniyle 401 ile durdu.

## Uygulanan davranış

- macOS, ortak C# Windows/Linux, iOS ve Android geçmişi ek dosya bildirimleri için yeniden yazmaz. Değişiklik ve geri gelme bildirimleri, tamamlanmış araç gruplarından sonra bir kez eklenir. Mobilde eski ek dosya blokları kendi snapshot'larındaki baytları kullanır.
- macOS plugin/MCP tanımları son başarılı katalogdan korunur. Disconnect, ağ kapatma ve devre dışı bırakma yürütmeyi durdurur; tanım snapshot'ını silmez. Başarısız kısmi plugin yüklemesi eski katalog üzerinde commit yapmaz ve bıraktığı çalıştırılabilir closure'lar temizlenir. Çağrı ve paralel ön çalıştırma öncesinde; onay bekleyen plugin/MCP/Computer Use çağrılarında ayrıca onay sonrasında güncel bağ ve erişim kontrol edilir.
- Gerçek şema, çalışma sözleşmesi, politika ve compaction değişiklikleri cache dönemini değiştirir. Plan modu araç kataloğunu veya cache anahtarını daraltmaz; yeni context olayı ve mevcut yürütme kısıtları kullanılır. İç içe uygulama JSON'u deterministiktir; opaque sağlayıcı içerikleri korunur.
- Claude'da son araç, sabit sistem, önceki kabul edilmiş sınır ve güncel son sınır olmak üzere en fazla dört farklı marker vardır. Çakışmalar birleşir. Hepsi `1h` kullanır; açık TTL reddinde tek `5m` fallback kalır. Doğrulanmış sınır yalnız başarılı yanıt sonrasında ilerler; küçülen veya eksik terminal sayaç önceki sınırı yenilemez.
- Desteklenen doğrudan OpenAI Responses rotalarında sabit developer `input_text` için explicit breakpoint, güncel son uygun blok için implicit caching ve normal istekte diagnostics birleştirilir. Açık alan reddi ilgili özelliği kaldırır. ChatGPT Codex gateway sabit instructions sözleşmesini korur ve yeni explicit breakpoint almaz.
- Sohbet cache metadata'sı ve usage tekrar kullanım kanıtları geriye uyumlu optional alanlardır. Geçmiş metadata için dönüşüm sürümü/proof sürümü kullanılır; doğrulanmamış eski token paydası yeni kabul hesabına taşınmaz.
- Parmak izleri gerçek gönderilen istekten alınır. Şemalardaki kullanıcıya ait `cache_control` adlı özellikler fingerprint hesabından yanlışlıkla silinmez. Diagnostics tahminleri kesin token veya fatura sayacına dönüştürülmez.
- Toplam cached/input, uygun geçmişin token ağırlıklı tekrar kullanımı, ölçüm kapsamı, soğuk/expired/değişmiş istekler, kayıplar ve gecikme ayrı gösterilir. Normal kullanım pencereleri sohbet/hesap/endpoint/model rotasına göre ayrılır. Kesin sayaçlarla doğrulanmış miss ve eviction kayıpları paydada kalır; sayaçsız devamlar kapsamı düşürür. Model/politika/katalog değişikliği, ilk yazım ve TTL aşımı ayrı raporlanır.
- Gateway için public OpenAI TTL'si veya varsayımsal 300 saniye kullanılmaz. Read-only usage'dan bütün input'un cache'e yazıldığı sonucuna varılmaz. Kesin önceki yazım sınırı veya efektif TTL eksikse hedef sonucu ölçülemedi kalır. Gerçek raporlanmayan maliyet `—` olarak gösterilir; token ölçümleri fatura iddiasına çevrilmez.
- Prewarm, keepalive, ek düşük effort çağrısı eklenmedi. Model kalitesi, araç yeteneği ve gerekli compaction sınırlandırılmadı.

## Yerel doğrulama

| Kapsam | Sonuç ve sınır |
| --- | --- |
| macOS | 69 ilgili test geçti. Cache epoch/persistence, eski kayıt, katalog sırası ve şema değişimi, başarısız plugin yüklemesi, izin/disconnect, geçmiş, dört marker, 20'den fazla blok, JSON/SSE, optional alan reddi, TTL fallback, exact/unknown hesap ve gerçek miss kapsamı. |
| Ortak C# router/contracts | Production kaynak dosyalarını doğrudan linkleyen izole projede 33 ilgili test geçti. Scratch projede yalnız mevcut EconomyPolicy nullable local derleme hatasının geçici kopyası düzeltilir. Tam platform kanıtı değildir. |
| iOS | Çalışan iPhone 17 Pro simülatörü yeniden kullanıldı; 20 cache/history + 2 attachment testi, toplam 22 test geçti. Canlı mobil sağlayıcı ölçümü yapılmadı. |
| Android | 20 cache/history JVM testi geçti; debug Kotlin derlemesi başarılı. Android cihaz/emülatör üzerinde canlı ölçüm yapılmadı. |
| Windows/Linux tam derleme | Mevcut AgentBridge, RouterController, BrowserSessionManager, RemoteControl ve EconomyPolicy hatalarıyla engellendi. Ortak test sonucu Windows/Linux tam doğrulaması olarak sunulmaz; yeni kullanım popup'ları runtime doğrulanmadı. |

Tekrar çalıştırılan kontroller:

```sh
# macos/DotsHarness
swift test --filter 'CacheEpochAndReuseTests|PromptCacheProviderEvidenceTests|PromptCacheImprovementTests|ContextTelemetryTests|MCPAndToolBridgeTests|PromptHistoryTests|CompositionLoaderTests|SandboxPluginAndMCPEscapeTests|ConversationStoreIncrementalTests'

# repository root; halihazırda çalışan iPhone 17 Pro
xcodebuild -project mobile/ios/HerNessMobile.xcodeproj -scheme HerNessMobile \
  -destination 'platform=iOS Simulator,id=F8D41B89-BD78-41BD-BCA0-BB15523F5484' \
  -only-testing:HerNessMobileTests/MobilePromptHistoryTests \
  -only-testing:HerNessMobileTests/MobileAttachmentTests \
  -derivedDataPath /tmp/herness-mobile-cache-tests test

# mobile/android
ANDROID_HOME=/Users/alibirkanbayram/Library/Android/sdk \
ANDROID_SDK_ROOT=/Users/alibirkanbayram/Library/Android/sdk \
gradle :app:testDebugUnitTest --tests com.dots.herness.mobile.MobilePromptHistoryTest
```

Yerel test logları: `/private/tmp/herness-cache-implementation-swift-final.log`, `/private/tmp/cache-prefix-csharp-tests-final.log`, `/private/tmp/herness-mobile-cache-tests-final.log`, `/private/tmp/herness-cache-android-tests-final.log`. Android raporu: `mobile/android/app/build/test-results/testDebugUnitTest/TEST-com.dots.herness.mobile.MobilePromptHistoryTest.xml`.

## Canlı kabul deneyi

`PromptCacheLiveTests` her öncelikli rota için ilk istek + 20 devam isteği ve Claude için keepalive olmadan 360 saniye 5m/1h karşılaştırması içerir. **Transport seviyesindeki 50 istek sınırı fallback/retry girişimlerini de kapsar.** İlk devamda protokol kanıtı yoksa gereksiz ücretli çağrılar sürdürülmez. Keychain erişimi etkileşim beklemeden kontrol edilir; kimlik bilgileri loglanmaz.

4 Ekim çalıştırması:

- ChatGPT: başlangıç ve devam yanıtı alındı; devamda `cached_tokens=14080`. `previous_boundary_unverified` nedeniyle 20 uygun istek kabul testi skip edildi. Sonuç **doğrulanamadı**; yüksek raw hit ile %99,9 hedefi eşitlenmedi.
- Claude 5m/1h: ilk API çağrısı `401 OAuth access token has been revoked` döndürdü. 360 saniye karşılaştırması başlamadı. Sonuç **doğrulanamadı**.
- Claude 20 devam: aynı 401 ile durdu. Sonuç **doğrulanamadı**.

Canlı log: `/private/tmp/herness-cache-live-final.log`. Claude için yeniden oturum açıldıktan sonra normal rota üzerinden tekrar denenmesi gerekir. ChatGPT için önceki cache yazım sınırı ve retention kanıtı sağlanmadan hedef kabulü yapılamaz. Tam Windows/Linux derleme engelleri ve canlı mobil doğrulama da açık kalır.

Kaynaklar: [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [Claude diagnostics](https://platform.claude.com/docs/en/build-with-claude/cache-diagnostics), [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching), [OpenAI diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics). Context7 bu oturumda mevcut değildi; resmi belgeler kullanıldı.
