# Cache tekrar kullanımı canlı kabul yeniden denemesi

4 Ekim 2026, 02:18 Europe/Istanbul. Bu rapor `docs/cache-reuse-implementation-2026-10-04.md` sonrasında aynı checkout üzerinde yapılan yeni canlı denemeyi kaydeder. Önceki 14.080 cached token sonucu yalnız karşılaştırma bağlamı olarak kaldı; aşağıdaki sonuçlar bu turdaki logdan alınmıştır.

## Sürüm ve kapsam

- Çalışan HerNess macOS süreci PID `35400`, `/Volumes/HIKVISION/Projects/DOTS/DOTS Dev/dots_hernes/macos/DotsHarness/.build/arm64-apple-macosx/debug/DotsHarness.app/Contents/MacOS/DotsHarness` içinden çalışıyordu.
- `codesign --verify --deep --strict --verbose=2 macos/DotsHarness/.build/arm64-apple-macosx/debug/DotsHarness.app` başarılıydı; bundle valid on disk ve designated requirement sağlandı.
- Canlı ölçüm komutu: `DOTS_CACHE_LIVE=1 DOTS_CACHE_KEYCHAIN_INTERACTIVE=1 swift test --disable-sandbox --filter PromptCacheLiveTests`.
- Canlı log: `/private/tmp/herness-cache-live-2026-10-04-rerun.log`.
- Context7 bu oturumda çağrılabilir MCP aracı olarak mevcut değildi. Sürüm duyarlı sağlayıcı davranışları resmi OpenAI prompt caching diagnostics ve Anthropic prompt caching dokümanlarıyla kontrol edildi.

## Canlı sonuç özeti

| Rota | Gerçek model transport isteği | Raw hit | Exact eligible reuse | Ölçüm kapsamı | Sonuç |
| --- | ---: | ---: | ---: | ---: | --- |
| ChatGPT abonelik/Codex gateway | 2 | 14.080 cached token | Ölçülemedi | 0 / 20 continuation | Doğrulanamadı |
| Claude 5m/1h TTL karşılaştırması | 1 | 0 | Ölçülemedi | 0 / 2 after-idle ölçümü | Doğrulanamadı |
| Claude 20 continuation | 1 | 0 | Ölçülemedi | 0 / 20 continuation | Doğrulanamadı |

Toplam canlı model transport denemesi: 4. 50 istek sınırının altında kalındı. ChatGPT iki çağrıdan sonra durdu; Claude iki ayrı testte ilk çağrıda 401 aldı. Fallback veya retry model çağrısı gözlenmedi.

## ChatGPT

`testChatGPTTwentyWarmContinuations` ilk yazım ve ilk devam isteğini gönderdi. İlk devam sonucu:

- `raw cached=14080`
- `cacheReuseEvidence.reason=previous_boundary_unverified`
- test sonucu: skip, hedef doğrulanmadı

Bu, cache okuması olduğunu gösterir; fakat kabul hedefindeki payda olan efektif TTL içindeki uygun geçmişin önceki başarılı istekte cache'e yazıldığı/okunduğu sınır doğrulanmadığı için `14080 / eligible` hesabı yapılamadı. Bu nedenle:

- raw cached/input toplamı eksik input paydası nedeniyle kabul oranına çevrilmedi.
- exact reuse unknown kaldı.
- ölçüm kapsamı ilk devamda durduğu için 0 / 20 kabul edildi.
- en büyük kayıp nedeni kesin token kaybı değil, `previous_boundary_unverified` nedeniyle kapsam kaybıdır.

Tekrar işlenen içerik: sağlayıcı usage yalnız cached token sayısını verdiği için tekrar işlenen kesin token miktarı raporlanmadı. Yeni içerik, ilk yazım ve devam mesajı ayrı düşünülmelidir; read-only cached token sayısından bütün input'un cache'e yazıldığı sonucu çıkarılmadı.

## Claude

`testClaudeFiveMinuteControlAndOneHourCacheAfterSixIdleMinutes` ve `testClaudeTwentyWarmContinuations` ikisi de ilk Anthropic çağrısında şu hata ile durdu:

```text
OAuth access token has been revoked. statusCode=401 retryable=false
```

Bu turda 1 saat TTL kabulü, 5m/1h farkı ve 20 continuation reuse ölçümü başlamadı. Dolayısıyla:

- 1 saat TTL korunuyor mu: doğrulanamadı.
- cache write/read tokenları: alınamadı.
- exact reuse ve coverage: ölçülemedi.
- en büyük engel: Claude OAuth access token iptali.

Kod incelemesi: normal `RouterController.complete` yolu 401 gördüğünde bir kez `refreshCredential(for:)` çağırıp başarılı olursa aynı hesabı yeniden dener. Bu canlı harness ise doğrudan `NativeAgentClient` kullandığından router refresh katmanından geçmiyor. Bu yüzden bu rapor, normal uygulama sohbetinde refresh'in toparladığını veya toparlamadığını kanıtlamaz; yalnız harness yolunda mevcut access token ile 401 alındığını kanıtlar.

## Kayıp ve kabul kararı

| Kayıp/engel | Rota | Kanıt | Token etkisi |
| --- | --- | --- | --- |
| Önceki cache boundary doğrulanamadı | ChatGPT | `previous_boundary_unverified`, `raw cached=14080` | Kesin kayıp token yok; kapsam kaybı var |
| OAuth access token iptal edilmiş | Claude | HTTP 401, `OAuth access token has been revoked.` | Cache ölçümü başlamadı; token kaybı ölçülemedi |
| Normal router refresh yolu harness'te devrede değil | Claude harness | `PromptCacheLiveTests` doğrudan `NativeAgentClient` çağırıyor; router 401 refresh kodu ayrı | Kabul kanıtı yok |

Kabul kararı: %99,9 exact reuse ve %95 ölçüm kapsamı hiçbir rota için doğrulanmadı. ChatGPT cache okuması canlı olarak çalışıyor, fakat kabul hesabı için gerekli previous boundary kanıtı eksik. Claude rotası geçerli OAuth oturumu gerektiriyor; kullanıcı yeniden giriş yaptıktan sonra normal router/harness ayrımı korunarak tekrar denenmeli.

## Sonraki işlem

1. Claude hesabını HerNess içinden yeniden bağla veya revoked oturumu yenile.
2. Claude için normal router yolunda bir kısa canlı istekle 401 refresh'in toparlayıp toparlamadığını ayrı kanıtla; ardından cache harness'i yeniden çalıştır.
3. ChatGPT için previous boundary proof üretmeyen yolu düzeltmeden 20 continuation testi sürdürme; aksi halde raw hit artsa bile kabul oranı yine unknown kalır.
