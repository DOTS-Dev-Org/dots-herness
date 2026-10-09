# HerNess cache hit araştırması — 30 Eylül 2026

Cache çalışıyor. Son kullanımda sayaç raporlayan ChatGPT istekleri yaklaşık %85–86 token hit oranına ulaşıyor. Bütün kullanımın kesin oranını söylemek mümkün değil: yerel kayıtlardaki 18 isteğin 7'sinde cache sayaçları yok. Ayrıca iki farklı toplam/UI hesabı aynı metrik için farklı paydalar kullanıyor.

İlk inceleme kaynak kodu, yerel kullanım kayıtları ve güncel resmi sağlayıcı belgelerini kapsıyordu. Aşağıdaki baseline o incelemeye aittir. Kullanıcının sonraki isteği üzerine uygulanan değişiklikler ve çalıştırılan testler sondaki **Uygulama ve doğrulama** bölümünde ayrı raporlanmıştır.

## Ölçüm ve kapsam

Kaynak: `/Users/alibirkanbayram/Library/Application Support/DotsHarness/context-usage.json`. Kayıt aralığı İstanbul saatiyle **19 Eylül 2026 23:48:29 – 29 Eylül 2026 23:40:13**. Dosyada 18 olay var; hepsi ana model isteği. Bunlar kullanıcı mesajı sayısı değildir: bir mesajın araç döngüsü birden fazla model isteği üretebilir. Örneklem küçük ve yalnızca bu Mac'in yerel kayıtlarını temsil ediyor.

Oran, istek yüzdelerinin ortalaması alınarak değil, **raporlanan cached token toplamı / aynı isteklerin toplam input token'ı** olarak hesaplandı. Cache alanları bulunmayan istekler ayrı tutuldu. Claude için toplam input, normal input + cache read + cache write token'larından oluşuyor.

| Kapsam | İstek | Cache sayacı olan | Sayaç olmayan | Raporlanan cached token | Ölçülen isteklerin toplam input'u | Token hit oranı |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Bütün yerel kayıtlar | 18 | 11 | 7 | 87.194 | 131.157 | %66,5 |
| ChatGPT, iki model birlikte | 14 | 7 | 7 | 79.360 | 93.428 | %84,9 |
| ChatGPT / gpt-6-luna, 25–26 Eylül | 7 | 3 | 4 | 36.352 | 43.607 | %83,4 |
| ChatGPT / gpt-5.6-luna, 29 Eylül | 7 | 4 | 3 | 43.008 | 49.821 | %86,3 |
| Claude / claude-sonnet-5, 19 Eylül | 4 | 4 | 0 | 7.834 | 37.729 | %20,8 |

Claude örnekleri eski ve yalnızca dört istekten oluşuyor; bugünkü Claude performansını temsil ettikleri söylenemez. Burada üç istek yalnızca cache yazımı raporluyor, bir istek okuma da raporluyor. Okuma yapan tek isteğin kendi oranı %91,0.

Son 29 Eylül isteğinde 14.726 input token'ın 11.776'sı cached: **%80,0**. Aynı gün ölçülebilen diğer istekler yaklaşık %91,6, %90,8 ve %85,1.

Bütün 18 isteğin toplam input'u 203.084. Bunun 87.194 token'ı kesin olarak cache okuması raporlamış: bütün kayıtlar için **en az %42,9 doğrulanmış cache payı**. Sayaç eksikliği yüzünden toplam oran kesin değil. %66,5 ve %86,3 yalnızca ölçülebilen alt kümelerin oranlarıdır; soğuk ilk istekler daha sık sayaç raporlamıyorsa bu alt kümeler genel oranı yukarı doğru yanlı gösterebilir. Eksik sayaçlı 7 isteğin tamamı ChatGPT rotasında.

## Mevcut altyapının güçlü tarafları

