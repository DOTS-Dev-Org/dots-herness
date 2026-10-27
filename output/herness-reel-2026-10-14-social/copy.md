# HerNess — 20 saniyelik dikey sosyal medya videosu

1. 0–3 sn — HerNess · Fikrinden çalışan çözüme.
2. 3–7 sn — Model özgürlüğü · 25 hazır sağlayıcı · İhtiyacına göre seç.
3. 7–11,5 sn — Projende üret · Oku. Düzenle. Çalıştır.
4. 11,5–14,5 sn — Zamanlanmış görevler · Sen planla. O çalışsın.
5. 14,5–17,5 sn — HerNess her cihazda · macOS, Windows, Linux, iOS, Android.
6. 17,5–20 sn — HerNess · Yapay zekâ çalışma alanın · herness.dots.net.tr · DOTS.

## Doğrulanmış ürün bilgileri

- “25 hazır sağlayıcı”: `macos/DotsHarness/Sources/DotsHarnessCore/Resources/providers.json` içindeki 25 benzersiz görünen ad. Dosyada Anthropic için iki ayrı bağlantı profili olduğundan toplam kayıt sayısı 26.
- Beş platform: masaüstü macOS, Windows, Linux ile mobil iOS ve Android istemcileri; `docs/platform-parity.md` ve `mobile/README.md`.
- Zamanlanmış görevler: `macos/DotsHarness/Sources/DotsHarnessUI/TasksView.swift` ve `macos/DotsHarness/Sources/DotsHarnessCore/ScheduledTask.swift`.
- Tanıtım bağlantısı: `cloudflare/wrangler.jsonc` içindeki `FRONTEND_URL`.
- Proje ekranı gerçek ekran görüntüsü değildir; tarafsız örnek verilerle HTML/CSS olarak çizilmiştir.
- Video müziği `music.py` ile yerel olarak sentezlenir. Ses sentezlenmiş, dinleme kontrolü yapılmamıştır.

## Yeniden oluşturma

```sh
node render.mjs 2 5.5 9 13.8 16.6 19.5
node render.mjs
```

Çıktı 1080×1920, 30 fps, 20 saniye, H.264/AAC MP4'tür.
