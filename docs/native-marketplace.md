# Native Plugin Marketplace

Marketplace registry ve artifact API'si Cloudflare Worker tarafından servis edilir:

- Public registry: `GET https://dots.net.tr/harness/registry.json`
- Community registry: `GET https://dots.net.tr/harness/community-registry.json`
- Public artifact download: Worker `/assets/*` route'u üzerinden R2
- Authenticated publish: `/api/marketplace/*`
- CI callbacks: `/api/marketplace/ci/*`
- Admin moderation: `/api/admin/marketplace/reviews` ve `/api/admin/marketplace/reports`

Ana Marketplace ile Community / Experimental alanı bilinçli olarak ayrıdır. Eğlence,
novelty, lifestyle veya Harness'ın çekirdek geliştirici/agent iş akışına doğrudan
uymayan ama zararsız pluginler reddedilmez; AI tarafından `community` kategorisine
ve ayrı kataloğa atanır. `experimental` içerik de ana keşif listesinden ayrılır.

## Yayın akışı

1. macOS uygulaması HerNess OAuth/email oturumunu Keychain'de açar.
2. `plugin.yml`, `plugin.ir.json`, `license` ve `source/<platform>/` klasörleri doğrulanır.
3. Plugin ID ilk yayıncıya ayrılır; release SemVer ve lisansla `draft` olarak oluşur.
4. Source bundle immutable R2 anahtarına yüklenir; release CI doğrulaması tamamlanana kadar `draft` kalır.
5. Source upload sonrasında Worker, plugin manifesti ve declarative IR metadata'sını TypeSafe/Jev ile sınıflandırır. AI otomatik olarak kategori, katalog alanı, risk seviyesi ve görünen izinleri verir; kullanıcı bu alanları elle seçemez.
6. AI çıktısı tek başına yayın yetkisi değildir. Her release `pending_review` durumuna gider; AI servisi yoksa veya belirsizlik varsa fail-closed olarak yine insan incelemesine alınır. Açık kötüye kullanım sinyalleri (`credential theft`, secret exfiltration, persistence, destructive behavior vb.) reddedilir; yüksek riskli raporlar release'i anında `suspended` yapar.
7. GitHub Actions macOS arm64/x64, Windows x64 ve Linux x64 matrix'iyle derler. Artifact hash + DOTS Ed25519 imzasıyla `ready` olması yalnızca build/integrity başarısıdır; release ancak admin `approved` kararı verdikten ve en az bir artifact hazır olduktan sonra `published` olur.
8. İstemci imzayı, SHA-256'yı, manifest ID/sürümünü ve native library'yi doğrular; kullanıcı açıkça kabul etmeden native kod mount edilmez. Kurulum ekranında AI kategorisi, alanı, risk seviyesi ve izinleri gösterilir.

## Moderasyon durumları

- `pending_ai`: source bundle geldi, AI sınıflandırması bekleniyor.
- `pending_review`: sınıflandırma yapıldı veya AI kullanılamadı; insan incelemesi bekleniyor.
- `approved`: admin onayı var; build hazırsa ilgili kataloğa yayınlanabilir.
- `rejected`: release yayınlanmaz ve build kuyruğuna alınamaz.
- `suspended`: rapor veya inceleme nedeniyle yayından çekilmiştir.

Raporlama authenticated kullanıcılar için `POST /api/marketplace/plugins/:id/reports`
üzerinden yapılır. Malware, credential theft ve data exfiltration raporları, insan
incelemesi tamamlanana kadar yayınlanan release'i otomatik olarak yayından çeker.

## Üretim kurulumu

Remote D1 migration'ları Worker deploy'undan önce uygulayın:

```bash
cd cloudflare
npm run db:migrate:remote
```

Ardından Wrangler secret olarak yalnızca üretim ortamında şunları tanımlayın:

- `MARKETPLACE_SIGNING_PRIVATE_KEY`: `wrangler.jsonc` içindeki public key ile eşleşen Ed25519 JWK
- `MARKETPLACE_CI_SECRET`: private source download için sınırlı CI secret
- `MARKETPLACE_BUILD_DISPATCH_TOKEN`: yalnızca ilgili GitHub Actions workflow dispatch yetkisi
- `TYPESAFE_API_KEY`: yalnızca Worker secret olarak saklanan TypeSafe API anahtarı

Örneğin secret'ı deploy ortamına yalnızca Wrangler üzerinden ekleyin:

```bash
npx wrangler secret put TYPESAFE_API_KEY
```

GitHub repository variables/secrets:

- `MARKETPLACE_API_URL`: Worker public API origin'i
- `MARKETPLACE_CI_OIDC_AUDIENCE`: `wrangler.jsonc` içindeki OIDC audience ile aynı değer
- `MARKETPLACE_CI_SECRET`: Worker secret ile aynı değer; public source için bile artifact callback OIDC kullanılabilir

Sonra:

```bash
npm run deploy
```

Migration `0004_marketplace_moderation.sql` uygulanmadan yeni moderasyon alanları
kullanılamaz. Mevcut release'ler güvenli varsayılan olarak `pending_review` +
`community/other` konumuna alınır; admin incelemesi olmadan tekrar görünür olmaz.

Üretim secrets veya deploy bu çalışma sırasında otomatik olarak uygulanmaz; signing private key, CI token ve GitHub yetkileri repository'ye commit edilmemelidir.

## Güven modeli

`verified`, format/native build ve insan yayın incelemesinin tamamlandığını belirtir;
mutlak güvenlik garantisi değildir. Registry'deki imza, artifact'in DOTS anahtarıyla
imzalandığını gösterir. Plugin üçüncü taraf native kod çalıştırdığı için istemci
tarafındaki açık kullanıcı onayı zorunludur. AI sınıflandırması bir güvenlik sandbox'ı
veya kaynak kodu denetimi değildir; kararsız kararlar insan onayına gider.