- `docs/prompt-cache-history.md` ve macOS request/history kodu, değişen host bağlamını yeni kullanıcı mesajında bir kez yakalıyor. Önceki mesajlar ve araç sonuçları korunuyor; sabit politika önde kalıyor.
- Araçlar sıralanıyor; macOS JSON gövdesi sıralı anahtarlarla yazılıyor. Plan modu araç tanımlarını silmek yerine araç çalıştırmayı sınırlandırıyor.
- Cache kimliği sohbet, proje, model, sağlayıcı/API, hesap, araç tanımları ve compaction segmentini kapsıyor. Kısa yanıt tercihi bu kimliğe eklenmiyor.
- Router anahtarı gerçekten hizmet veren hesaba göre kapsamlandırıyor. Hesap/model sürekliliği mevcut.
- Claude isteklerinde system, tools ve son message için cache breakpoint'leri var.
- iOS ve Android kaynaklarında aynı sohbet/hesap/model/araç/segment kimliği ve Claude breakpoint yaklaşımı mevcut. Bu karşılaştırma kaynak kodu seviyesinde yapıldı; mobil hit oranı ölçülmedi.

## Doğrulanan ölçüm sorunları

**1. Global toplam hesabı, sayaç eksik istekleri paydada tutuyor.**

`macos/DotsHarness/Sources/DotsHarnessCore/ContextTelemetry.swift` içindeki `AgentContextCacheSummary`, ölçülebilen istek sayısını ayrı hesaplıyor ama cached/uncached token toplamlarına bütün ana istekleri dahil ediyor. Cache alanı olmayan bir istek input'unun tamamı uncached sayılıyor. Bu veride global hesap %50,3 üretiyor; ölçülebilen isteklerin token oranı %66,5. Bunlar aynı kapsama ait iki geçerli oran değil.

**2. Cache write token'ları toplam oran paydasında eksik.**

Aynı global hesap ve `macos/DotsHarness/Sources/DotsHarnessUI/ConversationUsagePopover.swift` içindeki `cacheEligible`, paydada cached + uncached kullanıyor. Claude'un cache write token'ları ayrı gösteriliyor ama paydada bulunmuyor. Claude'un dört kaydına bu global formül uygulandığında %99,9 çıkıyor; read / total input hesabı %20,8. Tek hit kaydında UI formülü 7.834 / (7.834 + 2) = %99,97, doğru token oranı 7.834 / 8.605 = %91,04.

UI sayaç eksik istekleri zaten filtreliyor; global summary ile aynı davranışı paylaşmıyor. UI cache bölümünde ana istek ve compaction summary ayrımı da bulunmuyor. Bu 18 kayıtta summary isteği yok, dolayısıyla mevcut örnekte bu ayrım sonuç değiştirmiyor.

**3. Alt seviye breakdown, açık sıfır ile eksik sayacı ayıramıyor.**

`AgentUsageBreakdown.cacheAccountingAvailable`, pozitif read/write veya mevcut miss alanı arıyor. Sağlayıcının açıkça `cached_tokens: 0` döndürdüğü bir OpenAI isteği bu helper'da bilinmiyor gibi görünebilir. Event seviyesindeki `measuredCacheHitRate` alan mevcudiyetini koruyor. Tek bir ortak muhasebe modeli kullanılmalı.

Mevcut parser sayısal sıfırı atmaz: `JSONValue.int` sıfır için de `Int` döndürüyor. Kayıtlardaki eksikliğin sağlayıcıdan mı, eski sürümden mi, farklı şemadan mı geldiğini ham usage verisi olmadan kesinleştirmek mümkün değil. Eksik alan otomatik olarak sıfıra çevrilmemeli.

Mevcut `ContextTelemetryTests.swift`, sağlayıcı input ayrımını ve maliyet hesabını test ediyor; global summary'nin unknown/write/sıfır ayrımlarını kapsayan test bulunmuyor.

## Cache sürekliliği hakkında eldeki kanıt

29 Eylül'de bir sohbetin cache anahtarı iki kullanıcı turu arasında değişiyor. Aynı geçişte native araç tanımları tahmini 5.159 token'dan 5.226 token'a çıkıyor; araç sayısı 35 kalıyor. Araç içeriği/fingerprint değişimi anahtar değişiminin olası nedenlerinden biri. Kaydedilmiş ayrı fingerprint bileşenleri olmadığı için tam neden kanıtlanamıyor. Anahtar değişimindeki isteğin cache sayacı da yok; bu isteğin kesin miss olduğu söylenemez.

