# Token ekonomisi ve araç keşfi

Uygulama, macOS, Windows, Linux, iOS ve Android ana sohbetlerinde ve explore/delegate alt görevlerinde aynı yaklaşımı kullanır. Bu değişiklikler HerNess'in sağlayıcıya gönderdiği istekleri etkiler.

## Sağlayıcıya giden araçlar

Tam yerel/MCP/plugin kataloğu cihazda kalır. Sağlayıcının `tools` alanında dört sabit kontrol tanımı bulunur: `discover_tools`, `invoke_tool`, `execution_plan`, `read_tool_output`. Masaüstü (macOS, Windows, Linux) bu dördün üzerine her istekte `read_file`, `grep_files`, `glob` ve `edit_file` şemalarını doğrudan ekler (`DeferredToolSession.DirectNames`: neredeyse her kodlama turu okur, arar ve düzenler; bir keşif turu tüm bağlamı gereksiz yeniden gönderirdi). Explore/delegate alt görevleri ve mobil ana sohbet yalnızca dört kontrolle çağrılır; mobilde araçlar her zaman keşfedilerek `invoke_tool` ile çağrılır, doğrudan araç yoktur. Bu küçük başlangıç arayüzü keşif yapabilmek için gereklidir; kullanılmayan gerçek araçların parametre şemaları gönderilmez.

`discover_tools` tam isimle tek şema, yetenek sorgusuyla en fazla beş şema döndürür. Boş sorgu yalnızca yirmi isimlik sayfa verir. Önceki gerçek keşif sonuçlarındaki şemalar sohbet geçmişinden geri alınır; yeni görevde eski effort planı geri alınmaz. Şema keşif sonucunda konuşmaya eklenir; sonraki isteklerin araç listesine yeniden eklenmez. Tekrarlanan keşif çağrısı tekrar sonuç üretebilir. Skill kataloğu sistem promptunda bulunmaz; `skill.list` arama/sayfalama, `skill.read` seçilen prosedürü getirir.

`invoke_tool` yalnızca o oturumda keşfedilmiş, halen mevcut ve şeması değişmemiş araçları açar. Mevcut kapsam, onay, plan modu, sandbox, dosya sürümü ve okuma yetkisi kontrolleri gerçek araç üzerinde uygulanır. Bir araç adını tahmin etmek keşif kontrolünü atlatmaz. Alt görevler yalnızca kendi sınırlı kataloğunu keşfedebilir; delegate dosya sahipliği ve explore salt okuma sınırı ayrıca korunur.

## Plan ve effort

İlk model çağrısı kullanıcının seçtiği effort ile yapılır. Model inceleme sonrasında `execution_plan` kaydeder. `routine=true`, bir ile beş somut adım, boş belirsizlik listesi ve uygulama modu birlikte sağlanırsa sonraki ana çağrılar `low` effort ister. Zaten `none`, `minimal` veya `low` seçilmişse yükseltilmez. Kullanıcının kalıcı seçimi değişmez. Yeni kullanıcı görevi, yeniden planlamada belirsizlik veya araç hatası seçilen efforta dönülmesini sağlar; yeni rutin plan tekrar düşürebilir.

Görevin rutin olduğuna model karar verir. Prompt migrasyon, güvenlik değişikliği, belirsiz teşhis ve geniş refactoring için bunu yasaklar; bu sınıflandırma deterministik bir güvenlik garantisi değildir. Yetki kontrolleri sınıflandırmadan bağımsızdır. Alt görevler kendi mevcut model/effort yönlendirmelerini kullanır; ana sohbetin rutin iş geçişi alt görevler için ayrı bir effort yöneticisi eklemez. Sağlayıcı/model desteklemiyorsa veya normalleştiriyorsa istenen effort aynen uygulanmayabilir. Mobilde effort alanı desteklenen OpenAI model ailesine gönderilir; mevcut Anthropic mobil yolu bu ayarı sunmaz.

## Çıktı ve geçmiş

Yerel dosya okuma sayfaları 8.192 sınırına küçültülür ve mevcut satır/okuma yetkisi sözleşmesi korunur. Büyük komut ve diğer araç sonuçlarının model bağlamına kısa baş/son ve belirleyici hata satırları girer; açık atlama işareti ve özgün çağrı kimliği bulunur. Masaüstü sınırı yaklaşık 1.024 tahmini tokendir. Mobil eşik 4.096 UTF-8 bayttır; dosya okumaları ve keşif/orijinal çıktı sayfaları yeniden kırpılmaz.

