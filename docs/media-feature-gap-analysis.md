# Medya özellikleri: karşılaştırma ve eksik listesi

**İnceleme tarihi:** 27 Ekim 2026  
**Kapsam:** HerNess'in macOS, Windows, Linux, iOS ve Android Media bölümleri ile Nashi, Banana Studio ve ClipBoardLine depolarındaki kullanıcı akışları.

Bu rapor kaynak kodu ve depoların herkese açık özellik belgeleri üzerinden hazırlanmıştır. Referans projelerin kodu alınmadı; öneriler özellik ve etkileşim kalıplarını uyarlamaya yöneliktir.

## Uygulama durumu

İlk uygulama turunda kaynak dosyayı koruyan kırpma verisi, katmanlı işaretleme, video önizleme/kesme, Medya Kütüphanesi organizasyonu ve yerel OCR eklendi. YouTube kapağı hem masaüstü hem mobil şablon listesinde ayrı bir seçenek olarak görünür. Bu bölüm, ilk incelemedeki “bizde bugün bulunanlar” kısmına göre güncel uygulama durumudur.

| Alan | Uygulanan | Açık kalan / sınır |
|---|---|---|
| Görsel kırpma ve işaretleme | Kırpma kaynağı değiştirmeyen katman verisi olarak saklanır ve tuval dışa aktarımında uygulanır. Serbest, kare, 16:9 ve 9:16 ön ayarları; kalem/fosforlu kalem, ok, metin ve şekil katmanları mevcut platformlara eklendi. | Kırpma alanı henüz görüntü üzerinde sürüklenebilir tutamaçlarla seçilmiyor; oran seçimi sonrasında oran kilidi, Enter/Esc ile uygula/iptal ve ayrı kırpma önizleme akışı yok. Mobil araçlarda serbest çizim/işaretleme tam masaüstü araç çeşitliliğinde değil; mobil crop/markup undo-redo da yok. |
| Video izleme ve kesme | macOS/iOS AVFoundation; Windows WPF oynatıcı + FFmpeg; Linux HTML oynatıcı + FFmpeg; Android yerel VideoView ve MP4 muxer ile oynatma/kesme akışı eklendi. Kaynak klip tutulur, kesilen çıktı varlık olarak projeye eklenir; ilerleme/iptal/hata sunulur. | Android kodlayıcı olmadan akışları yeniden birleştirir ve anahtar kareye hizalar; tam kare hassasiyeti garanti etmez. Windows/Linux'ta dış FFmpeg kurulumu gerekir. Platformlar arasında aynı codec/metadata ve kare hassasiyeti henüz garanti edilmiyor. |
| AI alan düzenleme / fikir üretimi | Mevcut katman planlama ve istemle görsel üretim korunuyor. | Maske ile gerçek bölgesel üretim, referans görselleri/rolleri, kullanıcı onayına açık istem geliştirme, konsept × sonuç sayısı ve karşılaştırmalı sonuç galerisi henüz yok. Mevcut görüntü üretim arayüzü kaynak görseli ve maskeyi sağlayıcıya göndermiyor; seçilmeyen piksellerin korunacağı sözü verilemez. Video modeline göre süre/oran/kalite kontrolleri de tanımlı değil. |
| Medya Kütüphanesi | Favori, klasör, etiket, başlık/istem/etiket/OCR araması, tür ve tarih sıralaması, çoklu seçme ve dışa aktarma eklendi. macOS/iOS Vision, Android ML Kit ile OCR cihazda çalışır. Windows/Linux Tesseract'ı yerelde çağırır. | Windows/Linux için Tesseract ve İngilizce/Türkçe dil verisi ayrıca kurulu olmalı. OCR'a göre arama, öğe OCR'ı çalıştırdıktan sonra kullanılabilir. Teknik dosya ayrıntıları (boyut/çözünürlük/süre/codec) masaüstü kartlarında henüz yok. |
| YouTube kapağı | Ayrı YouTube kapak şablonu doğrudan Templates içindeki sosyal şablonlarda görünür; 1280×720 tuvalle açılır. | Kanal/bölüm bağlantısından analiz ve brief çıkarma, YouTube kartı/güvenli alan önizlemesi henüz yok. |