18 isteğin tamamında compaction strategy `none`. Bu örneklemde düşüşleri sık compaction'a bağlayan kanıt yok. Varsayılan compaction eşiğini sırf hit oranı için artırmak ilk adım olmamalı.

Son kayıtlarda native araç tanımları yaklaşık 5,2 bin, system prompt tahmini 2,3 bin token. Bunlar yerel tahminlerdir; provider tokenizer ölçümü değildir. Kararlı hale getirilen bu ortak içerik önemli bir yeniden kullanım alanı oluşturuyor.

## Önerilen sıra

| Öncelik | Değişiklik | Kazanç ve doğrulama |
| --- | --- | --- |
| 1 | Tek cache muhasebe modeli: bilinen isteklerin `sum(read) / sum(totalInput)` hesabı; write token'larını paydaya dahil et; unknown istek/input payını göster | Önce doğru baseline. Claude %99,9 yanılsamasını ve unknown kaynaklı global düşüşü giderir. Açık sıfır, eksik alan, cache write ve farklı provider testleri gerekir. |
| 2 | Yerel tanılama: sağlayıcı usage alanlarının mevcudiyeti, ayrı policy/tool/segment hash'leri, gerçekleşen route, önceki isteğe süre, cache anahtarı değişim nedeni | Soğuk başlangıç, süre dolması, araç değişimi, model/hesap geçişi ve compaction ayrılır. Prompt veya araç argümanlarını kaydetmek gerekmez. |
| 3 | Araç tanımlarını sohbet boyunca sabitle; MCP keşif/yenileme ve plugin değişimlerini kontrollü uygula | Önde bulunan 5,2 bin token'lık araç alanının yeniden kullanımı korunur. Mevcut sıralama yaklaşımı korunmalı. |
| 4 | Doğrudan OpenAI Responses rotalarında, desteklenen modeller için sabit politika breakpoint'i ve cache diagnostics deneyi | Yeni sohbetlerde ortak prefix'in yeniden kullanımı ve gerçek miss nedeni ölçülür. GPT-5.6+ için key esas olarak muhasebe gruplamasıdır; yalnızca key eklemek optimizasyon sayılmaz. |
| 5 | Claude için kullanım aralığına göre 5 dakika / 1 saat TTL seçimi; gerektiğinde önceki breakpoint'i de koruma | 5 dakikadan uzun aralar ve çok sayıda yeni content block sonucu cache kaybı azalabilir. 1 saat yazımı daha pahalı olduğundan maliyetle birlikte karşılaştırılmalı. |
| 6 | Büyük ve nadiren kullanılan araçlara, desteklenen rotalarda ertelenmiş yükleme | Soğuk input yükü azaltılabilir. Her turda tools listesini kesip yeniden yapmak yerine yeni tanımları sona ekleyen model kullanılmalı. |

Cache anahtarının sohbet kimliğini içerdiği için aynı hesap/projedeki yeni sohbetler farklı muhasebe alanlarına ayrılıyor. Ortak policy/tools prefix'ini yeni sohbetler arasında paylaşmak ayrıca değerlendirilebilir; hesap, kullanıcı ve proje sınırları korunmalı. Claude JSON cache key'ini kullanmaz; bu öneri her sağlayıcıda aynı şekilde uygulanamaz.

Resmi OpenAI belgeleri GPT-5.6+ için explicit breakpoint'leri, `prompt_cache_options.ttl: "30m"` ve cache diagnostics karşılaştırmasını açıklıyor. HerNess'in mevcut request kodu bu tanılama/breakpoint seçeneklerini göndermiyor. Bunlar **doğrudan OpenAI API sözleşmesidir**; ChatGPT aboneliğinin Codex gateway rotasında veya başka OpenAI uyumlu sağlayıcılarda kabul edildiği doğrulanmadı. Endpoint/model desteği doğrulanarak, desteklemeyen rotalara alan gönderilmeden uygulanmalı. [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching), [cache diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).