`read_tool_output` aynı çalışmadaki tam sonucu yeniden komut çalıştırmadan sayfalar: varsayılan 4.000, en çok 8.000 karakter. Özgün sonuç kullanıcıya görünen kalıcı transkriptte korunur; tekrar okuma deposu çalışma belleğindedir ve uygulama yeniden açılınca önceki çalışma için erişim iddia etmez.

Özet hedefi, kararları/yetkilendirmeyi, değişen dosyaları, son gerçek doğrulamayı, engelleri ve kalan işi tutar. Eski dosya gövdeleri, yazma içerikleri ve keşfedilen şemalar özet arşivinden çıkarılır. Çağrı zarfı arşivleme sırasında çözülür; `invoke_tool` içine sarılmış `read_file` dosya gövdesini özete sızdırmaz. Kompaktlaştırma eşikleri bu değişiklikte daha sık özetleme için indirilmez: cache kaybı ve özet çağrısı maliyeti ayrıca ölçülmelidir.

## Prompt ve doğrulama

Kanonik `shared/prompts/core.txt` için önceki sadeleştirme kaydı 15.481 karakterden 8.179 karaktere düşüşü (%47,2) gösterir. Sonraki değişikliklerle 2026-10-15 itibarıyla kaynak dosya 10.514 karakterdir; 4 karakter/token sezgiseliyle yaklaşık 2.628 token eder. Bu, sağlayıcı tokenizer ölçümü veya fatura tasarrufu değildir. Bölüm karakter sayımları aşağıdadır. İzole masaüstü katalog ölçümünde 32 kayıtlı araç yerine dört kontrol şeması gönderildi (masaüstü bunlara `read_file`, `grep_files` ve `edit_file` şemalarını doğrudan ekler); tahmini kontrol şeması maliyeti 6.139 → 339 token oldu. Bu katalog ölçümü kurulu ek araçları olan her ortam için aynı sayıyı garanti etmez. `tools/sync_prompts.py --check` masaüstü/mobil literallerin aynı olduğunu denetler.

### Güncel ölçüm (2026-10-15)

Tahminler 4 karakter/token sezgiseliyle, telemetri `context_economy_report.py --last 20` ile alındı (macOS, ana istekler).

| `core.txt` bölümü | Karakter |
|---|---:|
| Kimlik satırı | 74 |
| Instruction priority | 869 |
| Scope and intent | 1.601 |
| Tools and planning | 2.562 |
| Implementation and verification | 1.828 |
| Accuracy and language | 1.008 |
| Response economy and formatting | 2.018 |
| Non-negotiable | 554 |

Bölüm ölçümleri başlıklar, boş satırlar ve satır sonları dahil tüm dosyayı kapsar; toplamları 10.514 karakterdir. Toplam token tahmini, karakter sayısının dörde bölünmesiyle elde edilir ve yalnızca kaba bir sezgiseldir.

Duruma bağlı ekler: `response-style.txt` ~74, `plan-mode.txt` ~752 (yalnız plan modunda), `runtime_context`, `self_verification`, `project_context` (AGENTS.md, en fazla 32 KB), `project_memory`, `workspace_activity`, `plugin_guidance`. ChatGPT OAuth rotasında sabit `CodexInstructions` (~14,4 bin karakter, ~3,6 bin token) HerNess promptunun önüne eklenir; backend bu metni denetlediği için kısaltılamaz.

