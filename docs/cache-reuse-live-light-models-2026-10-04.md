# Dusuk modellerle canli cache kontrolu

Tarih: 4 Ekim 2026, Europe/Istanbul. Yeni Claude baglantisi sonrasinda gercek saglayici kontrolleri.

## Kapsam ve model secimi

Yerel `providers.json` katalogunun light modelleri Claude Haiku 4.5
(`claude-haiku-4-5`) ve GPT-5.4 Mini (`gpt-5.4-mini`) secildi.
GPT-5.4 Mini iki testin ilk isteginde HTTP 400 verdi. Hatanin cevabi
`Model request failed (HTTP 400)` oldugu icin emeklilik, hesap yetkisi veya
istek semasi gibi daha belirli bir neden kanitlanamadi.
Ardindan katalogdaki dusuk model GPT-5.6 Luna (`gpt-5.6-luna`) denendi.
Kayitli hesap/model tercihleri degistirilmedi; secim yalniz test konfigurasyonunda yapildi.

Bu kontrol macOS `NativeAgentClient` canli harness yolundadir.
Normal uygulama router'i, OAuth refresh ve sohbet UI'si bu testin kapsaminda degildir.
Mobil veya Windows calisma kaniti uretilmedi.

## Sonuclar

| Kontrol | Sonuc | Gercek kanit |
| --- | --- | --- |
| GPT-5.4 Mini ayni prompt / continuation | Basarisiz | Iki ilk istekte HTTP 400; cache sayaci yok |
| GPT-5.6 Luna ayni prompt | Gecti | Ilk input 14640; ikinci input 14640, read 14080; cevap OK |
| GPT-5.6 Luna ilk continuation | Cache okumasi var; kesin kabul atlandi | Input 14662, read 14080, write unknown, boundary false, TTL unknown |
| Claude Haiku 4.5 ayni prompt | Atlandi | Keychain -25293; saglayici istegi gonderilmedi |
| Claude Haiku 4.5 20 continuation | Atlandi | Keychain -25293; saglayici istegi gonderilmedi |
| Claude Haiku 4.5 5m/1h TTL | Atlandi | Keychain -25293; alti dakikalik deney baslamadi |

Luna ayni prompt tekrarinda raw cached/input orani %96.17;
ilk continuation'da %96.03. Bunlar uygun gecmisin kesin yeniden kullanim
orani degildir. Ilk isteklerde read/write sayaclari unknown; unknown sifir kabul edilmedi.
`previous_boundary_unverified` nedeniyle 20 continuation kabul testi ilk
devamda durdu. Kesin olcum kapsami 0/20; %99.9 reuse ve %95 coverage dogrulanmadi.

Son test sonucu: 5 test, 1 gecti, 4 atlandi, 0 failure.
Suite'in passed olmasi atlanan kontrollerin basarili oldugu anlamina gelmez.

## Keychain engeli

Ilk surec Claude credential okurken `SecItemCopyMatching` icinde bekledi.
Surec ornegi `/private/tmp/herness-cache-live-sample.txt` bunu gosterdi.
Computer Use, `com.apple.SecurityAgent` kontrolunu guvenlik nedeniyle reddetti.
Bekleyen test sureci sonlandirildi; son denemede legacy Keychain UI etkilesimi
yalniz senkron okuma boyunca kapatilarak hata aninda skip saglandi.
Credential veya parola loglanmadi, Keychain ACL'leri degistirilmedi.
Bu sonuc yeni Claude token'inin revoked oldugunu gostermez; token okunamadi.

Claude icin XCTest'in ilgili Keychain kaydina kullanici tarafindan erisimi
yetkilendirilmeli veya uygulamanin zaten yetkili normal yolu uzerinden
canli olcum yapilmalidir. Kullanici parolasi sohbete gonderilmemelidir.

## Butce ve loglar

- Onceki raporda 4 model transport denemesi vardi.
- Mini denemesinde iki HTTP 400 istegi oldu. Tamponlu transport loglari surec
  sonlandirilinca kayboldu; iki sayisi terminal test hatalari ve genel HTTP 400
  icin fallback yapmayan istemci akisi uzerinden cikarildi.
- Luna denemesinde transport_attempt 1..4 dogrudan loglandi; retry/fallback yok.
- Bu tur 6 model istegi; onceki raporla toplam 10/50 (Mini sayisi yukaridaki gibi cikarimdir).
- Ilk test limit 46; ikinci surecte ihtiyatli limit 30 olarak ayarlandi.
- Ilk log: `/private/tmp/herness-cache-live-2026-10-04-light-models.log`.
- Ikinci log: `/private/tmp/herness-cache-live-2026-10-04-light-models-retry.log`.

Ikinci komut (macos/DotsHarness dizininde):

```sh
DOTS_CACHE_LIVE=1 DOTS_CACHE_KEYCHAIN_INTERACTIVE=1 DOTS_CACHE_LIVE_LIMIT=30 DOTS_CACHE_CLAUDE_MODEL=claude-haiku-4-5 DOTS_CACHE_CHATGPT_MODEL=gpt-5.6-luna swift test --disable-sandbox --filter PromptCacheLiveTests
```

Harness'e test modeli override, dusurulebilir transport limiti, tamponlanmayan
sayac loglari, OK cevap kontrolu ve iki saglayici icin ayni prompt tekrar testi eklendi.
Urun cache mantigi degistirilmedi.

## Dokuman kontrolu

Context7 bu oturumda erisilebilir degildi. Resmi kaynaklar kontrol edildi:

- [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)
- [GPT-5.4 Mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini)
- [Claude prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [Apple Keychain interaction](https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:))

Haiku 4.5 icin resmi minimum 4096 token; test uzun sabit prompt kullanir.
Claude sayaclari alinamadigi icin bu testte esigin asildigi saglayici kanitiyla teyit edilmedi.
