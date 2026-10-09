# Sürüm Yönetimi ve Otomatik Güncelleme Mimarisi

Bu doküman, **DOTS HerNess** uygulamasının çok platformlu (macOS, Windows, Linux, iOS, Android) ekosistemindeki sürüm numaralandırma, güncelleme denetimi ve otomatik yayınlama süreçlerini açıklar.

---

## 1. Sürüm Numaralandırma Standardı (SemVer)

Uygulamada standart Semantic Versioning (`MAJOR.MINOR.PATCH`) kullanılır:

* **MAJOR (`X.0.0`):** Geriye dönük uyumsuz mimari değişiklikler veya büyük protokol kırılmaları.
* **MINOR (`0.X.0`):** Yeni yetenekler, yeni AI sağlayıcıları, yeni araçlar veya yeni platform özellikleri.
* **PATCH (`0.0.X`):** Hata düzeltmeleri, güvenlik yamaları ve performans iyileştirmeleri.

### Tek Gerçek Kaynak: `VERSION`
Kök dizindeki `VERSION` dosyası projenin kanonik sürümünü tutar.

### Sürüm Artırma Aracı (`tools/bump_version.py`)
Sürümleri güvenle yükseltmek ve tüm platform dosyalarını otomatik senkronize etmek için:

```bash
# Mevcut sürümü gösterir
python3 tools/bump_version.py --show

# Patch sürümünü artırır (örn. 0.1.0 -> 0.1.1) ve ilgili dosyalara uygular
python3 tools/bump_version.py --bump patch

# Minor sürümünü artırır (örn. 0.1.1 -> 0.2.0)
python3 tools/bump_version.py --bump minor

# Major sürümünü artırır (örn. 0.2.0 -> 1.0.0)
python3 tools/bump_version.py --bump major

# Belirli bir sürüme eşitler
python3 tools/bump_version.py --set 0.3.0
```

---

## 2. Güncelleme Kontrol API'si (Cloudflare Worker)

Backend, istemcilerin yeni sürümleri sorgulaması için hafif ve CDN önbellekli iki ana uç nokta sunar:

### A. Güncelleme Denetimi (`GET /harness/check-update`)
İstemci açılışında veya kullanıcı "Güncellemeleri Denetle" dediğinde çağrılır.

**İstek:**
```http
GET https://dots.net.tr/harness/check-update?platform=macos&version=0.1.0&build=1
```

**Başarılı Yanıt Örneği:**
```json
{
  "platform": "macos",
  "current_version": "0.1.0",
  "latest_version": "0.2.0",
  "build_number": 15,
  "min_supported_version": "0.1.0",
  "update_available": true,
  "mandatory": false,
  "release_notes": "• Yeni sesli etkileşim optimizasyonu\n• Claude 3.7 desteği",
  "download_url": "https://github.com/DOTS-Dev-Org/dots-herness/releases/download/v0.2.0/DotsHarness-0.2.0.dmg",
  "published_at": "2026-09-21T00:00:00Z"
}
```

### B. Tüm Platform Sürüm Matrisi (`GET /harness/version.json`)
Masaüstü ve mobil tüm platformların en son sürümlerini tek json içinde listeler.

### Zorunlu Güncelleme Mantığı (`mandatory: true`)
Eğer kullanıcının mevcut sürümü `min_supported_version` değerinden küçükse `mandatory: true` döner. Bu durumda istemci arayüzünde zorunlu güncelleme uyarısı gösterilir.

---

## 3. İstemci Tarafı Mimarisi

### macOS (Swift / SwiftUI)
* **Servis:** `UpdateChecker.swift` (`DotsHarnessCore`)
  * `CFBundleShortVersionString` ve `CFBundleVersion` değerlerini okur.
  * Açılışta `AppModel+Lifecycle.swift` üzerinden sessiz bir arka plan sorgusu yapar (24 saatlik önbellek sınırı ile).
* **Arayüz:** `SettingsView.swift` (`DotsHarnessUI`)
  * Ayarlar > Genel sekmesinde "Sürüm ve Güncellemeler" bölümü yer alır.
  * Mevcut yüklü sürümü gösterir.
  * "Güncellemeleri Denetle" butonu ile manuel tetikleme imkanı sağlar.
  * Yeni sürüm varsa sürüm notları ve doğrudan "Güncellemeyi İndir" butonunu sunar.

### Windows & Linux (.NET 8 C#)
* **Servis:** `shared/UpdateChecker.cs` (`CrossPlatformUpdateChecker`)
  * `DotsHarnessCore` içine derlenir; `CheckOnStartupAsync(platform)` açılışta sessizce sorgular.
  * Windows (`MainWindow.xaml.cs`) ve Linux (`App.axaml.cs`) yasal onaydan sonra güncelleme diyaloğu gösterir; `mandatory` ise uygulama kapanır.

---

## 4. Yeni Sürüm Yayınlama Süreci (Release Workflow)

Yeni bir sürüm yayınlanacağı zaman:

1. **Sürümü yükseltin ve senkronize edin:**
   ```bash
   python3 tools/bump_version.py --bump minor
   ```
2. **Değişiklikleri commit'leyin:**
   ```bash
   git commit -am "chore: release v0.2.0"
   ```
3. **Git tag oluşturun ve gönderin:**
   ```bash
   git tag v0.2.0
   git push origin main
   git push origin v0.2.0
   ```
4. **GitHub Actions (`release.yml`):**
   * Tag'i algılar.
   * `package-dmg.sh VERSION=0.2.0` script'ini çalıştırarak macOS için optimize edilmiş `.dmg` paketini üretir.
   * GitHub Releases sekmesinde otomatik yeni sürüm oluşturur ve `.dmg`, `.tar.gz` (Linux) ve `.zip` (Windows) dosyalarını ekler. Tag, `VERSION` dosyasıyla eşleşmezse yayın başarısız olur.
   * `deploy-worker` işi Cloudflare Worker'ı deploy eder (repo secret'ları: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`), böylece `check-update` yeni sürümü hemen döner.