Son 20 ana istekte ölçülen ortalama: sistem promptu ~2,7 bin, araç şemaları ~360, toplam input ~16 bin token; ham cache oranı %84 (20 isteğin 18'inde cache kanıtı `inconclusive`). Tahmini bileşim: konuşma geçmişi %45, araç sonuçları %30, sistem promptu %18, araç çağrıları %4, araç şemaları %2. Output, input'un ~%0,7'si; üslup kısaltması toplam maliyeti az etkiler.

Tur başına araç adımı tavanı `AgentBridge.maxToolSteps = 128`. Tavana ulaşan tur bir kez araçsız özet ister, sonra `continuation` ile duraklar; kullanıcı devam ettirebilir. Yerel telemetride 37 tur benzeri istek kümesinde medyan 4, p90 34, en büyük 139 istek görüldü; yalnız bir küme tavana yaklaştı.

Güncel ve yeterli okuma tekrar kullanılabilir. Durum sorusu inceleme ve rapor ister; ayrıca düzeltme talebi yoksa dosya değiştirilmez. Seçilmiş skill prosedürleri kullanıcı yetkisi ve üst düzey kurallar içinde izlenir. Arama yılı ve diyagram yalnızca faydalıysa kullanılır.

`tools/context_economy_report.py --last 20` mevcut yerel telemetry üzerinden tahmini bağlam bileşenlerini, sağlayıcının bildirdiği fresh/cached/output/reasoning değerlerini, özet maliyetini ve gerçekten geçmişi değiştiren kompaktlaştırmaların önce/sonra cache gözlemlerini raporlar. `--input` başka bir kayıt dosyasını, `--baseline` önce kaydedilmiş karşılaştırılabilir raporu seçer. Eksik alanların kapsama sayısı ayrıca raporlanır. Seçilmiş ve istek için kullanılan effort ayrı alanlardır; eski kayıtlarda istek effortu yoktur.

`tools/eval_prompt.py --dry-run` senaryoları ve yedi araçlık eval arayüzünü (dört kontrol + masaüstünün doğrudan eklediği üç araç) denetler. `ANTHROPIC_API_KEY` ile canlı değerlendirme, gerçek dosya/komut çalıştırmayan sınırlı mock araç döngüsü kullanır. `--save` davranış sonuçları ve sağlayıcı usage kayıtlarını, `--baseline` davranış regresyonlarını karşılaştırır. Canlı anahtar olmadan model davranışı veya yeni fatura tasarrufu doğrulanmış sayılmaz.

Gerçek tasarruf için aynı görev kümesi, kaynak snapshotı, sağlayıcı ve modelle önce/sonra tekrarları karşılaştırılmalıdır. Toplam yeni işlenen input, cache yazımı, output/reasoning ve özet çağrılarını birlikte değerlendirin. Ham cache oranı tek başına tasarruf ya da nedensellik kanıtı değildir.

### Ölçüm ve değişiklikler (2026-10-27)

Kaynak: macOS `context-usage.json`, 1.488 ChatGPT ana isteği (2026-10-16 → 2026-10-26), sağlayıcının bildirdiği sayılar.

- Bellek bağlamı ilk turda ~38–43 bin karakter (~10 bin token) ekliyordu; `task_history` ~20 bin, `project_memory` ~10,5 bin karakter. Proje haritasındaki klasör dosya sayıları her yeni dosyada değiştiği için `project_memory` tamamen yeniden yakalanıyordu: sayılar kaldırıldı. Backlog değişince `task_history` tamamen yeniden yakalanıyordu: artık yalnız yeni girdiler ve yeni backlog gider, ayrı bir işaret backlog'un eskisinin yerine geçtiğini söyler. Bulguların prompt bütçesi 8.000 → 3.000 karakter (konsolidasyon hedefi 6.000 karakterde sabit kaldı, model çağrısı sıklaşmasın diye). macOS code graph açıklaması kısaltıldı.
- Şifreli reasoning tahmini: aynı turdaki ardışık isteklerde sağlayıcı girdisi önceki reasoning token başına 1,03 token artıyor, tahmin 1,74 sayıyordu. Şifreli içerik ağırlığı `/4` → `/7` karakter.
- Ara compaction eşiği simüle edildi (aynı istek dizisi, cache okuması %10 fiyat, özet 4 bin output): 128K'da tetikleyip 25K tutmak maliyeti %3,6–8,2, 64K'da %18–41 artırır. Eşik sağlayıcı penceresinin %90'ında kalır. 128K üstü isteklerde TTFT medyanı 12,8 sn (64–128K: 7,5 sn); bu tek başına compaction gerekçesi değildir.
- Düzenlenmiş dosyanın eski `read_file` sonucunu budamak okuma karakterlerinin %10'unu etkiler; adayların 8/14'ü sonradan zaten yeniden okunup mevcut kuralla budanıyor. Net kazanç küçük, yeniden okuma riski var: uygulanmadı.