Claude için mevcut kod `{"type":"ephemeral"}` gönderiyor; varsayılan süre 5 dakika. Resmi belgeler 1 saatlik TTL seçeneğini, daha yüksek write ücretini ve breakpoint başına 20 content block geriye bakma sınırını açıklıyor. Son mesajdaki breakpoint'e ek olarak uygun önceki sınırı korumak, büyük araç döngülerinde faydalı olabilir. Bu örnekte Claude miss'lerinin nedeninin bu sınır olduğu kanıtlanmadı. [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

Gemini'nin mevcut native rotası Cloud Code Assist zarfını kullanıyor ve explicit CachedContent kaynağı oluşturmuyor. Public Gemini API cache özellikleri bu rotaya doğrudan uygulanamaz; bu Mac'te Gemini kullanım örneği bulunmuyor. DeepSeek caching otomatik; mevcut parser hit/miss alanlarını destekliyor fakat yerel örnek yok. [Gemini Generate Content caching](https://ai.google.dev/gemini-api/docs/generate-content/caching), [DeepSeek caching](https://api-docs.deepseek.com/guides/kv_cache/).

## Uygulama sonrası ölçüm planı

Her rota/model için en az 100–200 isteklik ayrı örneklemle ilk istek ve devam isteklerini ayır. Aynı hesap/model/policy/tools ile kısa aralı devam, 5–60 dakika bekleme, yeni sohbet, plan modu geçişi, araç yenileme ve compaction senaryolarını karşılaştır. Bu sayı bir istatistiksel güven garantisi değildir; mevcut 18 isteklik örneklemden daha sağlam bir başlangıçtır.

Birlikte izlenecek sonuçlar: token hit oranı, unknown alan kapsamı, cache write token'ları, input/output maliyeti, ilk token gecikmesi ve toplam cevap gecikmesi. Mevcut telemetry toplam gecikmeyi saklıyor; ilk token süresi ayrıca eklenmeli. Retry ve compaction maliyetlerini toplam maliyete dahil et, ana sohbet oranını ayrı göster.

Sürekli devam eden sohbetlerde %90 civarı oran denenecek bir hedef olabilir; yeni içerik, ilk istek, bekleme ve araç çıktıları nedeniyle bütün kullanım için %99 garantisi verilemez. %86 hit, %86 toplam fatura tasarrufu anlamına da gelmez: output/reasoning, cache write ücretleri ve abonelik rotası muhasebesi ayrıdır.

Context7 bu oturumda erişilebilir değildi; sürüme duyarlı sağlayıcı davranışları resmi belgelerle kontrol edildi. Baseline macOS sonuçları gerçek yerel kullanım kayıtlarından hesaplandı. Hiçbir platform için yeni bir canlı cache hit iyileşmesi ölçüldüğü iddia edilmemektedir.

## Uygulama ve doğrulama — 30 Eylül 2026

### Uygulanan değişiklikler

- macOS global toplamı ve sohbet kullanım görünümü aynı `AgentContextCacheSummary` hesabını kullanıyor. Payda ölçülen ana isteklerin bütün input'u; Claude cache write dahil. Sayaçsız istek/input ayrı; açık sıfır gerçek ölçüm. Compaction summary ana sohbet oranından ayrı.
- Yerel usage olaylarında araç/policy/hesap/endpoint fingerprint'leri, segment, effort, hız, istek başlangıcı ve istenen Claude TTL tutuluyor. Başlangıç ve sonraki istekler arasındaki farklar etiketleniyor. `idle_beyond_requested_ttl` bir şüphe: kesin sağlayıcı miss nedeni gibi sunulmuyor. Prompt, araç argümanı veya kimlik bilgisi eklenmedi.
- Responses araç adları sıralı `tool_0`, `tool_1` yerine canonical ada bağlı SHA-256 adları kullanıyor. Yeni bir araç eklemek mevcut araçların adlarını değiştirmiyor. Eski function-call geçmişi canonical tool-call kaydıyla güncel wire adına çevriliyor; opaque reasoning ve diğer provider item'ları korunuyor. Sürüm geçişi wire prefix'ini bir kez değiştirir; bundan sonraki gereksiz ad kaymaları önlenir. Araç tanımlarındaki gerçek değişiklikler hâlâ cache'i etkileyebilir.
- iOS'ta JSON anahtarları sıralanıyor; Android'te bütün provider request JSON'u recursive canonical serializer ile gönderiliyor. İç içe schema anahtarlarının keşif sırası wire içeriğini değiştirmiyor.
- macOS ve ortak C# Responses rotaları desteklenen GPT-5.6+ ailelerinde, bir önceki başarılı normal response ID'sini normal devam isteğinin `prompt_cache_options.comparison_response_id` alanına ekliyor. Karşılaştırma scope'u sohbet/hesap/endpoint üzerinden sabit; araç, cache anahtarı veya model değiştiğinde önceki karşılaştırma kaydı kaybolmuyor. Farklı hesap veya endpoint kayıtları karşılaştırılmıyor. SSE ve JSON sonuçlarındaki güvenli tanılama alanları okunuyor. Model çağrısı ayrı değil. Açık 400/422 alan reddi halinde alan çıkarılarak bir kez tekrar deneniyor ve o rota/model için desteklenmediği hatırlanıyor. Böyle bir fallback model çağrısı ve varsa normal retry maliyeti, tanılama özelliğinin ücretsiz olmasından ayrı tutulmalıdır.
- Claude breakpoint'leri macOS, ortak Windows/Linux C#, iOS ve Android'te `ttl: "1h"` istiyor. macOS `AgentConfiguration.anthropicCacheTTL`, C# `NativeProviderRouter.AnthropicCacheTTL` ile 5 dakika override edilebilir; mobilde varsayılan 1 saat ve açık TTL reddinde 5 dakikaya fallback var. Yeni bir TTL ayar ekranı eklenmedi. Desteklemeyen endpoint'lerde normal isteğin devam etmesi için tek fallback bulunuyor. Fallback sonucunda efektif TTL macOS telemetry'ye yazılıyor.
- Background timer, keepalive veya düşük effort ile cache ısıtma çağrısı eklenmedi. Doğrudan OpenAI sabit prefix breakpoint'i ve tool-addition/deferred-tools gibi ayrı protokol değişiklikleri bu uygulamanın kapsamına alınmadı.

### 5 dakika / 1 saat maliyet kararı

Claude varsayılan 5 dakikalık cache, tekrar kullanıldığında kendi TTL'si kadar yenilenir. Kullanıcı bu süreyi aşarsa konuşma kaybolmaz; ilgili prefix'in yeniden işlenmesi/yazılması gerekebilir. 1 saat TTL bunun doğal çözümüdür ve süresi dolmadan ayrıca istek gerektirmez. 1 saat geçmesi veya prefix/model/araç değişimi yine yeniden yazım doğurabilir. [Claude cache süreleri ve fiyatları](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

Maliyet testinde normal input birim fiyatı 1'e normalize edildi; cache write 5 dakika için 1,25, 1 saat için 2, read için 0,1. Output, yeni input ve abonelik kotası bu örneğin dışındadır:

| Aynı prefix'in iki kullanımı | 5 dakika TTL | 1 saat TTL | Sonuç |
| --- | ---: | ---: | --- |
| 5–60 dakika ara; 5 dakikalık cache dolmuş | 1,25 + 1,25 = 2,50 | 2 + 0,1 = 2,10 | Uzun TTL bu prefix için %16 daha ucuz |
| 5 dakika içinde devam | 1,25 + 0,1 = 1,35 | 2 + 0,1 = 2,10 | Kısa TTL daha ucuz |
| 1 saatten fazla ara; yeniden kullanım yok | 1,25 yazım | 2 yazım | Uzun TTL yazım primi geri kazanılmaz |

Bu, tüm faturanın %16 azalacağı veya 1 saatin her kullanıcı için daha ucuz olacağı anlamına gelmez. Varsayılan 1 saat, kullanıcının uzun aralı sohbet ihtiyacına göre seçildi; sık araç döngülerinin toplam cache write maliyeti gerçek kullanımda ayrıca izlenmelidir. Ek düşük effort çağrısı aynı modeli seçse bile effort/cache-sensitive ayarlar değişirse yeniden kullanımı bozabilir. Normal isteğe eklenen OpenAI tanılaması ek maliyet ve ayrı rate-limit tüketimi yaratmaz; yeni baseline/tekrar model istekleri normal şekilde sayılır. [OpenAI tanılama sözleşmesi](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).

### Test sonuçları ve sınırlar

| Doğrulama | Sonuç |
| --- | --- |
| macOS cache muhasebesi, ağırlıklı oran, açık sıfır/unknown, araç adı ve eski history, JSON/SSE diagnostics, optional alan reddi/TTL fallback, hesap izolasyonu/model ve key değişimi, prefix history ve mevcut API kontrolleri | 29 yerel test geçti |
| iOS / yalnız çalışan iPhone 17 Pro simülatörü | `MobilePromptHistoryTests`: 4 test geçti; Xcode test derlemesi başarılı |
| Android | `MobilePromptHistoryTest`: 4 JVM testi geçti; Android debug Kotlin derlemesi başarılı. Cihaz/emülatörde canlı cache ölçülmedi |
| Ortak C# router, aynı production dosyası üzerinden izole .NET test projesi | Cache ve prompt snapshot kapsamındaki 11 test geçti |
| Tam Windows test projesi | Mevcut AgentBridge/RouterController derleme hataları nedeniyle çalışamadı. İzole projede yalnız EconomyPolicy bağımlılığının mevcut nullable local compile hatası geçici kopyada tip belirtilerek aşılmıştır; production router kaynak dosyası doğrudan derlenmiştir |
| İzole C# ilk bütün RouterApiTests çalıştırması | O sıradaki 21 testin 20'si geçti; cache dışı mevcut provider label testi `GPT` / `ChatGPT` farkıyla başarısız. Sonradan eklenen scope testini de içeren cache kapsamındaki filtre ayrıca başarılı |
| Canlı ChatGPT abonelik gateway tanılama ve Claude 5m/1h kontrolü | Tamamlanmadı: test çalıştırıcısı macOS Anahtarlık erişim izninde bekledi; süreç durduruldu. Son yerel çalıştırmada iki canlı test bilinçli olarak skip edildi. Başarılı API isteği veya 6 dakika sonrası hit kanıtı yok |

Canlı deney `PromptCacheLiveTests.swift` içinde hazır: iki ayrı, benzersiz başlangıç prefix'iyle 5m kontrol ve 1h deneyi başlatılır; **360 saniye hiçbir keepalive göndermeden** beklenir; kontrolün yeniden write, deneyin read raporlaması beklenir. ChatGPT deneyi aynı model/effort ile normal devam isteğine comparison ID ekler. Bu küçük deney bir uzun dönem hit oranı ölçümü değildir.

Tekrar çalıştırırken test çalıştırıcısı için macOS Anahtarlık izni gerekir; kimlik bilgileri terminale, rapora veya kaynak dosyasına yazılmaz:

```sh
# macos/DotsHarness içinden; Anahtarlık erişimi kullanıcı tarafından verilerek:
DOTS_CACHE_LIVE=1 DOTS_CACHE_KEYCHAIN_INTERACTIVE=1 swift test --disable-sandbox --filter PromptCacheLiveTests
```

Yerel başarılı kontroller: `swift test --disable-sandbox --filter 'PromptCacheImprovementTests|ContextTelemetryTests|PromptHistoryTests'`; Android `gradle :app:testDebugUnitTest --tests com.dots.herness.mobile.MobilePromptHistoryTest`; iOS `xcodebuild` ile `HerNessMobileTests/MobilePromptHistoryTests` ve iPhone 17 Pro destination. Bunlar protocol/cache muhasebesi testleridir; gerçek sağlayıcının yeni hit oranının yerine geçmez.
