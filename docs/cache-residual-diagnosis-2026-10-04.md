# Luna cache disinda kalan tokenlarin teshisi

4 Ekim 2026, Europe/Istanbul. Bu rapor onceki 14640 input / 14080 cached
sonucundaki 560 token farkini kontrollu canli isteklerle inceler.

## Kanitlanan sonuc

Eksik okumanin buyuk bolumu tekrar eklenmis veya yeni bir mesaj degil:
saglayici, ayni uzun developer mesajinin son kismini cached olarak saymiyor.
Tam ve sabit Codex instructions cache'den okunuyor.
Bu rotada %100'e yakin raw cache hit elde edilemedi.
Saglayicinin ic cache algoritmasinin tam nedeni aciklanmiyor;
basarisiz ayarlari destekliyormus gibi urune eklemedik.

Ilk kontrollu tekrar icin saglayicinin ham `usage.attribution` sonucu:

| Bolum | Input | Cached | Cache disinda |
| --- | ---: | ---: | ---: |
| Codex instructions | 2695 | 2695 | 0 |
| Uzun developer mesaji | 11932 | 11385 | 547 |
| Sabit kullanici mesaji | 9 | 0 | 9 |
| Saglayicinin diger mesaj girdisi | 2 | 0 | 2 |
| Toplam | 14638 | 14080 | 558 |

Onceki 560 ve bu deneydeki 558 arasindaki fark, deney etiketindeki yeni UUID
gibi input farklariyla uyumludur; onceki istegin ham attribution kaydi yoktur.
Onceki tam 560 tokenin bolum dagilimini geriye donuk kanit olarak sunmuyoruz.
Yeni canli deney, ayni belirtili kaybi dogrudan developer mesajina yerlestiriyor.

700 kuralli prompt ayni icerikle uc kez gonderildi: ilk read 0, sonraki iki
read 14080. Ucuncu tekrar cache disinda kalan son bolumu azaltmadi.
Devam mesaji eklenince input 20 token artti; read yine 14080 kaldi.
300 kuralli daha kisa prompt'ta input 7838, read 6912:
developer input 5132 / read 4217, instructions input/read 2695.
Burada eski developer mesajindan 915 token cache disinda kaldi.
Fark sabit bir gizli 560-token maliyetine uymuyor.

## Wire ve provider kaniti

Ikinci kontrollu deneyde gercek HTTP body'si okunarak, icerik degistirilmeden
ayni byte'larla iletildi. Instructions/input/tools kanonik SHA-256:

- Ayni 700-rule prompt: `92d305eefe1887ac42fce5cf9a00a22f7995867a73b25eb6a699183ed553d0e9`
- Devam mesaji eklenmis sabit prompt: `a390488b7cf4d94c3f2a20945a86534dc6aac958864000edcf915aded80ef9a7`
- Ayni 300-rule prompt: `3f262d035d2a16613c430e816affa4833d68479a9695406178377593d20d57d3`

Tekrarlar icinde hash degismedi. Roller ilk istekte developer,user;
devam isteginde developer,user,assistant,user. Tool sayisi 0.
`Reference rule 0:` her wire body'sinde bir kez bulunuyor.
Saglayicinin terminal response model'i `gpt-5.6-luna`.
Kimlik bilgileri, header degerleri veya prompt metni loglanmadi.

Bu ikinci deneyde 700-rule input 14643 oldu. Read dizisi:
0, 14080, 0; devam istegi ve ayni devam istegi tekrari 14080, 14080.
Ayni icerigin ucuncu isteginde gercek bir tam read miss var.
Cache kaybi yalniz yuvarlama/yeni mesaj ile aciklanamaz.
Yerel icerik ayni olsa da provider routing/eviction gibi ic nedenlerin
hangisinin etkili oldugu kanitlanamadi.
Istegin diagnostik comparison alanina response `type: unavailable` verdi.
Bu nedenle %99.9 exact eligible reuse hedefi yine dogrulanamadi.

Read degerlerinin farkli prompt uzunluklarinda basamakli davranmasi provider
cache siniri/granulerligiyle uyumludur. Bir endpoint-sozlesmesi veya kesin
diagnostic olmadan sabit 1024-token quantum iddiasinda bulunmuyoruz.

## Cache hit artirma deneyleri

Iki yalniz-test wire deneyi yapildi; kayitli hesaplar ve urun cache ayarlari degismedi.

1. Developer sonunda explicit breakpoint + `prompt_cache_options.mode=implicit`:
   ilk istekte HTTP 400, `prompt_cache_options is not supported on this model`.
2. Yalniz developer sonunda explicit breakpoint:
   ilk istekte HTTP 400, `prompt_cache_breakpoint is not supported on this model`.

Her deney reddedilince durdu. Toplam iki deney istegi.
Public OpenAI Responses destek tablosu abonelik gateway'ine tasinmadi.
Bu Luna endpoint'inde tail'i zorla cache'e almak icin denenmis iki kontrol
kullanilamiyor. Raw oran yukseltilmedi; payda daraltilarak ya da gereksiz
metin/padding eklenerek daha iyi bir oran uretilmedi.

Ucuncu bir deneyde ayni sabit developer icerigi cift gonderilmeden
Codex instructions alaninin sonuna tasindi. 3 ayni prompt + 2 continuation
istegi yapildi. Input 14635, warm read 14080; continuation input 14655,
read yine 14080. Uzun instructions da artik kismen cached gorunuyor.
Bu, talimatin developer yerine instructions alaninda bulunmasinin cache
sinirini gidermedigini gosteriyor. Goreli oran degisimi farkli nonce/mesaj
cercevesi tokenlarindan etkilenebilir; cached token sayisinda artis yok.
Bu yerlesim degisikligi urune tasinmadi.

