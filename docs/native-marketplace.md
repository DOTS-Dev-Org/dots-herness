# Native Plugin Marketplace

Marketplace registry ve artifact API'si Cloudflare Worker tarafından servis edilir:

- Public registry: `GET https://dots.net.tr/harness/registry.json`
- Public artifact download: Worker `/assets/*` route'u üzerinden R2
- Authenticated publish: `/api/marketplace/*`
- CI callbacks: `/api/marketplace/ci/*`

## Yayın akışı

1. macOS uygulaması HerNess OAuth/email oturumunu Keychain'de açar.
2. `plugin.yml`, `plugin.ir.json`, `license` ve `source/<platform>/` klasörleri doğrulanır.
3. Plugin ID ilk yayıncıya ayrılır; release SemVer ve lisansla `draft` olarak oluşur.
4. Source bundle immutable R2 anahtarına yüklenir; release CI doğrulaması tamamlanana kadar `draft` kalır.
5. GitHub Actions macOS arm64/x64, Windows x64 ve Linux x64 matrix'iyle derler. İlk başarılı native artifact hash + DOTS Ed25519 imzasıyla `ready` olduğunda release `published` olur; başarısız hedef `failed` olarak kalır ve diğer hedefleri engellemez.
6. İstemci imzayı, SHA-256'yı, manifest ID/sürümünü ve native library'yi doğrular; kullanıcı açıkça kabul etmeden native kod mount edilmez.

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

GitHub repository variables/secrets:

- `MARKETPLACE_API_URL`: Worker public API origin'i
- `MARKETPLACE_CI_OIDC_AUDIENCE`: `wrangler.jsonc` içindeki OIDC audience ile aynı değer
- `MARKETPLACE_CI_SECRET`: Worker secret ile aynı değer; public source için bile artifact callback OIDC kullanılabilir

Sonra:

```bash
npm run deploy
```

Üretim secrets veya deploy bu çalışma sırasında otomatik olarak uygulanmaz; signing private key, CI token ve GitHub yetkileri repository'ye commit edilmemelidir.

## Güven modeli

`unverified` yalnızca otomatik format/native build doğrulamasının tamamlandığını belirtmez; güvenlik incelemesi anlamına gelmez. Registry'deki imza, artifact'in DOTS anahtarıyla imzalandığını gösterir. Plugin üçüncü taraf native kod çalıştırdığı için istemci tarafındaki açık kullanıcı onayı zorunludur.
