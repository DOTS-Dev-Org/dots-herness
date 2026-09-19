# Yasal Metinler — DOTS Herness

Uygulamanın Gizlilik Politikası ve Kullanıcı Sözleşmesi metinleri **uygulamaya
gömülü değildir**; sürümlü DOTS Herness Worker endpoint'inden canlı çekilir.
Metin gövdesi D1'de readback için, immutable kopyası R2'de tutulur ve istemci
iki SHA-256 değerini doğrular.

## Kaynak

Mevcut TR/EN metinlerinin kaynak kaydı DOTS web sitesi veritabanıdır (`apps`
tablosu, `slug = 'dots-herness'`). Yeni dağıtımın kanonik kaydı ise bu
checkout'taki D1 migration ve import scriptidir:

- `cloudflare/migrations/0003_legal_documents.sql`
- `cloudflare/scripts/seed-legal-documents.mjs`
- R2: `legal/dots-herness/<version>/<locale>/terms.md`
- R2: `legal/dots-herness/<version>/<locale>/privacy-notice.md`

Metin sürümü: **2026-08-26**. Veri sorumlusu: **DOTS Tech A.Ş.** ·
destek@dots.net.tr · Konya.

## Uygulamanın çektiği URL'ler

Sabit uç:

| Amaç | URL |
|---|---|
| JSON içerik (uygulama içi render) | `https://dotsherness-unified-backend.dotsherness-unified-backend.workers.dev/api/legal/documents?locale=<locale>` |
| R2 gövdesi | Yanıttaki `documents.*.r2_url` |

İçerik Markdown'dır. İstenen locale mevcut değilse veya belge `draft` durumundaysa istemci hata
gösterir; Türkçe ya da İngilizceye sessizce düşmez. `system` seçimi cihazda
çözülerek somut bir locale olarak gönderilir.

`LEGAL_MASTER_LOCALES = ["tr"]` bağlayıcı kabul için korunur. Ek dil taslakları
çeviri kontrolü tamamlanana kadar `draft` kalır; hukuki onay olmadan
`approved/published` yapılmaz.

## Uygulama içi davranış

Giriş ekranında **sert onay kapısı**:

1. İlk açılışta metinler JSON ucundan çekilir; kullanıcı isterse sözleşme veya
   gizlilik metnini ayrı bir görüntüleyicide açar.
2. Kullanıcı **Kullanıcı Sözleşmesi + Gizlilik Politikası** metinlerini gördükten
   sonra uygulama açılır; kabul, alttaki **İleri** düğmesine basılmasıyla kaydedilir.
3. **Açık rıza maddeleri** (AI içerik aktarımı / GitHub / ses / ticari ileti),
   Kullanıcı Sözleşmesi metninin içinde ayrı ayrı işaretlenir veya atlanır.
   "AI içerik aktarımı" rızası yoksa yapay zeka özellikleri kapalı kalır.
4. Kabul kaydı yerelde saklanır: `legal.acceptedVersion`, `legal.acceptedAt`,
   her rıza maddesi için ayrı bayrak.
5. **Ayarlar → Yasal ve Gizlilik**: metinleri tekrar açar, rıza tercihlerini
   değiştirir, "web'de aç" linki verir.
6. Çevrimdışıysa ve daha önce kabul edilmişse uygulama açılır; hiç kabul
   yoksa ağ bağlantısı istenir.

Metin sürümü değişince (`legal.version` uçtan gelir) yeniden onay istenir.