20 yeni tokenin matematiksel etkisi:
14080/14640 = %96.1749; 14080/14660 = %96.0437.
Onceki olculen continuation 14662 input oldugundan sonucu %96.0306 idi.
Yeni mesaj yaklasik 0.14 yuzde puan etkiliyor; asil fark eski developer tail'idir.

## Bulunan ve duzeltilen uygulama hatasi

`JSONCodec.value(from:)` icinde NSNumber icin once `as? Bool` deneniyordu.
Foundation'in bridge davranisi sayisal 0 ve 1'i false/true olarak okuyordu.
Sonuc: gercek cached_tokens=0 / cache_write_tokens=0 degerleri `.int` ile
okunamiyor, uygulamada unknown olarak gorunuyordu; output_tokens=1 de kaybolabiliyordu.

JSON bool/number ayrimi simdi CFBoolean tip kimligiyle yapiliyor.
Bulunmayan alanlar unknown kalirken bildirilen 0 ve 1 sayisal korunuyor.
Bu bir olcum/parser duzeltmesidir; gercek provider cache hit'ini artirdigi iddia edilmiyor.

Bagimsiz codec kontrolunde duzeltmeden once numeric zero, numeric one ve
nested values FAIL; duzeltmeden sonra alti kontrolun tamami PASS.
JSONCodecTests icinde sayi/bool ayrimi, terminal SSE sifir sayaclari ve
eksik sayaclarin unknown kalmasi icin uc regresyon testi eklendi.
Son derlenmis test bundle'inda JSONCodec + cache evidence/epoch/improvement
suiteleri: 39 test, 0 failure.

Mobile iOS ve Android parser'lari da incelendi: iOS sayaclari NSNumber.intValue,
Android Number.toInt ile okuyor; bildirilen sayisal sifiri zaten koruyorlar.
Bu macOS codec hatasi onlarda ayni yoldan olusmuyor; mobil kod degismedi.
Mobil build/simulator testi bu tur yapilmadi.

## Kapsam, butce ve loglar

Bu tur 8 ilk teshis + 1 options reddi + 8 wire/diagnostic kontrolu +
1 marker reddi + 5 instructions yerlesim kontrolu = 23 model transport istegi.
Onceki yaklasik 10 ile toplam yaklasik 33/50.
Yeni turdaki 23 istek transport counter ile dogrudan kayitli.
Prewarm/keepalive yok; deneyler soguk baslangic ve normal tekrar/devam isteklerinden olusuyor.
Kontroller NativeAgentClient harness'inde; uygulama UI/router canli kabul kaniti degildir.
Claude'a bu tur model istegi gonderilmedi.

- Ilk teshis: `/private/tmp/herness-cache-residual-2026-10-04-retry.log`
- Wire/ham attribution/diagnostics: `/private/tmp/herness-cache-residual-verified-2026-10-04.log`
- Options reddi: `/private/tmp/herness-cache-breakpoint-2026-10-04.log`
- Marker reddi: `/private/tmp/herness-cache-marker-2026-10-04.log`
- Instructions yerlesimi: `/private/tmp/herness-cache-instructions-2026-10-04.log`
- Son 39 regresyon testi: `/private/tmp/herness-cache-regression-final-2026-10-04.log`

Iki SwiftPM derlemesi baska islemlerin FeedbackLearningTests/TrayPanelView
dosyalarini ayni anda degistirmesi nedeniyle durdu. Var olan degisiklikler
korundu; derlenmis bundle uzerinden nihai testler calistirildi.

Context7 erisilebilir degildi; [OpenAI cache dokumani](https://developers.openai.com/api/docs/guides/prompt-caching),
[diagnostics](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics) ve
[Apple CFBoolean API](https://developer.apple.com/documentation/corefoundation/cfbooleangettypeid()) kontrol edildi.

Kabul karari: client kaynakli tekrar/prefix rewrite bu deneyde bulunmadi;
sayac parser hatasi giderildi. Provider'in kalan tail ve aralikli miss davranisi
nedeniyle bu rotada %100'e yakin raw hit / %99.9 exact reuse saglandigi soylenemez.

## 6 Ekim 2026 ek notu

Gorunen `%95,6` satiri provider'in `cached_tokens / input_tokens` oranidir.
Bu oran yeni kullanici mesaji, cevaba eklenen devam input'u ve provider'in
breakpoint disinda biraktigi terminal kismi ayni paydada toplar. Onceki
cachelenebilir prefix icin asil kabul metrigi `eligibleTokens / reusedTokens`
olmalidir.

Uygulama artik exact reuse ozetinde `freshInputTokens` degerini ayri tutar.
Ornek 14.640 input / 14.080 cached durumda, onceki eligible prefix 14.080 ve
reused 14.080 ise reuse %100'dur; kalan 560 token `cache loss` degil, yeni veya
breakpoint disi input olarak gosterilir. Gercek provider usage sayaci
degistirilmez ve maliyet hesabi yine ham usage alanlarina dayanir.

ChatGPT abonelik gateway'i public OpenAI Responses diagnostics alanlarini
desteklemiyor. `comparison_response_id` artik yalnizca host'u
`api.openai.com` olan public Responses rotasinda gonderiliyor; gateway'e
gonderilmiyor. Boylece devam isteklerinde gereksiz 400 + retry cache rotasini
kirletmiyor. Bu, provider'in 1024'luk okuma basamagini degistirmez; onu
degistirdigini iddia eden bir padding veya prewarm eklenmedi.
