#!/usr/bin/env python3
"""Build the iOS and Android mobile catalogs from the macOS catalog.

The native desktop catalog is the existing translation source in this
repository.  Mobile-only copy is kept here so both native clients receive the
same key set and the same translated intro flow.  The script is deterministic
and safe to re-run after adding a locale or a mobile key.
"""

from __future__ import annotations

import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "mobile" / "localization" / "languages.json"
MAC_RESOURCES = ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources"
IOS_RESOURCES = ROOT / "mobile" / "ios" / "Resources"
ANDROID_RESOURCES = ROOT / "mobile" / "android" / "app" / "src" / "main" / "res"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from translation_catalog import MOBILE_TRANSLATIONS  # noqa: E402

ENTRY = re.compile(r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;\s*$')


def unescape(value: str) -> str:
    result: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
    while index < len(value):
        if value[index] != "\\" or index + 1 == len(value):
            result.append(value[index])
            index += 1
            continue
        index += 1
        result.append(escapes.get(value[index], value[index]))
        index += 1
    return "".join(result)


def read_strings(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("/*") or stripped.endswith("*/"):
            continue
        match = ENTRY.match(line)
        if not match:
            continue
        key, value = (unescape(item) for item in match.groups())
        if key in values:
            raise ValueError(f"{path}:{line_number}: duplicate key {key}")
        values[key] = value
    return values


def escape_strings(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def android_name(key: str) -> str:
    camel = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", key)
    name = re.sub(r"[^A-Za-z0-9_]", "_", camel).lower()
    return name if not name[:1].isdigit() else f"key_{name}"


def android_value(value: str) -> str:
    # Android's resource parser accepts XML entities and keeps literal percent
    # placeholders for stringResource formatting.
    # Keep apostrophes literal; AAPT interprets numeric apostrophe entities in
    # text nodes as an invalid unicode escape on some build-tools versions.
    return html.escape(value, quote=False).replace("'", "\\'").replace('"', "&quot;")


# Translations for keys introduced by the mobile clients. Existing shared
# keys are copied from the already translated macOS catalog.
CORE_TRANSLATIONS: dict[str, dict[str, str]] = {
    "mobile.splash.logo": {
        "en": "HerNess logo", "tr": "HerNess logosu", "de": "HerNess-Logo", "es": "Logotipo de HerNess", "fr": "Logo HerNess", "it": "Logo HerNess", "ja": "HerNessロゴ", "ko": "HerNess 로고", "nl": "HerNess-logo", "pt": "Logótipo HerNess", "ru": "Логотип HerNess", "zh-Hans": "HerNess 徽标", "ar": "شعار HerNess", "bn": "HerNess লোগো", "hi": "HerNess लोगो", "id": "Logo HerNess", "vi": "Logo HerNess", "ur": "HerNess لوگو", "mr": "HerNess लोगो", "te": "HerNess లోగో", "ta": "HerNess லோகோ", "fa": "نشان HerNess", "pl": "Logo HerNess", "uk": "Логотип HerNess", "th": "โลโก้ HerNess", "ms": "Logo HerNess", "ro": "Sigla HerNess", "el": "Λογότυπο HerNess", "cs": "Logo HerNess", "hu": "HerNess-logó"
    },
    "mobile.splash.buildLine": {
        "en": "BUILD  •  CONNECT  •  SHIP", "tr": "GELİŞTİR  •  BAĞLAN  •  YAYINLA", "de": "BAUEN  •  VERBINDEN  •  AUSLIEFERN", "es": "CREA  •  CONECTA  •  PUBLICA", "fr": "CRÉER  •  CONNECTER  •  LIVRER", "it": "CREA  •  CONNETTI  •  PUBBLICA", "ja": "BUILD  •  CONNECT  •  SHIP", "ko": "BUILD  •  CONNECT  •  SHIP", "nl": "BOUW  •  VERBIND  •  LEVER", "pt": "CRIAR  •  LIGAR  •  ENVIAR", "ru": "СОЗДАЙ  •  ПОДКЛЮЧИ  •  ЗАПУСТИ", "zh-Hans": "构建  •  连接  •  发布", "ar": "أنشئ  •  صِل  •  انشر", "bn": "তৈরি করুন  •  সংযোগ করুন  •  প্রকাশ করুন", "hi": "बनाएँ  •  जोड़ें  •  जारी करें", "id": "BANGUN  •  HUBUNGKAN  •  KIRIM", "vi": "XÂY DỰNG  •  KẾT NỐI  •  PHÁT HÀNH", "ur": "بنائیں  •  جوڑیں  •  جاری کریں", "mr": "तयार करा  •  जोडा  •  प्रकाशित करा", "te": "నిర్మించండి  •  కనెక్ట్ చేయండి  •  విడుదల చేయండి", "ta": "உருவாக்கு  •  இணை  •  வெளியிடு", "fa": "بساز  •  متصل شو  •  منتشر کن", "pl": "BUDUJ  •  ŁĄCZ  •  PUBLIKUJ", "uk": "СТВОРЮЙ  •  ПІДКЛЮЧАЙ  •  ПУБЛІКУЙ", "th": "สร้าง  •  เชื่อมต่อ  •  เผยแพร่", "ms": "BINA  •  SAMBUNG  •  HANTAR", "ro": "CONSTRUIEȘTE  •  CONECTEAZĂ  •  LIVREAZĂ", "el": "ΔΗΜΙΟΥΡΓΗΣΕ  •  ΣΥΝΔΕΣΕ  •  ΔΗΜΟΣΙΕΥΣΕ", "cs": "VYTVÁŘEJ  •  PŘIPOJ  •  NASAZUJ", "hu": "ÉPÍTS  •  KAPCSOLÓDJ  •  SZÁLLÍTS"
    },
    "intro.eyebrow.connect": {
        "en": "YOUR WORKSPACE, EVERYWHERE", "tr": "ÇALIŞMA ALANIN, HER YERDE", "de": "DEIN ARBEITSBEREICH, ÜBERALL", "es": "TU ESPACIO DE TRABAJO, EN TODAS PARTES", "fr": "TON ESPACE DE TRAVAIL, PARTOUT", "it": "IL TUO SPAZIO DI LAVORO, OVUNQUE", "ja": "どこでも、あなたのワークスペース", "ko": "어디서나 사용하는 나만의 작업 공간", "nl": "JOUW WERKRUIMTE, OVERAL", "pt": "O TEU ESPAÇO DE TRABALHO, EM TODO O LADO", "ru": "ТВОЁ РАБОЧЕЕ ПРОСТРАНСТВО — ВЕЗДЕ", "zh-Hans": "随时随地使用你的工作区", "ar": "مساحة عملك، في كل مكان", "bn": "আপনার ওয়ার্কস্পেস, সর্বত্র", "hi": "आपका कार्यक्षेत्र, हर जगह", "id": "RUANG KERJAMU, DI MANA SAJA", "vi": "KHÔNG GIAN LÀM VIỆC CỦA BẠN, MỌI NƠI", "ur": "آپ کی ورک اسپیس، ہر جگہ", "mr": "तुमचे कार्यक्षेत्र, सर्वत्र", "te": "మీ వర్క్‌స్పేస్, ప్రతిచోటా", "ta": "உங்கள் பணியிடம், எங்கும்", "fa": "فضای کاری تو، همه‌جا", "pl": "TWOJA PRZESTRZEŃ ROBOCZA, WSZĘDZIE", "uk": "ТВОЄ РОБОЧЕ ПРОСТОРІНЬ — СКРІЗЬ", "th": "เวิร์กสเปซของคุณ ทุกที่", "ms": "RUANG KERJA ANDA, DI MANA-MANA", "ro": "SPAȚIUL TĂU DE LUCRU, PRETUTINDENI", "el": "Ο ΧΩΡΟΣ ΕΡΓΑΣΙΑΣ ΣΟΥ, ΠΑΝΤΟΥ", "cs": "TVŮJ PRACOVNÍ PROSTOR, VŠUDE", "hu": "A MUNKATERÜLETED, MINDENHOL"
    },
    "intro.title.connect": {
        "en": "Bring HerNess with you.", "tr": "HerNess hep yanında.", "de": "HerNess ist immer dabei.", "es": "Lleva HerNess contigo.", "fr": "Emporte HerNess avec toi.", "it": "Porta HerNess con te.", "ja": "HerNessをどこへでも。", "ko": "HerNess를 어디서나.", "nl": "Neem HerNess met je mee.", "pt": "Leva o HerNess contigo.", "ru": "HerNess всегда с тобой.", "zh-Hans": "随身携带 HerNess。", "ar": "اصطحب HerNess معك.", "bn": "HerNess-কে সঙ্গে রাখুন।", "hi": "HerNess को अपने साथ रखें।", "id": "Bawa HerNess bersamamu.", "vi": "Mang HerNess theo bạn.", "ur": "HerNess کو اپنے ساتھ رکھیں۔", "mr": "HerNess सोबत ठेवा.", "te": "HerNessను మీతో తీసుకెళ్లండి.", "ta": "HerNess-ஐ உங்களுடன் எடுத்துச் செல்லுங்கள்.", "fa": "HerNess را همراه خود داشته باش.", "pl": "Zabierz HerNess ze sobą.", "uk": "Бери HerNess із собою.", "th": "พก HerNess ไปกับคุณ", "ms": "Bawa HerNess bersama anda.", "ro": "Ia HerNess cu tine.", "el": "Πάρε το HerNess μαζί σου.", "cs": "Vezmi si HerNess s sebou.", "hu": "Vidd magaddal a HerNess-t."
    },
    "intro.description.connect": {
        "en": "Set up a private workspace on this phone and keep your project within reach.", "tr": "Bu telefonda özel bir çalışma alanı oluştur ve projeni her zaman elinin altında tut.", "de": "Richte auf diesem Telefon einen privaten Arbeitsbereich ein und behalte dein Projekt griffbereit.", "es": "Configura un espacio de trabajo privado en este teléfono y ten tu proyecto siempre a mano.", "fr": "Configure un espace de travail privé sur ce téléphone et garde ton projet à portée de main.", "it": "Configura uno spazio di lavoro privato su questo telefono e tieni il progetto a portata di mano.", "ja": "このスマホにプライベートなワークスペースを設定し、プロジェクトをいつでも手元に置けます。", "ko": "이 휴대폰에 비공개 작업 공간을 설정하고 프로젝트를 가까이 두세요.", "nl": "Stel op deze telefoon een privéwerkruimte in en houd je project binnen handbereik.", "pt": "Configura um espaço de trabalho privado neste telemóvel e mantém o teu projeto à mão.", "ru": "Настрой личное рабочее пространство на этом телефоне и держи проект под рукой.", "zh-Hans": "在这部手机上设置私密工作区，让项目随时触手可及。", "ar": "أنشئ مساحة عمل خاصة على هذا الهاتف وأبقِ مشروعك في متناولك.", "bn": "এই ফোনে একটি ব্যক্তিগত ওয়ার্কস্পেস সেট আপ করুন এবং প্রকল্পটি হাতের কাছে রাখুন।", "hi": "इस फ़ोन पर निजी कार्यक्षेत्र बनाएँ और अपना प्रोजेक्ट पास रखें।", "id": "Siapkan ruang kerja privat di ponsel ini dan simpan proyekmu agar mudah diakses.", "vi": "Thiết lập không gian làm việc riêng trên điện thoại này và giữ dự án trong tầm tay.", "ur": "اس فون پر نجی ورک اسپیس بنائیں اور اپنے پروجیکٹ کو ہمیشہ قریب رکھیں۔", "mr": "या फोनवर खासगी कार्यक्षेत्र तयार करा आणि तुमचा प्रकल्प हाताशी ठेवा.", "te": "ఈ ఫోన్‌లో ప్రైవేట్ వర్క్‌స్పేస్ ఏర్పాటు చేసి మీ ప్రాజెక్ట్‌ను అందుబాటులో ఉంచండి.", "ta": "இந்தத் தொலைபேசியில் தனிப்பட்ட பணியிடத்தை அமைத்து, உங்கள் திட்டத்தை அருகில் வைத்திருங்கள்.", "fa": "یک فضای کاری خصوصی روی این تلفن بساز و پروژه‌ات را همیشه در دسترس نگه دار.", "pl": "Skonfiguruj prywatną przestrzeń pracy na tym telefonie i miej projekt zawsze pod ręką.", "uk": "Налаштуй приватний робочий простір на цьому телефоні й тримай проєкт під рукою.", "th": "ตั้งค่าเวิร์กสเปซส่วนตัวบนโทรศัพท์เครื่องนี้และให้โปรเจกต์อยู่ใกล้มือ", "ms": "Sediakan ruang kerja peribadi pada telefon ini dan pastikan projek anda sentiasa dekat.", "ro": "Configurează un spațiu de lucru privat pe acest telefon și păstrează proiectul la îndemână.", "el": "Ρύθμισε έναν ιδιωτικό χώρο εργασίας σε αυτό το τηλέφωνο και κράτησε το έργο σου πρόχειρο.", "cs": "Nastav si v tomto telefonu soukromý pracovní prostor a měj projekt vždy po ruce.", "hu": "Állíts be privát munkaterületet ezen a telefonon, hogy a projekted mindig kéznél legyen."
    },
    "intro.eyebrow.agent": {
        "en": "THINK WITH YOUR AGENT", "tr": "AJANINLA BİRLİKTE DÜŞÜN", "de": "DENKE MIT DEINEM AGENTEN", "es": "PIENSA CON TU AGENTE", "fr": "RÉFLÉCHIS AVEC TON AGENT", "it": "PENSA CON IL TUO AGENTE", "ja": "エージェントと考える", "ko": "에이전트와 함께 생각하세요", "nl": "DENK SAMEN MET JE AGENT", "pt": "PENSA COM O TEU AGENTE", "ru": "ДУМАЙ ВМЕСТЕ С АГЕНТОМ", "zh-Hans": "与你的智能体一起思考", "ar": "فكّر مع وكيلك", "bn": "আপনার এজেন্টের সঙ্গে ভাবুন", "hi": "अपने एजेंट के साथ सोचें", "id": "BERPIKIR BERSAMA AGEN", "vi": "SUY NGHĨ CÙNG AGENT", "ur": "اپنے ایجنٹ کے ساتھ سوچیں", "mr": "तुमच्या एजंटसोबत विचार करा", "te": "మీ ఏజెంట్‌తో కలిసి ఆలోచించండి", "ta": "உங்கள் ஏஜெண்டுடன் சிந்தியுங்கள்", "fa": "با عامل خود فکر کن", "pl": "MYŚL ZE SWOIM AGENTEM", "uk": "ДУМАЙ РАЗОМ ІЗ АГЕНТОМ", "th": "คิดไปพร้อมกับเอเจนต์ของคุณ", "ms": "FIKIR BERSAMA EJEN ANDA", "ro": "GÂNDEȘTE CU AGENTUL TĂU", "el": "ΣΚΕΨΟΥ ΜΑΖΙ ΜΕ ΤΟΝ AGENT ΣΟΥ", "cs": "PŘEMÝŠLEJ SE SVÝM AGENTEM", "hu": "GONDOLKODJ AZ AGENSEDDEL"
    },
    "intro.title.agent": {
        "en": "Turn ideas into code.", "tr": "Fikirleri koda dönüştür.", "de": "Mach aus Ideen Code.", "es": "Convierte ideas en código.", "fr": "Transforme tes idées en code.", "it": "Trasforma le idee in codice.", "ja": "アイデアをコードに。", "ko": "아이디어를 코드로 바꾸세요.", "nl": "Maak van ideeën code.", "pt": "Transforma ideias em código.", "ru": "Превращай идеи в код.", "zh-Hans": "把想法变成代码。", "ar": "حوّل الأفكار إلى برمجيات.", "bn": "ভাবনাকে কোডে রূপ দিন।", "hi": "विचारों को कोड में बदलें।", "id": "Ubah ide menjadi kode.", "vi": "Biến ý tưởng thành mã.", "ur": "خیالات کو کوڈ میں بدلیں۔", "mr": "कल्पनांना कोडमध्ये बदला.", "te": "ఆలోచనలను కోడ్‌గా మార్చండి.", "ta": "யோசனைகளை குறியீடாக மாற்றுங்கள்.", "fa": "ایده‌ها را به کد تبدیل کن.", "pl": "Zamieniaj pomysły w kod.", "uk": "Перетворюй ідеї на код.", "th": "เปลี่ยนไอเดียให้เป็นโค้ด", "ms": "Tukarkan idea menjadi kod.", "ro": "Transformă ideile în cod.", "el": "Κάνε τις ιδέες σου κώδικα.", "cs": "Proměň nápady v kód.", "hu": "Váltsd az ötleteidet kóddá."
    },
    "intro.description.agent": {
        "en": "Run the agent, tools, approvals, and event history locally without a desktop.", "tr": "Ajanı, araçları, onayları ve olay geçmişini masaüstü olmadan yerel olarak çalıştır.", "de": "Führe Agent, Tools, Freigaben und Ereignisverlauf lokal ohne Desktop aus.", "es": "Ejecuta el agente, las herramientas, las aprobaciones y el historial de eventos localmente sin ordenador.", "fr": "Exécute l’agent, les outils, les approbations et l’historique des événements localement, sans ordinateur.", "it": "Esegui localmente agente, strumenti, approvazioni e cronologia degli eventi senza desktop.", "ja": "デスクトップなしで、エージェントやツール、承認、イベント履歴をローカルで実行できます。", "ko": "데스크톱 없이 에이전트, 도구, 승인 및 이벤트 기록을 로컬에서 실행하세요.", "nl": "Draai de agent, tools, goedkeuringen en gebeurtenisgeschiedenis lokaal zonder desktop.", "pt": "Executa o agente, as ferramentas, as aprovações e o histórico de eventos localmente, sem computador.", "ru": "Запускай агента, инструменты, подтверждения и историю событий локально без компьютера.", "zh-Hans": "无需桌面电脑，也能在本地运行智能体、工具、审批和事件历史。", "ar": "شغّل الوكيل والأدوات والموافقات وسجل الأحداث محليًا من دون كمبيوتر مكتبي.", "bn": "ডেস্কটপ ছাড়াই এজেন্ট, টুল, অনুমোদন ও ইভেন্ট ইতিহাস স্থানীয়ভাবে চালান।", "hi": "डेस्कटॉप के बिना एजेंट, टूल, अनुमोदन और इवेंट इतिहास स्थानीय रूप से चलाएँ।", "id": "Jalankan agen, alat, persetujuan, dan riwayat acara secara lokal tanpa desktop.", "vi": "Chạy agent, công cụ, phê duyệt và lịch sử sự kiện cục bộ mà không cần máy tính.", "ur": "ڈیسک ٹاپ کے بغیر ایجنٹ، ٹولز، منظوریوں اور ایونٹ ہسٹری کو مقامی طور پر چلائیں۔", "mr": "डेस्कटॉपशिवाय एजंट, साधने, मंजुरी आणि इव्हेंट इतिहास स्थानिक पातळीवर चालवा.", "te": "డెస్క్‌టాప్ లేకుండానే ఏజెంట్, టూల్స్, అనుమతులు, ఈవెంట్ చరిత్రను స్థానికంగా నడపండి.", "ta": "டெஸ்க்டாப் இல்லாமல் ஏஜென்ட், கருவிகள், ஒப்புதல்கள் மற்றும் நிகழ்வு வரலாற்றை உள்ளூரில் இயக்குங்கள்.", "fa": "عامل، ابزارها، تأییدها و تاریخچه رویدادها را بدون دسکتاپ به‌صورت محلی اجرا کن.", "pl": "Uruchamiaj agenta, narzędzia, zatwierdzenia i historię zdarzeń lokalnie, bez komputera.", "uk": "Запускай агента, інструменти, підтвердження та історію подій локально, без комп’ютера.", "th": "เรียกใช้เอเจนต์ เครื่องมือ การอนุมัติ และประวัติเหตุการณ์ในเครื่องโดยไม่ต้องใช้เดสก์ท็อป", "ms": "Jalankan ejen, alat, kelulusan dan sejarah acara secara setempat tanpa desktop.", "ro": "Rulează local agentul, instrumentele, aprobările și istoricul evenimentelor fără un desktop.", "el": "Εκτέλεσε το agent, τα εργαλεία, τις εγκρίσεις και το ιστορικό συμβάντων τοπικά, χωρίς υπολογιστή.", "cs": "Spouštěj agenta, nástroje, schválení a historii událostí lokálně bez počítače.", "hu": "Futtasd helyben az ügynököt, az eszközöket, a jóváhagyásokat és az eseményelőzményeket asztali gép nélkül."
    },
    "intro.eyebrow.ship": {
        "en": "SHIP WITH CONFIDENCE", "tr": "GÜVENLE YAYINLA", "de": "SICHER AUSLIEFERN", "es": "PUBLICA CON CONFIANZA", "fr": "LIVRE EN TOUTE CONFIANCE", "it": "PUBBLICA CON FIDUCIA", "ja": "自信を持って届ける", "ko": "자신 있게 배포하세요", "nl": "LEVER MET VERTROUWEN", "pt": "ENVIA COM CONFIANÇA", "ru": "ВЫПУСКАЙ УВЕРЕННО", "zh-Hans": "自信地发布", "ar": "انشر بثقة", "bn": "আত্মবিশ্বাসের সঙ্গে প্রকাশ করুন", "hi": "विश्वास के साथ जारी करें", "id": "RILIS DENGAN PERCAYA DIRI", "vi": "PHÁT HÀNH TỰ TIN", "ur": "اعتماد کے ساتھ جاری کریں", "mr": "आत्मविश्वासाने प्रकाशित करा", "te": "నమ్మకంతో విడుదల చేయండి", "ta": "நம்பிக்கையுடன் வெளியிடுங்கள்", "fa": "با اطمینان منتشر کن", "pl": "PUBLIKUJ PEWNIE", "uk": "ПУБЛІКУЙ УПЕВНЕНО", "th": "เผยแพร่อย่างมั่นใจ", "ms": "HANTAR DENGAN YAKIN", "ro": "LIVREAZĂ CU ÎNCREDERE", "el": "ΔΗΜΟΣΙΕΥΣΕ ΜΕ ΣΙΓΟΥΡΙΑ", "cs": "NASAZUJ S JISTOTOU", "hu": "SZÁLLÍTS MAGABIZTOSAN"
    },
    "intro.title.ship": {
        "en": "Move forward safely.", "tr": "Güvenle ilerle.", "de": "Geh sicher weiter.", "es": "Avanza con seguridad.", "fr": "Avance en toute sécurité.", "it": "Vai avanti in sicurezza.", "ja": "安全に前へ進もう。", "ko": "안전하게 앞으로 나아가세요.", "nl": "Ga veilig vooruit.", "pt": "Avança em segurança.", "ru": "Двигайся вперёд безопасно.", "zh-Hans": "安全地继续前进。", "ar": "تقدّم بأمان.", "bn": "নিরাপদে এগিয়ে যান।", "hi": "सुरक्षित रूप से आगे बढ़ें।", "id": "Melangkah dengan aman.", "vi": "Tiến bước an toàn.", "ur": "محفوظ طریقے سے آگے بڑھیں۔", "mr": "सुरक्षितपणे पुढे जा.", "te": "సురక్షితంగా ముందుకు సాగండి.", "ta": "பாதுகாப்பாக முன்னேறுங்கள்.", "fa": "با امنیت به جلو برو.", "pl": "Idź naprzód bezpiecznie.", "uk": "Рухайся вперед безпечно.", "th": "ก้าวต่อไปอย่างปลอดภัย", "ms": "Teruskan dengan selamat.", "ro": "Mergi mai departe în siguranță.", "el": "Προχώρα με ασφάλεια.", "cs": "Postupuj bezpečně.", "hu": "Haladj biztonságosan."
    },
    "intro.description.ship": {
        "en": "Review local changes, create a branch, and ship when you are ready.", "tr": "Yerel değişiklikleri incele, bir dal oluştur ve hazır olduğunda yayınla.", "de": "Prüfe lokale Änderungen, erstelle einen Branch und liefere aus, sobald du bereit bist.", "es": "Revisa los cambios locales, crea una rama y publica cuando estés listo.", "fr": "Vérifie les changements locaux, crée une branche et livre quand tu es prêt.", "it": "Esamina le modifiche locali, crea un branch e pubblica quando sei pronto.", "ja": "ローカルの変更を確認し、ブランチを作成して、準備ができたら公開できます。", "ko": "로컬 변경 사항을 검토하고 브랜치를 만든 뒤 준비가 되면 배포하세요.", "nl": "Bekijk lokale wijzigingen, maak een branch en lever uit wanneer je klaar bent.", "pt": "Revê as alterações locais, cria uma branch e publica quando estiveres pronto.", "ru": "Проверяй локальные изменения, создавай ветку и выпускай, когда будешь готов.", "zh-Hans": "检查本地更改，创建分支，准备好后再发布。", "ar": "راجع التغييرات المحلية وأنشئ فرعًا وانشر عندما تصبح جاهزًا.", "bn": "স্থানীয় পরিবর্তন পর্যালোচনা করুন, একটি ব্রাঞ্চ তৈরি করুন এবং প্রস্তুত হলে প্রকাশ করুন।", "hi": "स्थानीय बदलावों की समीक्षा करें, ब्रांच बनाएँ और तैयार होने पर जारी करें।", "id": "Tinjau perubahan lokal, buat cabang, lalu rilis saat siap.", "vi": "Xem lại thay đổi cục bộ, tạo nhánh và phát hành khi sẵn sàng.", "ur": "مقامی تبدیلیوں کا جائزہ لیں، برانچ بنائیں اور تیار ہونے پر جاری کریں۔", "mr": "स्थानिक बदल तपासा, शाखा तयार करा आणि तयार झाल्यावर प्रकाशित करा.", "te": "లోకల్ మార్పులను పరిశీలించి, బ్రాంచ్ సృష్టించి, సిద్ధమైనప్పుడు విడుదల చేయండి.", "ta": "உள்ளூர் மாற்றங்களை மதிப்பாய்வு செய்து, கிளையை உருவாக்கி, தயாரானதும் வெளியிடுங்கள்.", "fa": "تغییرات محلی را بررسی کن، یک شاخه بساز و وقتی آماده بودی منتشر کن.", "pl": "Przejrzyj lokalne zmiany, utwórz gałąź i opublikuj, gdy będziesz gotowy.", "uk": "Переглянь локальні зміни, створи гілку й публікуй, коли будеш готовий.", "th": "ตรวจสอบการเปลี่ยนแปลงในเครื่อง สร้างบรานช์ และเผยแพร่เมื่อพร้อม", "ms": "Semak perubahan setempat, cipta cawangan dan hantar apabila anda bersedia.", "ro": "Verifică modificările locale, creează o ramură și livrează când ești gata.", "el": "Έλεγξε τις τοπικές αλλαγές, δημιούργησε κλάδο και δημοσίευσε όταν είσαι έτοιμος.", "cs": "Zkontroluj místní změny, vytvoř větev a nasaď je, až budeš připraven.", "hu": "Nézd át a helyi módosításokat, hozz létre egy ágat, majd publikálj, amikor készen állsz."
    },
    "intro.skip": {
        "en": "Skip", "tr": "Atla", "de": "Überspringen", "es": "Omitir", "fr": "Passer", "it": "Salta", "ja": "スキップ", "ko": "건너뛰기", "nl": "Overslaan", "pt": "Ignorar", "ru": "Пропустить", "zh-Hans": "跳过", "ar": "تخطَّ", "bn": "এড়িয়ে যান", "hi": "छोड़ें", "id": "Lewati", "vi": "Bỏ qua", "ur": "چھوڑیں", "mr": "वगळा", "te": "దాటవేయి", "ta": "தவிர்", "fa": "رد کردن", "pl": "Pomiń", "uk": "Пропустити", "th": "ข้าม", "ms": "Langkau", "ro": "Omite", "el": "Παράλειψη", "cs": "Přeskočit", "hu": "Kihagyás"
    },
    "intro.back": {
        "en": "Back", "tr": "Geri", "de": "Zurück", "es": "Atrás", "fr": "Retour", "it": "Indietro", "ja": "戻る", "ko": "뒤로", "nl": "Terug", "pt": "Voltar", "ru": "Назад", "zh-Hans": "返回", "ar": "رجوع", "bn": "পিছনে", "hi": "वापस", "id": "Kembali", "vi": "Quay lại", "ur": "واپس", "mr": "मागे", "te": "వెనక్కి", "ta": "பின்", "fa": "بازگشت", "pl": "Wstecz", "uk": "Назад", "th": "ย้อนกลับ", "ms": "Kembali", "ro": "Înapoi", "el": "Πίσω", "cs": "Zpět", "hu": "Vissza"
    },
    "intro.continue": {
        "en": "Continue", "tr": "Devam", "de": "Weiter", "es": "Continuar", "fr": "Continuer", "it": "Continua", "ja": "続ける", "ko": "계속", "nl": "Doorgaan", "pt": "Continuar", "ru": "Продолжить", "zh-Hans": "继续", "ar": "متابعة", "bn": "চালিয়ে যান", "hi": "जारी रखें", "id": "Lanjutkan", "vi": "Tiếp tục", "ur": "جاری رکھیں", "mr": "पुढे चला", "te": "కొనసాగించండి", "ta": "தொடர்க", "fa": "ادامه", "pl": "Dalej", "uk": "Продовжити", "th": "ดำเนินการต่อ", "ms": "Teruskan", "ro": "Continuă", "el": "Συνέχεια", "cs": "Pokračovat", "hu": "Folytatás"
    },
    "intro.start": {
        "en": "Start using HerNess", "tr": "HerNess'i kullanmaya başla", "de": "HerNess verwenden", "es": "Empezar a usar HerNess", "fr": "Commencer à utiliser HerNess", "it": "Inizia a usare HerNess", "ja": "HerNessを始める", "ko": "HerNess 사용 시작", "nl": "HerNess gebruiken", "pt": "Começar a usar o HerNess", "ru": "Начать использовать HerNess", "zh-Hans": "开始使用 HerNess", "ar": "ابدأ استخدام HerNess", "bn": "HerNess ব্যবহার শুরু করুন", "hi": "HerNess का उपयोग शुरू करें", "id": "Mulai menggunakan HerNess", "vi": "Bắt đầu dùng HerNess", "ur": "HerNess استعمال شروع کریں", "mr": "HerNess वापरणे सुरू करा", "te": "HerNess ఉపయోగించడం ప్రారంభించండి", "ta": "HerNess பயன்பாட்டைத் தொடங்குங்கள்", "fa": "استفاده از HerNess را شروع کن", "pl": "Zacznij używać HerNess", "uk": "Почати користуватися HerNess", "th": "เริ่มใช้ HerNess", "ms": "Mula menggunakan HerNess", "ro": "Începe să folosești HerNess", "el": "Ξεκίνα να χρησιμοποιείς το HerNess", "cs": "Začít používat HerNess", "hu": "HerNess használatának megkezdése"
    },
    "intro.language": {
        "en": "Language", "tr": "Dil", "de": "Sprache", "es": "Idioma", "fr": "Langue", "it": "Lingua", "ja": "言語", "ko": "언어", "nl": "Taal", "pt": "Idioma", "ru": "Язык", "zh-Hans": "语言", "ar": "اللغة", "bn": "ভাষা", "hi": "भाषा", "id": "Bahasa", "vi": "Ngôn ngữ", "ur": "زبان", "mr": "भाषा", "te": "భాష", "ta": "மொழி", "fa": "زبان", "pl": "Język", "uk": "Мова", "th": "ภาษา", "ms": "Bahasa", "ro": "Limbă", "el": "Γλώσσα", "cs": "Jazyk", "hu": "Nyelv"
    },
    "intro.languageAccessibility": {
        "en": "Choose language", "tr": "Dil seç", "de": "Sprache auswählen", "es": "Elegir idioma", "fr": "Choisir la langue", "it": "Scegli lingua", "ja": "言語を選択", "ko": "언어 선택", "nl": "Taal kiezen", "pt": "Escolher idioma", "ru": "Выбрать язык", "zh-Hans": "选择语言", "ar": "اختيار اللغة", "bn": "ভাষা বেছে নিন", "hi": "भाषा चुनें", "id": "Pilih bahasa", "vi": "Chọn ngôn ngữ", "ur": "زبان منتخب کریں", "mr": "भाषा निवडा", "te": "భాషను ఎంచుకోండి", "ta": "மொழியைத் தேர்ந்தெடுக்கவும்", "fa": "انتخاب زبان", "pl": "Wybierz język", "uk": "Вибрати мову", "th": "เลือกภาษา", "ms": "Pilih bahasa", "ro": "Alege limba", "el": "Επιλογή γλώσσας", "cs": "Vybrat jazyk", "hu": "Nyelv kiválasztása"
    },
    "intro.languageSystem": {
        "en": "System", "tr": "Sistem", "de": "Systém", "es": "Sistema", "fr": "Système", "it": "Sistema", "ja": "システム", "ko": "시스템", "nl": "Systeem", "pt": "Sistema", "ru": "Системный", "zh-Hans": "系统", "ar": "النظام", "bn": "সিস্টেম", "hi": "सिस्टम", "id": "Sistem", "vi": "Hệ thống", "ur": "سسٹم", "mr": "सिस्टम", "te": "సిస్టమ్", "ta": "சிஸ்டம்", "fa": "سیستم", "pl": "System", "uk": "Системна", "th": "ระบบ", "ms": "Sistem", "ro": "Sistem", "el": "Σύστημα", "cs": "Systém", "hu": "Rendszer"
    },
    "intro.page": {
        "en": "Onboarding page %1$d of %2$d", "tr": "Tanıtım sayfası: %1$d / %2$d", "de": "Einführungsseite %1$d von %2$d", "es": "Página de introducción %1$d de %2$d", "fr": "Page d’introduction %1$d sur %2$d", "it": "Pagina introduttiva %1$d di %2$d", "ja": "オンボーディング %1$d / %2$d", "ko": "온보딩 페이지 %1$d/%2$d", "nl": "Introductiepagina %1$d van %2$d", "pt": "Página de introdução %1$d de %2$d", "ru": "Страница знакомства %1$d из %2$d", "zh-Hans": "引导页 %1$d（共 %2$d 页）", "ar": "صفحة التعريف %1$d من %2$d", "bn": "পরিচিতি পৃষ্ঠা %1$d / %2$d", "hi": "ऑनबोर्डिंग पृष्ठ %1$d / %2$d", "id": "Halaman pengenalan %1$d dari %2$d", "vi": "Trang giới thiệu %1$d trên %2$d", "ur": "تعارفی صفحہ %1$d از %2$d", "mr": "परिचय पृष्ठ %1$d / %2$d", "te": "ఆన్‌బోర్డింగ్ పేజీ %1$d / %2$d", "ta": "அறிமுகப் பக்கம் %1$d / %2$d", "fa": "صفحه معرفی %1$d از %2$d", "pl": "Strona wprowadzenia %1$d z %2$d", "uk": "Сторінка вступу %1$d із %2$d", "th": "หน้าการเริ่มต้น %1$d จาก %2$d", "ms": "Halaman pengenalan %1$d daripada %2$d", "ro": "Pagina de prezentare %1$d din %2$d", "el": "Σελίδα αρχικής ρύθμισης %1$d από %2$d", "cs": "Úvodní stránka %1$d z %2$d", "hu": "Bevezető oldal: %1$d/%2$d"
    },
    "mobile.nav.code": { "en": "Code", "tr": "Kod", "de": "Code", "es": "Código", "fr": "Code", "it": "Codice", "ja": "コード", "ko": "코드", "nl": "Code", "pt": "Código", "ru": "Код", "zh-Hans": "代码", "ar": "الكود", "bn": "কোড", "hi": "कोड", "id": "Kode", "vi": "Mã", "ur": "کوڈ", "mr": "कोड", "te": "కోడ్", "ta": "குறியீடு", "fa": "کد", "pl": "Kod", "uk": "Код", "th": "โค้ด", "ms": "Kod", "ro": "Cod", "el": "Κώδικας", "cs": "Kód", "hu": "Kód" },
    "mobile.nav.agent": { "en": "Agent", "tr": "Ajan", "de": "Agent", "es": "Agente", "fr": "Agent", "it": "Agente", "ja": "エージェント", "ko": "에이전트", "nl": "Agent", "pt": "Agente", "ru": "Агент", "zh-Hans": "智能体", "ar": "الوكيل", "bn": "এজেন্ট", "hi": "एजेंट", "id": "Agen", "vi": "Agent", "ur": "ایجنٹ", "mr": "एजंट", "te": "ఏజెంట్", "ta": "ஏஜென்ட்", "fa": "عامل", "pl": "Agent", "uk": "Агент", "th": "เอเจนต์", "ms": "Ejen", "ro": "Agent", "el": "Agent", "cs": "Agent", "hu": "Ügynök" },
    "mobile.nav.terminal": { "en": "Terminal", "tr": "Terminal", "de": "Terminal", "es": "Terminal", "fr": "Terminal", "it": "Terminale", "ja": "ターミナル", "ko": "터미널", "nl": "Terminal", "pt": "Terminal", "ru": "Терминал", "zh-Hans": "终端", "ar": "الطرفية", "bn": "টার্মিনাল", "hi": "टर्मिनल", "id": "Terminal", "vi": "Terminal", "ur": "ٹرمینل", "mr": "टर्मिनल", "te": "టెర్మినల్", "ta": "டெர்மினல்", "fa": "ترمینال", "pl": "Terminal", "uk": "Термінал", "th": "เทอร์มินัล", "ms": "Terminal", "ro": "Terminal", "el": "Τερματικό", "cs": "Terminál", "hu": "Terminál" },
    "mobile.nav.preview": { "en": "Preview", "tr": "Önizleme", "de": "Vorschau", "es": "Vista previa", "fr": "Aperçu", "it": "Anteprima", "ja": "プレビュー", "ko": "미리보기", "nl": "Voorbeeld", "pt": "Pré-visualização", "ru": "Предпросмотр", "zh-Hans": "预览", "ar": "معاينة", "bn": "প্রিভিউ", "hi": "पूर्वावलोकन", "id": "Pratinjau", "vi": "Xem trước", "ur": "پیش منظر", "mr": "पूर्वदृश्य", "te": "ప్రివ్యూ", "ta": "முன்னோட்டம்", "fa": "پیش‌نمایش", "pl": "Podgląd", "uk": "Попередній перегляд", "th": "ตัวอย่าง", "ms": "Pratonton", "ro": "Previzualizare", "el": "Προεπισκόπηση", "cs": "Náhled", "hu": "Előnézet" },
    "mobile.nav.settings": { "en": "Settings", "tr": "Ayarlar", "de": "Einstellungen", "es": "Ajustes", "fr": "Réglages", "it": "Impostazioni", "ja": "設定", "ko": "설정", "nl": "Instellingen", "pt": "Definições", "ru": "Настройки", "zh-Hans": "设置", "ar": "الإعدادات", "bn": "সেটিংস", "hi": "सेटिंग्स", "id": "Pengaturan", "vi": "Cài đặt", "ur": "ترتیبات", "mr": "सेटिंग्ज", "te": "సెట్టింగ్‌లు", "ta": "அமைப்புகள்", "fa": "تنظیمات", "pl": "Ustawienia", "uk": "Налаштування", "th": "การตั้งค่า", "ms": "Tetapan", "ro": "Setări", "el": "Ρυθμίσεις", "cs": "Nastavení", "hu": "Beállítások" },
    "mobile.workspace.local": { "en": "Local workspace", "tr": "Yerel çalışma alanı", "de": "Lokaler Arbeitsbereich", "es": "Espacio de trabajo local", "fr": "Espace de travail local", "it": "Spazio di lavoro locale", "ja": "ローカルワークスペース", "ko": "로컬 작업 공간", "nl": "Lokale werkruimte", "pt": "Espaço de trabalho local", "ru": "Локальное рабочее пространство", "zh-Hans": "本地工作区", "ar": "مساحة العمل المحلية", "bn": "স্থানীয় ওয়ার্কস্পেস", "hi": "स्थानीय कार्यक्षेत्र", "id": "Ruang kerja lokal", "vi": "Không gian làm việc cục bộ", "ur": "مقامی ورک اسپیس", "mr": "स्थानिक कार्यक्षेत्र", "te": "లోకల్ వర్క్‌స్పేస్", "ta": "உள்ளூர் பணியிடம்", "fa": "فضای کاری محلی", "pl": "Lokalna przestrzeń pracy", "uk": "Локальний робочий простір", "th": "เวิร์กสเปซในเครื่อง", "ms": "Ruang kerja setempat", "ro": "Spațiu de lucru local", "el": "Τοπικός χώρος εργασίας", "cs": "Místní pracovní prostor", "hu": "Helyi munkaterület" },
    "mobile.workspace.selectFile": { "en": "Select a file", "tr": "Bir dosya seç", "de": "Datei auswählen", "es": "Selecciona un archivo", "fr": "Sélectionner un fichier", "it": "Seleziona un file", "ja": "ファイルを選択", "ko": "파일 선택", "nl": "Selecteer een bestand", "pt": "Selecionar um ficheiro", "ru": "Выберите файл", "zh-Hans": "选择文件", "ar": "اختر ملفًا", "bn": "একটি ফাইল বেছে নিন", "hi": "फ़ाइल चुनें", "id": "Pilih file", "vi": "Chọn tệp", "ur": "فائل منتخب کریں", "mr": "फाइल निवडा", "te": "ఫైల్‌ను ఎంచుకోండి", "ta": "கோப்பைத் தேர்ந்தெடுக்கவும்", "fa": "یک فایل انتخاب کن", "pl": "Wybierz plik", "uk": "Виберіть файл", "th": "เลือกไฟล์", "ms": "Pilih fail", "ro": "Selectează un fișier", "el": "Επίλεξε αρχείο", "cs": "Vyber soubor", "hu": "Válassz fájlt" },
    "mobile.workspace.save": { "en": "Save", "tr": "Kaydet", "de": "Speichern", "es": "Guardar", "fr": "Enregistrer", "it": "Salva", "ja": "保存", "ko": "저장", "nl": "Opslaan", "pt": "Guardar", "ru": "Сохранить", "zh-Hans": "保存", "ar": "حفظ", "bn": "সংরক্ষণ", "hi": "सहेजें", "id": "Simpan", "vi": "Lưu", "ur": "محفوظ کریں", "mr": "जतन करा", "te": "సేవ్ చేయండి", "ta": "சேமி", "fa": "ذخیره", "pl": "Zapisz", "uk": "Зберегти", "th": "บันทึก", "ms": "Simpan", "ro": "Salvează", "el": "Αποθήκευση", "cs": "Uložit", "hu": "Mentés" },
    "mobile.workspace.saved": { "en": "Saved", "tr": "Kaydedildi", "de": "Gespeichert", "es": "Guardado", "fr": "Enregistré", "it": "Salvato", "ja": "保存しました", "ko": "저장됨", "nl": "Opgeslagen", "pt": "Guardado", "ru": "Сохранено", "zh-Hans": "已保存", "ar": "تم الحفظ", "bn": "সংরক্ষিত", "hi": "सहेजा गया", "id": "Tersimpan", "vi": "Đã lưu", "ur": "محفوظ", "mr": "जतन केले", "te": "సేవ్ చేయబడింది", "ta": "சேமிக்கப்பட்டது", "fa": "ذخیره شد", "pl": "Zapisano", "uk": "Збережено", "th": "บันทึกแล้ว", "ms": "Disimpan", "ro": "Salvat", "el": "Αποθηκεύτηκε", "cs": "Uloženo", "hu": "Mentve" },
    "mobile.workspace.conflict": { "en": "Conflict", "tr": "Çakışma", "de": "Konflikt", "es": "Conflicto", "fr": "Conflit", "it": "Conflitto", "ja": "競合", "ko": "충돌", "nl": "Conflict", "pt": "Conflito", "ru": "Конфликт", "zh-Hans": "冲突", "ar": "تعارض", "bn": "দ্বন্দ্ব", "hi": "टकराव", "id": "Konflik", "vi": "Xung đột", "ur": "تضاد", "mr": "विरोध", "te": "విరోధం", "ta": "முரண்பாடு", "fa": "تعارض", "pl": "Konflikt", "uk": "Конфлікт", "th": "ข้อขัดแย้ง", "ms": "Konflik", "ro": "Conflict", "el": "Σύγκρουση", "cs": "Konflikt", "hu": "Ütközés" },
    "mobile.workspace.keepLocalEdit": { "en": "Keep local edit", "tr": "Yerel düzenlemeyi koru", "de": "Lokale Änderung behalten", "es": "Conservar edición local", "fr": "Garder la modification locale", "it": "Mantieni modifica locale", "ja": "ローカル編集を保持", "ko": "로컬 편집 유지", "nl": "Lokale bewerking behouden", "pt": "Manter edição local", "ru": "Сохранить локальное изменение", "zh-Hans": "保留本地编辑", "ar": "الاحتفاظ بالتعديل المحلي", "bn": "স্থানীয় সম্পাদনা রাখুন", "hi": "स्थानीय संपादन रखें", "id": "Pertahankan edit lokal", "vi": "Giữ chỉnh sửa cục bộ", "ur": "مقامی ترمیم برقرار رکھیں", "mr": "स्थानिक संपादन ठेवा", "te": "లోకల్ ఎడిట్‌ను ఉంచండి", "ta": "உள்ளூர் திருத்தத்தை வைத்திருங்கள்", "fa": "ویرایش محلی را نگه دار", "pl": "Zachowaj lokalną edycję", "uk": "Зберегти локальне редагування", "th": "เก็บการแก้ไขในเครื่อง", "ms": "Kekalkan suntingan setempat", "ro": "Păstrează editarea locală", "el": "Διατήρηση τοπικής επεξεργασίας", "cs": "Ponechat místní úpravu", "hu": "Helyi szerkesztés megtartása" },
    "mobile.preview.title": { "en": "Web preview", "tr": "Web önizleme", "de": "Webvorschau", "es": "Vista previa web", "fr": "Aperçu web", "it": "Anteprima web", "ja": "Webプレビュー", "ko": "웹 미리보기", "nl": "Webvoorbeeld", "pt": "Pré-visualização web", "ru": "Веб-предпросмотр", "zh-Hans": "网页预览", "ar": "معاينة الويب", "bn": "ওয়েব প্রিভিউ", "hi": "वेब पूर्वावलोकन", "id": "Pratinjau web", "vi": "Xem trước web", "ur": "ویب پیش منظر", "mr": "वेब पूर्वदृश्य", "te": "వెబ్ ప్రివ్యూ", "ta": "வலை முன்னோட்டம்", "fa": "پیش‌نمایش وب", "pl": "Podgląd WWW", "uk": "Вебперегляд", "th": "ตัวอย่างเว็บ", "ms": "Pratonton web", "ro": "Previzualizare web", "el": "Προεπισκόπηση ιστού", "cs": "Webový náhled", "hu": "Webes előnézet" },
    "mobile.preview.url": { "en": "Web preview URL", "tr": "Web önizleme URL'si", "de": "URL der Webvorschau", "es": "URL de vista previa web", "fr": "URL de l’aperçu web", "it": "URL anteprima web", "ja": "WebプレビューURL", "ko": "웹 미리보기 URL", "nl": "URL van webvoorbeeld", "pt": "URL da pré-visualização web", "ru": "URL веб-предпросмотра", "zh-Hans": "网页预览 URL", "ar": "رابط معاينة الويب", "bn": "ওয়েব প্রিভিউ URL", "hi": "वेब पूर्वावलोकन URL", "id": "URL pratinjau web", "vi": "URL xem trước web", "ur": "ویب پیش منظر URL", "mr": "वेब पूर्वदृश्य URL", "te": "వెబ్ ప్రివ్యూ URL", "ta": "வலை முன்னோட்ட URL", "fa": "نشانی پیش‌نمایش وب", "pl": "URL podglądu WWW", "uk": "URL вебперегляду", "th": "URL ตัวอย่างเว็บ", "ms": "URL pratonton web", "ro": "URL previzualizare web", "el": "URL προεπισκόπησης ιστού", "cs": "URL webového náhledu", "hu": "Webes előnézeti URL" },
    "mobile.preview.none": { "en": "No preview", "tr": "Önizleme yok", "de": "Keine Vorschau", "es": "Sin vista previa", "fr": "Aucun aperçu", "it": "Nessuna anteprima", "ja": "プレビューなし", "ko": "미리보기 없음", "nl": "Geen voorbeeld", "pt": "Sem pré-visualização", "ru": "Нет предпросмотра", "zh-Hans": "没有预览", "ar": "لا توجد معاينة", "bn": "কোনও প্রিভিউ নেই", "hi": "कोई पूर्वावलोकन नहीं", "id": "Tidak ada pratinjau", "vi": "Không có bản xem trước", "ur": "کوئی پیش منظر نہیں", "mr": "पूर्वदृश्य नाही", "te": "ప్రివ్యూ లేదు", "ta": "முன்னோட்டம் இல்லை", "fa": "پیش‌نمایشی نیست", "pl": "Brak podglądu", "uk": "Немає перегляду", "th": "ไม่มีตัวอย่าง", "ms": "Tiada pratonton", "ro": "Nicio previzualizare", "el": "Δεν υπάρχει προεπισκόπηση", "cs": "Žádný náhled", "hu": "Nincs előnézet" },
    "mobile.preview.description": { "en": "Open a preview URL here after a desktop or Pages deploy.", "tr": "Masaüstü veya Pages dağıtımından sonra önizleme URL'sini burada aç.", "de": "Öffne hier nach einem Desktop- oder Pages-Deployment eine Vorschau-URL.", "es": "Abre aquí una URL de vista previa después de un despliegue de escritorio o Pages.", "fr": "Ouvre ici une URL d’aperçu après un déploiement Desktop ou Pages.", "it": "Apri qui un URL di anteprima dopo un deploy desktop o Pages.", "ja": "デスクトップまたはPagesへのデプロイ後、ここでプレビューURLを開けます。", "ko": "데스크톱 또는 Pages 배포 후 미리보기 URL을 여기에서 여세요.", "nl": "Open hier een voorbeeld-URL na een desktop- of Pages-deployment.", "pt": "Abre aqui um URL de pré-visualização após uma publicação no desktop ou Pages.", "ru": "Откройте здесь URL предпросмотра после развертывания с компьютера или Pages.", "zh-Hans": "在桌面或 Pages 部署后，可在此打开预览 URL。", "ar": "افتح رابط المعاينة هنا بعد النشر من سطح المكتب أو Pages.", "bn": "ডেস্কটপ বা Pages ডিপ্লয়ের পরে এখানে একটি প্রিভিউ URL খুলুন।", "hi": "डेस्कटॉप या Pages पर परिनियोजन के बाद यहाँ पूर्वावलोकन URL खोलें।", "id": "Buka URL pratinjau di sini setelah deploy desktop atau Pages.", "vi": "Mở URL xem trước tại đây sau khi triển khai từ máy tính hoặc Pages.", "ur": "ڈیسک ٹاپ یا Pages تعیناتی کے بعد یہاں پیش منظر URL کھولیں۔", "mr": "डेस्कटॉप किंवा Pages डिप्लॉय केल्यानंतर येथे पूर्वदृश्य URL उघडा.", "te": "డెస్క్‌టాప్ లేదా Pages డిప్లాయ్ చేసిన తర్వాత ప్రివ్యూ URLను ఇక్కడ తెరవండి.", "ta": "டெஸ்க்டாப் அல்லது Pages வெளியீட்டுக்குப் பிறகு முன்னோட்ட URL-ஐ இங்கே திறக்கவும்.", "fa": "پس از استقرار دسکتاپ یا Pages، نشانی پیش‌نمایش را اینجا باز کن.", "pl": "Otwórz tutaj URL podglądu po wdrożeniu z pulpitu lub Pages.", "uk": "Відкрийте тут URL перегляду після розгортання з комп’ютера або Pages.", "th": "เปิด URL ตัวอย่างที่นี่หลังจากดีพลอยจากเดสก์ท็อปหรือ Pages", "ms": "Buka URL pratonton di sini selepas penggunaan desktop atau Pages.", "ro": "Deschide aici un URL de previzualizare după o implementare desktop sau Pages.", "el": "Άνοιξε εδώ ένα URL προεπισκόπησης μετά από ανάπτυξη Desktop ή Pages.", "cs": "Po nasazení z počítače nebo Pages zde otevři URL náhledu.", "hu": "Asztali vagy Pages-telepítés után itt nyisd meg az előnézeti URL-t."
    },
    "app.ok": { "en": "OK", "tr": "Tamam", "de": "OK", "es": "Aceptar", "fr": "OK", "it": "OK", "ja": "OK", "ko": "확인", "nl": "OK", "pt": "OK", "ru": "ОК", "zh-Hans": "确定", "ar": "موافق", "bn": "ঠিক আছে", "hi": "ठीक है", "id": "Oke", "vi": "OK", "ur": "ٹھیک ہے", "mr": "ठीक आहे", "te": "సరే", "ta": "சரி", "fa": "تأیید", "pl": "OK", "uk": "Гаразд", "th": "ตกลง", "ms": "OK", "ro": "OK", "el": "OK", "cs": "OK", "hu": "OK" },
    "mobile.connection.title": { "en": "Connection", "tr": "Bağlantı", "de": "Verbindung", "es": "Conexión", "fr": "Connexion", "it": "Connessione", "ja": "接続", "ko": "연결", "nl": "Verbinding", "pt": "Ligação", "ru": "Подключение", "zh-Hans": "连接", "ar": "الاتصال", "bn": "সংযোগ", "hi": "कनेक्शन", "id": "Koneksi", "vi": "Kết nối", "ur": "کنکشن", "mr": "कनेक्शन", "te": "కనెక్షన్", "ta": "இணைப்பு", "fa": "اتصال", "pl": "Połączenie", "uk": "Підключення", "th": "การเชื่อมต่อ", "ms": "Sambungan", "ro": "Conexiune", "el": "Σύνδεση", "cs": "Připojení", "hu": "Kapcsolat" }
    ,
    "mobile.exit.confirm": { "en": "Exit", "tr": "Çık", "de": "Beenden", "es": "Salir", "fr": "Quitter", "it": "Esci", "ja": "終了", "ko": "종료", "nl": "Afsluiten", "pt": "Sair", "ru": "Выйти", "zh-Hans": "退出", "ar": "خروج", "bn": "বেরিয়ে যান", "hi": "बाहर निकलें", "id": "Keluar", "vi": "Thoát", "ur": "خروج", "mr": "बाहेर पडा", "te": "నిష్క్రమించండి", "ta": "வெளியேறு", "fa": "خروج", "pl": "Wyjdź", "uk": "Вийти", "th": "ออก", "ms": "Keluar", "ro": "Ieșire", "el": "Έξοδος", "cs": "Ukončit", "hu": "Kilépés" },
    "mobile.exit.remember": { "en": "Remember my choice", "tr": "Seçimimi hatırla", "de": "Auswahl merken", "es": "Recordar mi elección", "fr": "Mémoriser mon choix", "it": "Ricorda la mia scelta", "ja": "選択を記憶", "ko": "선택 기억", "nl": "Mijn keuze onthouden", "pt": "Memorizar a minha escolha", "ru": "Запомнить выбор", "zh-Hans": "记住我的选择", "ar": "تذكّر اختياري", "bn": "আমার পছন্দ মনে রাখুন", "hi": "मेरी पसंद याद रखें", "id": "Ingat pilihan saya", "vi": "Ghi nhớ lựa chọn", "ur": "میرا انتخاب یاد رکھیں", "mr": "माझी निवड लक्षात ठेवा", "te": "నా ఎంపికను గుర్తుంచుకోండి", "ta": "என் தேர்வை நினைவில் கொள்க", "fa": "انتخابم را به خاطر بسپار", "pl": "Zapamiętaj mój wybór", "uk": "Запам’ятати мій вибір", "th": "จำตัวเลือกของฉัน", "ms": "Ingat pilihan saya", "ro": "Ține minte alegerea mea", "el": "Απομνημόνευση επιλογής", "cs": "Zapamatovat volbu", "hu": "Választásom megjegyzése" },
}

# Keep the Android resource set focused.  The desktop catalog contains a few
# legacy strings with desktop-only escape syntax that AAPT correctly rejects;
# those strings are not part of the mobile UI and must not be shipped there.
MOBILE_KEYS = set(CORE_TRANSLATIONS)
MOBILE_KEYS.update({
    "common.cancel", "common.connect", "common.delete", "common.done", "common.download", "common.refresh", "common.remove", "common.save", "common.start", "common.stop",
    "settings.title", "settings.language", "settings.confirmBeforeExit", "settings.pluginsTitle", "settings.pluginsHint", "settings.reload", "settings.tab.providers",
    "settings.sandbox", "settings.sandboxOff", "settings.sandboxOn", "settings.sandboxName", "settings.sandboxEnter", "settings.sandboxMerge", "settings.sandboxDiscard", "settings.sandboxOrigin", "settings.sandboxBranch",
    "conversation.files", "conversation.terminal", "conversation.closeTerminal", "conversation.openTerminal", "conversation.queuedMessage", "conversation.you", "conversation.assistant", "conversation.tool",
    "permission.approvalTitle", "permission.allowOnce", "permission.reject", "tool.error",
    "agent.continue", "agent.messageQueued", "agent.steeringQueued", "agent.runningTool", "agent.chooseWorkspace", "agent.chooseModel",
    "conversation.steer", "plan.title", "plan.waitingApproval",
    "loop.minutesLabel", "loop.instructionLabel", "tasks.runNow", "tasks.field.name", "tasks.field.prompt", "tasks.cancel", "tasks.save",
    "modelPicker.model", "modelPicker.selectModel", "modelPicker.noModel",
    "slash.mcp", "slash.loop", "settings.tab.plugins",
    "mobile.exit.title", "mobile.exit.message", "mobile.exit.action", "mobile.exit.confirm", "mobile.exit.remember", "mobile.exit.rememberAndExit", "mobile.exit.cancel",
    "mobile.exit.settingsSection", "mobile.exit.askBeforeExit", "mobile.exit.settingsHint", "mobile.exit.actionLabel",
    "mobile.event.fileOperation", "mobile.event.runSummary", "mobile.event.connectionChanged", "mobile.event.live",
    "mobile.event.added", "mobile.event.changed", "mobile.event.removed", "mobile.event.workspaceFile", "mobile.event.fileDetail",
    "mobile.event.runDetail", "mobile.event.runFinished", "mobile.event.previousConnection", "mobile.event.currentConnection",
    "mobile.event.connectionVerified", "mobile.event.connectionFailed", "mobile.event.connectionPreserved", "mobile.event.connectionDefault",
    "legal.title", "legal.gateHeading", "legal.gateIntro", "legal.termsTab", "legal.privacyTab", "legal.acceptRequired",
    "legal.accept", "legal.acceptHint", "legal.openWeb", "legal.consentHeading", "legal.consentPrefs",
    "legal.consent.aiTransfer", "legal.consent.github", "legal.consent.voice", "legal.consent.marketing",
    "legal.updated", "legal.loadError", "legal.retry",
    "mobile.workspace.savedLocal", "mobile.workspace.saveFailed", "mobile.workspace.codeEditor", "mobile.workspace.conflictMessage", "mobile.workspace.sandboxLabel",
    "mobile.artifact.ipaHint", "mobile.artifact.openOutput", "mobile.artifact.share", "mobile.artifact.fullOutput",
    "mobile.agent.phone", "mobile.agent.newConversation", "mobile.agent.plan", "mobile.agent.approvalRequired", "mobile.agent.allowTool", "mobile.agent.clarification", "mobile.agent.answer", "mobile.agent.eventHistory", "mobile.agent.ask", "mobile.agent.queue", "mobile.agent.send", "mobile.agent.model", "mobile.agent.close", "mobile.agent.user", "mobile.agent.error",
    "mobile.terminal.title", "mobile.terminal.help", "mobile.terminal.run", "mobile.preview.pagesHint",
    "mobile.loops.title", "mobile.loops.every", "mobile.loops.lastRun", "mobile.loops.runNow", "mobile.loops.add", "mobile.loops.backgroundHint",
    "mobile.mcp.title", "mobile.mcp.bearerToken", "mobile.mcp.add", "mobile.mcp.reconnect", "mobile.mcp.httpsHint",
    "mobile.plugins.emptyHint", "mobile.plugins.reload",
    "mobile.settings.phoneAccounts", "mobile.settings.providerKey", "mobile.settings.saveProviderKey", "mobile.settings.providerKeyHint",
    "mobile.settings.gptAccount", "mobile.settings.signInChatGPT", "mobile.settings.waitingChatGPT", "mobile.settings.connected", "mobile.settings.signOut", "mobile.settings.gptHint",
    "mobile.settings.githubAccount", "mobile.settings.signInGitHub", "mobile.settings.waitingGitHub", "mobile.settings.githubHint",
    "mobile.settings.offlineRepository", "mobile.settings.loadRepositories", "mobile.settings.chooseRepository", "mobile.settings.ownerRepository", "mobile.settings.branch", "mobile.settings.clone", "mobile.settings.selectedBranchHint",
    "mobile.settings.githubChanges", "mobile.settings.owner", "mobile.settings.repository", "mobile.settings.baseBranch", "mobile.settings.newBranch", "mobile.settings.commitPR", "mobile.settings.noLocalChanges", "mobile.settings.repositoryInputError", "mobile.settings.requestFailed",
    "mobile.settings.remoteRunner", "mobile.settings.desktopPaired", "mobile.settings.noDesktop", "mobile.settings.remoteRunnerHint", "mobile.settings.accessModeHint", "mobile.settings.buildHint", "mobile.settings.preview", "mobile.settings.pagesURL", "mobile.settings.snapshotExclusions",
})

# English source values for the mobile-only keys. Every non-English value is
# supplied by MOBILE_TRANSLATIONS in translation_catalog.py before generation.
MOBILE_DEFAULTS = {
    "mobile.exit.title": "Exit HerNess?",
    "mobile.exit.message": "Are you sure you want to exit the app?",
    "mobile.exit.action": "Exit",
    "mobile.exit.cancel": "Cancel",
    "mobile.exit.rememberAndExit": "Exit and remember",
    "mobile.exit.settingsSection": "Application",
    "mobile.exit.askBeforeExit": "Ask before exiting",
    "mobile.exit.settingsHint": "When enabled, HerNess asks for confirmation before closing.",
    "mobile.exit.actionLabel": "Exit HerNess",
    "mobile.event.fileOperation": "File operation",
    "mobile.event.runSummary": "Run summary",
    "mobile.event.connectionChanged": "Connection changed",
    "mobile.event.live": "Live event",
    "mobile.event.added": "added",
    "mobile.event.changed": "changed",
    "mobile.event.removed": "removed",
    "mobile.event.workspaceFile": "workspace file",
    "mobile.event.fileDetail": "File %@: %@",
    "mobile.event.runDetail": "+%@ added, %@ changed, %@ removed. %@",
    "mobile.event.runFinished": "Run finished.",
    "mobile.event.previousConnection": "Previous connection",
    "mobile.event.currentConnection": "Current connection",
    "mobile.event.connectionVerified": "%@ was disconnected. Its local connection data was removed; conversations and user data were preserved, and remote data was not touched.",
    "mobile.event.connectionFailed": "%@ was disconnected, but its local connection cleanup could not be fully verified; it was preserved.",
    "mobile.event.connectionPreserved": "%@ was kept while %@ was selected. No local connection data was removed; conversations and user data were preserved.",
    "mobile.event.connectionDefault": "%@ → %@. Conversations and user data were preserved; remote data was not touched.",
    "mobile.workspace.savedLocal": "Saved to the local workspace.",
    "mobile.workspace.saveFailed": "Save failed.",
    "mobile.workspace.codeEditor": "Code editor",
    "mobile.workspace.conflictMessage": "The desktop file changed first. Your edit was kept in the offline mirror; review the diff before applying it.",
    "mobile.workspace.sandboxLabel": "Sandbox '%@' — isolated",
    "mobile.artifact.ipaHint": "IPA installation requires TestFlight or Ad Hoc signing.",
    "mobile.artifact.openOutput": "Open full output",
    "mobile.artifact.share": "Share / save downloaded artifact",
    "mobile.artifact.fullOutput": "Full output",
    "mobile.agent.phone": "Phone agent",
    "mobile.agent.newConversation": "New conversation",
    "mobile.agent.plan": "Plan mode (read-only)",
    "mobile.agent.approvalRequired": "Approval required",
    "mobile.agent.allowTool": "Allow %@ to run on this phone?",
    "mobile.agent.clarification": "Agent clarification required",
    "mobile.agent.answer": "Answer",
    "mobile.agent.eventHistory": "Event history",
    "mobile.agent.ask": "Ask the agent running on this phone",
    "mobile.agent.queue": "Queue",
    "mobile.agent.send": "Send",
    "mobile.agent.model": "Model",
    "mobile.agent.close": "Close",
    "mobile.agent.user": "You",
    "mobile.agent.error": "Error",
    "mobile.terminal.title": "Mobile runtime",
    "mobile.terminal.help": "Help",
    "mobile.terminal.run": "Run",
    "mobile.preview.pagesHint": "Open a Pages or Quick Tunnel URL here.",
    "mobile.loops.title": "Loops",
    "mobile.loops.every": "every %d min",
    "mobile.loops.lastRun": " · last run %@",
    "mobile.loops.runNow": "Run now",
    "mobile.loops.add": "Add loop",
    "mobile.loops.backgroundHint": "Loops run on time while the app is open. In the background WorkManager will not run them more often than every 15 minutes.",
    "mobile.mcp.title": "MCP servers",
    "mobile.mcp.bearerToken": "Bearer token (optional)",
    "mobile.mcp.add": "Add server",
    "mobile.mcp.reconnect": "Reconnect all",
    "mobile.mcp.httpsHint": "Only HTTPS MCP servers are reachable: the app cannot spawn a stdio server process.",
    "mobile.plugins.emptyHint": "Drop a plugin under the app workspace with plugin.json and plugin.js. Cloning a repository brings its plugins with it.",
    "mobile.plugins.reload": "Reload plugins",
    "mobile.settings.phoneAccounts": "Your phone accounts",
    "mobile.settings.providerKey": "Provider API key",
    "mobile.settings.saveProviderKey": "Save provider key on this device",
    "mobile.settings.providerKeyHint": "The provider key stays in secure device storage and is sent directly to the selected provider. It is not embedded in the app.",
    "mobile.settings.gptAccount": "GPT account",
    "mobile.settings.signInChatGPT": "Sign in with ChatGPT",
    "mobile.settings.waitingChatGPT": "Waiting for ChatGPT…",
    "mobile.settings.connected": "Connected",
    "mobile.settings.signOut": "Sign out on this device",
    "mobile.settings.gptHint": "GPT uses the existing OAuth + PKCE Responses flow. Access and refresh tokens stay in secure device storage.",
    "mobile.settings.githubAccount": "GitHub",
    "mobile.settings.signInGitHub": "Sign in with GitHub",
    "mobile.settings.waitingGitHub": "Waiting for GitHub…",
    "mobile.settings.githubHint": "GitHub uses authorization code + PKCE. No client secret is stored in the mobile app.",
    "mobile.settings.offlineRepository": "Offline repository",
    "mobile.settings.loadRepositories": "Load repositories",
    "mobile.settings.chooseRepository": "Choose repository",
    "mobile.settings.ownerRepository": "owner/repository",
    "mobile.settings.branch": "Branch",
    "mobile.settings.clone": "Clone to this phone",
    "mobile.settings.selectedBranchHint": "The selected branch is copied into the private app sandbox and becomes the local workspace.",
    "mobile.settings.githubChanges": "GitHub changes",
    "mobile.settings.owner": "Owner",
    "mobile.settings.repository": "Repository",
    "mobile.settings.baseBranch": "Base branch",
    "mobile.settings.newBranch": "New branch",
    "mobile.settings.commitPR": "Commit mirror and open PR",
    "mobile.settings.noLocalChanges": "No local mirror changes to commit.",
    "mobile.settings.repositoryInputError": "Enter the repository as owner/repository or a GitHub clone URL.",
    "mobile.settings.requestFailed": "GitHub request failed.",
    "mobile.settings.remoteRunner": "Remote runner",
    "mobile.settings.desktopPaired": "Desktop paired — heavy commands run on desktop",
    "mobile.settings.noDesktop": "No desktop paired",
    "mobile.settings.remoteRunnerHint": "Heavy commands are forwarded to the paired desktop when available; otherwise the phone runtime remains available.",
    "mobile.settings.accessModeHint": "The desktop may ask for approval when full access is not enabled.",
    "mobile.settings.buildHint": "Builds and release signing remain on desktop or GitHub Actions.",
    "mobile.settings.preview": "Preview",
    "mobile.settings.pagesURL": "Pages URL",
    "mobile.settings.snapshotExclusions": "Snapshot exclusions",
}


def localized_values(locale: str) -> dict[str, str]:
    if locale != "en":
        missing = sorted(set(MOBILE_DEFAULTS) - set(MOBILE_TRANSLATIONS))
        if missing:
            raise ValueError(f"missing mobile translations: {', '.join(missing)}")
        incomplete = sorted(key for key in MOBILE_DEFAULTS if locale not in MOBILE_TRANSLATIONS[key])
        if incomplete:
            raise ValueError(f"incomplete mobile translations for {locale}: {', '.join(incomplete)}")
    # Some pre-existing macOS locale files predate the newest desktop keys.
    # Unioning with English keeps the mobile catalogs structurally complete;
    # the mobile checker still catches accidental key drift on either platform.
    source_values = read_strings(MAC_RESOURCES / "en.lproj" / "Localizable.strings")
    if locale != "en":
        source = MAC_RESOURCES / f"{locale}.lproj" / "Localizable.strings"
        source_values.update(read_strings(source))
    values = {key: source_values.get(key, MOBILE_DEFAULTS.get(key, key)) for key in MOBILE_KEYS}
    for key, translations in CORE_TRANSLATIONS.items():
        value = translations.get(locale) or translations.get("en")
        if value:
            values[key] = value
    for key, translations in MOBILE_TRANSLATIONS.items():
        value = translations.get(locale) or translations.get("en")
        if value:
            values[key] = value
    return values


def write_ios(locale: str, values: dict[str, str]) -> None:
    directory = IOS_RESOURCES / f"{locale}.lproj"
    directory.mkdir(parents=True, exist_ok=True)
    lines = ["// Generated from the shared macOS catalog and mobile additions.", ""]
    lines.extend(f'"{escape_strings(key)}" = "{escape_strings(values[key])}";' for key in sorted(values))
    (directory / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_android(locale: str, values: dict[str, str]) -> None:
    directory_name = "values" if locale == "en" else f"values-{locale}" if locale != "zh-Hans" else "values-b+zh+Hans"
    directory = ANDROID_RESOURCES / directory_name
    directory.mkdir(parents=True, exist_ok=True)
    lines = ["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<resources>"]
    seen: set[str] = set()
    for key in sorted(values):
        name = android_name(key)
        if name in seen:
            raise ValueError(f"Android resource name collision for {key}: {name}")
        seen.add(name)
        formatted = "" if re.search(r"%\d+\$", values[key]) else ' formatted="false"' if "%" in values[key] else ""
        lines.append(f'    <string name="{name}"{formatted}>{android_value(values[key])}</string>')
    lines.append("</resources>")
    (directory / "strings.xml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    locales = [item["code"] for item in manifest["languages"]]
    if locales != [item["code"] for item in manifest["languages"]]:
        raise ValueError("invalid locale manifest")
    for locale in ["en", *locales]:
        values = localized_values(locale)
        write_ios(locale, values)
        write_android(locale, values)
    print(f"generated mobile catalogs for {len(locales)} languages plus English base")


if __name__ == "__main__":
    main()