Bu turdaki kırpma denetimleri ve video iş akışları ilk teslim düzeyindedir; yukarıdaki açık satırlar tamamlanmış gibi değerlendirilmemelidir. Maskeli üretim sağlayıcı desteği eklenene kadar kullanıcı arayüzünde “alan dışı pikseller korunur” vaadi verilmemelidir.

## İnceleme öncesi başlangıç durumu

- Media Studio; bir projede birden çok tuval, hiyerarşik katman, metin, şekil, ikon, çizgi, yorum, görsel ve video öğeleri sunuyor. Katmanları taşıma, boyutlandırma, sıralama, gizleme/kilitleme, geri alma/yineleme, hazır tuval boyutları ve şablonlar var.
- AI tasarım planı bir tuvali katmanlara dönüştürüyor; seçili görsel katmanı metin istemiyle yeniden üretebiliyor. Görsel/video üretimi için ayrı kaynak ve model seçilebiliyor. Görsel üretim şu an tek istemden tek sonuç alıyor; video isteği de model ve metin istemiyle gönderiliyor.
- Tuval ve katman PNG/JPEG/PDF olarak dışa aktarılabiliyor. `slice` aracı, tuvalin seçilen bir dikdörtgenini PNG olarak kaydediyor; bu, kaynak görseli kırpan veya düzenleyen bir araç değil.
- Medya Kütüphanesi üretilen ve içe aktarılan dosyaları tür, başlık ve tarihle listeliyor. Arama başlıkla sınırlı; klasör, etiket, favori, OCR ve çoklu seçim yok.
- Video katmanı tuvalde poster karesi gösteriyor. Katman denetimindeki oynatma düğmesi videoyu sistem oynatıcısında açıyor; Media içinde oynatma, zaman çizelgesi veya kesme yok.
- iOS ve Android Media Studio daha hafif bir düzenleyici sunuyor: hazır tuval/şablonlar, metin/şekil/görsel katmanları, katman taşıma-sıralama ve PNG dışa aktarma var. İki mobil platformda da görsel/video üretimi ve üretim arşivi mevcut; video oynatma iOS'ta VideoPlayer, Android'de VideoView ile yapılıyor. Mobil düzenleyicide görsel kırpma/işaretleme ve video kesme bulunmuyor.

Masaüstü ve mobil Media Studio ayrı veri modelleri ve arayüzler kullanıyor. Mobil Media değişikliklerinde iOS ve Android eşdeğerini aynı iş kapsamında ele almak gerekiyor.

## Referanslardan alınabilecek ürün fikirleri

| Kaynak | Güçlü özellik | Bizdeki karşılığı | Öncelik |
|---|---|---|---|
| [Nashi](https://github.com/orkunisitmak/nashi-app) | Fotoğrafı sürükleyerek kırpma; oranı koruma; klipte oynat/durdur, saniye saniye gezinme ve In/Out ile kesme; klavye kısayolları | Tuvalde bölgeyi PNG dışa aktarma var. Görsel katman kırpma ve video montajı yok. Mobilde temel görsel tuvaline de bu akışlar eklenebilir. | **P0** |
| [Banana Studio](https://github.com/orkunisitmak/banana-studio) | Görselin seçilen maskeli alanını düzenleyip geri kalan pikselleri koruma; referans görseller ve rolleri; istem geliştirme; bir fikirden çoklu konsept/sonuç; sonuç karşılaştırma ve üretim geçmişi | Katman görseli tam istemle üretiliyor. Maske, kaynak görsel referansı, varyasyon/çoklu sonuç ve karşılaştırma akışı yok. | **P1** |
| [Banana Studio](https://github.com/orkunisitmak/banana-studio) | Video modellerinin desteklediği süre, oran, kalite ve referans kontrollerini gösterme; üretim durumunu takip etme | Video üretimi ve durum sorgulama var; Media arayüzünde model yeteneğine göre süre/oran/referans ayarı yok. İş tamamlanınca tek dosya alınabiliyor. | **P1** |
| [ClipBoardLine](https://github.com/orkunisitmak/clipboardline-desktop) | Kırpma ve düzenlenebilir işaretleme; görselden yerel OCR; klasör/etiket/favori; toplu seçme, kopyalama ve dışa aktarma | Şekil/yazı/ok katmanlarıyla tuvale not eklenebiliyor. Kütüphane araması OCR yapmıyor ve öğeler düzenlenebilir biçimde organize edilemiyor. | **P1** |
| [Banana Studio](https://github.com/orkunisitmak/banana-studio) | YouTube bölümünü inceleyip kapak fikri ve YouTube görünüm önizlemesi üretme | Thumbnail şablonumuz var; YouTube video analizi ve gerçekçi önizleme akışı yok. | **P2** |

Nashi'nin PDF/ses dönüşümü, QR okuma ve web'den dosya indirme özellikleri yararlı olabilir; fakat doğrudan tasarım/video düzenleme akışına ait değiller. ClipBoardLine'ın pano yakalama rafları da ayrı bir pano uygulaması deneyimi ve izin modeli gerektiriyor. Bunları Media Studio'ya taşımak yerine gerekirse bağımsız araç olarak değerlendirmek daha uygun.

## Önerilen tamamlama sırası

### 1. Görsel kırpma ve işaretleme — P0

- Görsel katmanda kaynak dosyayı koruyan, geri alınabilir kırpma alanı.
- Serbest oran ve kare/16:9/9:16 gibi oran kilidi; sürükleme ve klavye ile ince ayar.
- Kalem, fosforlu işaretleyici, dikdörtgen, elips, ok ve metin ekleme; ek açıklamaları ayrı katman olarak koruma.
- `Enter` uygula, `Esc` iptal, geri al/yinele; dışa aktarmadan önce kırpılmış sonucu önizleme.
- macOS, Windows ve Linux'ta aynı proje davranışı; iOS/Android'de dokunmatik tutamaçlar ve eşdeğer oran seçenekleri.

### 2. Media içinde video izleme ve kesme — P0

- Video katmanında uygulama içi oynatıcı; oynat/durdur, zaman göstergesi, kare/saniye bazlı gezinme.
- Nashi'deki gibi In/Out tutamaçları ve klavye ile aralık seçimi.
- Kaynağı ezmeden yeni MP4 dosyasına dışa aktarma; orijinal klibi proje varlığı olarak tutma.
- Kodlamanın ilerlemesi, iptal ve hata mesajı; dışa aktarılan klibi doğrudan projeye ekleme.
- iOS ve Android'deki mevcut video oynatıcılarını aralık seçimi/trim akışına genişletme.

Tam video düzenleyicisi için kesme, bölme, birden fazla klibi zaman çizelgesinde sıralama, ses, altyazı ve geçişler ayrı aşamalar olmalı. İlk teslimi trim ile sınırlamak hem mevcut katman modeline uyar hem de platform kodlayıcısı/codec kapsamını yönetilebilir tutar.

### 3. Alan seçerek AI düzenleme ve fikir üretimi — P1

- Mevcut görsel katmanına serbest maske veya dikdörtgen alan seçip yalnız o bölgeyi düzenleme.
- Kullanıcının seçtiği referans görselleri ve bunların kişi/nesne/stil rollerini isteğe ekleme.
- İstem geliştirme önerisini kullanıcıya gösterme; düzenleme ve geri alma imkânı.
- Bir brief için ayrı konsept sayısı ve her konseptte üretilecek sonuç sayısı; sonuçları karşılaştırma ve projeye ekleme.
- Sadece sağlayıcının desteklediği süre/oran/kalite gibi video ayarlarını gösterme; sağlayıcı/model sınırlarını istekten önce açıklama.

Bu alan yeni model/provider yetenekleri ve maliyet yönetimi gerektiriyor. Maske dışındaki piksellerin korunması sağlayıcı tarafından garanti edilemiyorsa özellik bunu vaat etmemeli.

### 4. Medya Kütüphanesini düzenleme ve bulma — P1

- Öğeleri favorileme, klasör/etiket ekleme, çoklu seçim ve toplu dışa aktarma.
- Başlık, istem, etiket ve OCR metninde arama; OCR'ı yerel çalıştırıp görselleri hizmete göndermeme.
- Görsel/video/ses türü ve tarihe göre filtre, sıralama ve dosya ayrıntıları.

### 5. YouTube kapak iş akışı — P2

- Kanal/ bölüm bağlantısından bilgi çıkarma, kapağa dönük kısa brief önerme ve thumbnail şablonu seçme.
- YouTube benzeri kart üzerinde güvenli alan/ölçek önizlemesi.
- Harici YouTube API'si ve ek izin/anahtar gerektirdiğinden önce genel Media iyileştirmelerinden sonra ele alma.

## Kalan işlerin sırası

1. **P0 etkileşim tamamlama:** sürüklenen kırpma çerçevesi ve tutamaçlar; kilitli en-boy oranı; Enter/Esc ile uygula/iptal; telefon dokunmatik tutamaçları. Linux video önizlemesine zaman göstergesi/seek ve ortak In/Out etkileşimi ekle; Android'de codec destekli yeniden kodlama veya açıkça kareye en yakın remux seçeneği sun.
2. **P1 AI kapasitesi:** sağlayıcı/model yetenek kataloğu ve maliyet tahmini; destekleyen sağlayıcı için kaynak + maske ile bölgesel düzenleme, rol etiketli referanslar, önizlenebilir istem iyileştirme, konsept/result sayıları ve karşılaştırma galerisi. Sağlayıcı maskeyi desteklemiyorsa düzenleme seçeneğini kapalı tut.
3. **P1 video üretim parametreleri:** modele göre desteklenen süre, oran, kalite ve referans alanlarını tanımlayan yetenek şeması. Mevcut katalog bu parametreleri sağlamıyor; tüm modellerde ortak alan varmış gibi gösterilmemeli.
4. **P2 YouTube akışı:** şablon artık var ve Templates altında görünür. Sonraki adım bağlantı çözümleme/brief ve güvenli alanı gösteren YouTube benzeri önizleme. Bunları API anahtarı ve ayrı ağ erişimi gereksinimi açıklanarak ekle.

İlk turdaki video altyapısı platforma göre AVFoundation, FFmpeg ve Android MediaMuxer kullanıyor. Paketleyici/codec lisansları ve her platformdaki gerçek örnek videolarla süre/kare/metadata davranışı ayrıca doğrulanmalı; bu turda build veya çalışma zamanı doğrulaması yapılmadı.

## Kaynak kodu doğrulama noktaları

- macOS görsel katman denetimi ve videonun harici açılması: `macos/DotsHarness/Sources/DotsHarnessUI/MediaEditorPanels.swift`.
- Video katmanının poster karesi olarak çizilmesi ve mevcut PNG/JPEG/PDF dışa aktarma biçimleri: `macos/DotsHarness/Sources/DotsHarnessUI/MediaRendering.swift`.
- Video üretim isteğinin `model` + `prompt` alanlarıyla kurulması ve iş durumunun sorgulanması: `macos/DotsHarness/Sources/DotsHarnessCore/MediaGeneration.swift`.
- Medya kütüphanesi kaydının `id/kind/title/path/createdAt` alanları: `macos/DotsHarness/Sources/DotsHarnessCore/MediaLibrary.swift`.
- Kütüphane aramasının yalnızca görünen başlıkla eşleşmesi: `macos/DotsHarness/Sources/DotsHarnessUI/MediaLibraryView.swift`.
- Aynı temel video-katmanı ve medya-kütüphanesi modeli paylaşılan C# kodunda da kullanılıyor; Windows ve Linux ekranlarında kütüphane öğeleri harici dosya olarak açılıyor.
- iOS mobil tuval katmanları ve düzenleme araçları: `mobile/ios/Sources/MobileProductSections.swift` (`MobileMediaLayer`, `layerToolbar`, `canvasEditor`, `assetDetail`).
- Android mobil tuval/katman ve video oynatma: `mobile/android/app/src/main/java/com/dots/herness/mobile/MobileProductSections.kt` (`PhoneMediaLayer`, `MobileMediaCanvasEditor`, `MediaAssetList`).
