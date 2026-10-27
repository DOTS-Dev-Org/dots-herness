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
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "mobile" / "localization" / "languages.json"
MAC_RESOURCES = ROOT / "macos" / "DotsHarness" / "Sources" / "DotsHarnessCore" / "Resources"
IOS_RESOURCES = ROOT / "mobile" / "ios" / "Resources"
ANDROID_RESOURCES = ROOT / "mobile" / "android" / "app" / "src" / "main" / "res"
SHARED_RESOURCES = ROOT / "shared"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from translation_catalog import (  # noqa: E402
    MOBILE_NOTICE_KEYS, MOBILE_TRANSLATIONS, NO_PROJECT_ENGLISH, NO_PROJECT_KEYS, NOTICE_ENGLISH,
)

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


def android_format(value: str) -> str:
    """Translate Foundation printf placeholders into Java Formatter syntax."""
    next_index = 1

    def convert(match: re.Match[str]) -> str:
        nonlocal next_index
        explicit_index, conversion = match.groups()
        if conversion == "%":
            return "%%"
        index = int(explicit_index) if explicit_index else next_index
        next_index = max(next_index, index + 1)
        conversion = {"@": "s", "lld": "d", "ld": "d"}.get(conversion, conversion)
        return f"%{index}${conversion}"

    return re.sub(r"%(?:(\d+)\$)?(lld|ld|@|d|s|%)", convert, value)


# Translations for keys introduced by the mobile clients. Existing shared
# keys are copied from the already translated macOS catalog.
CORE_TRANSLATIONS: dict[str, dict[str, str]] = {
    "mobile.splash.logo": {
        "en": "HerNess logo", "tr": "HerNess logosu", "de": "HerNess-Logo", "es": "Logotipo de HerNess", "fr": "Logo HerNess", "it": "Logo HerNess", "ja": "HerNessロゴ", "ko": "HerNess 로고", "nl": "HerNess-logo", "pt": "Logótipo HerNess", "ru": "Логотип HerNess", "zh-Hans": "HerNess 徽标", "ar": "شعار HerNess", "bn": "HerNess লোগো", "hi": "HerNess लोगो", "id": "Logo HerNess", "vi": "Logo HerNess", "ur": "HerNess لوگو", "mr": "HerNess लोगो", "te": "HerNess లోగో", "ta": "HerNess லோகோ", "fa": "نشان HerNess", "pl": "Logo HerNess", "uk": "Логотип HerNess", "th": "โลโก้ HerNess", "ms": "Logo HerNess", "ro": "Sigla HerNess", "el": "Λογότυπο HerNess", "cs": "Logo HerNess", "hu": "HerNess-logó"
    },
    "mobile.splash.buildLine": {
        "en": "BUILD  •  CONNECT  •  SHIP", "tr": "GELİŞTİR  •  BAĞLAN  •  YAYINLA", "de": "BAUEN  •  VERBINDEN  •  AUSLIEFERN", "es": "CREA  •  CONECTA  •  PUBLICA", "fr": "CRÉER  •  CONNECTER  •  LIVRER", "it": "CREA  •  CONNETTI  •  PUBBLICA", "ja": "BUILD  •  CONNECT  •  SHIP", "ko": "BUILD  •  CONNECT  •  SHIP", "nl": "BOUW  •  VERBIND  •  LEVER", "pt": "CRIAR  •  LIGAR  •  ENVIAR", "ru": "СОЗДАЙ  •  ПОДКЛЮЧИ  •  ЗАПУСТИ", "zh-Hans": "构建  •  连接  •  发布", "ar": "أنشئ  •  صِل  •  انشر", "bn": "তৈরি করুন  •  সংযোগ করুন  •  প্রকাশ করুন", "hi": "बनाएँ  •  जोड़ें  •  जारी करें", "id": "BANGUN  •  HUBUNGKAN  •  KIRIM", "vi": "XÂY DỰNG  •  KẾT NỐI  •  PHÁT HÀNH", "ur": "بنائیں  •  جوڑیں  •  جاری کریں", "mr": "तयार करा  •  जोडा  •  प्रकाशित करा", "te": "నిర్మించండి  •  కనెక్ట్ చేయండి  •  విడుదల చేయండి", "ta": "உருவாக்கு  •  இணை  •  வெளியிடு", "fa": "بساز  •  متصل شو  •  منتشر کن", "pl": "BUDUJ  •  ŁĄCZ  •  PUBLIKUJ", "uk": "СТВОРЮЙ  •  ПІДКЛЮЧАЙ  •  ПУБЛІКУЙ", "th": "สร้าง  •  เชื่อมต่อ  •  เผยแพร่", "ms": "BINA  •  SAMBUNG  •  HANTAR", "ro": "CONSTRUIEȘTE  •  CONECTEAZĂ  •  LIVREAZĂ", "el": "ΔΗΜΙΟΥΡΓΗΣΕ  •  ΣΥΝΔΕΣΕ  •  ΔΗΜΟΣΙΕΥΣΕ", "cs": "VYTVÁŘEJ  •  PŘIPOJ  •  NASAZUJ", "hu": "ÉPÍTS  •  KAPCSOLÓDJ  •  SZÁLLÍTS"
    },
    "intro.title.connect": {
        "en": "Bring HerNess with you.", "tr": "HerNess hep yanında.", "de": "HerNess ist immer dabei.", "es": "Lleva HerNess contigo.", "fr": "Emporte HerNess avec toi.", "it": "Porta HerNess con te.", "ja": "HerNessをどこへでも。", "ko": "HerNess를 어디서나.", "nl": "Neem HerNess met je mee.", "pt": "Leva o HerNess contigo.", "ru": "HerNess всегда с тобой.", "zh-Hans": "随身携带 HerNess。", "ar": "اصطحب HerNess معك.", "bn": "HerNess-কে সঙ্গে রাখুন।", "hi": "HerNess को अपने साथ रखें।", "id": "Bawa HerNess bersamamu.", "vi": "Mang HerNess theo bạn.", "ur": "HerNess کو اپنے ساتھ رکھیں۔", "mr": "HerNess सोबत ठेवा.", "te": "HerNessను మీతో తీసుకెళ్లండి.", "ta": "HerNess-ஐ உங்களுடன் எடுத்துச் செல்லுங்கள்.", "fa": "HerNess را همراه خود داشته باش.", "pl": "Zabierz HerNess ze sobą.", "uk": "Бери HerNess із собою.", "th": "พก HerNess ไปกับคุณ", "ms": "Bawa HerNess bersama anda.", "ro": "Ia HerNess cu tine.", "el": "Πάρε το HerNess μαζί σου.", "cs": "Vezmi si HerNess s sebou.", "hu": "Vidd magaddal a HerNess-t."
    },
    "intro.description.connect": {
        "en": "Create an independent workspace on your phone and keep your projects within reach.", "tr": "Telefonunda bağımsız bir çalışma alanı oluştur, projelerini dilediğin her an elinin altında tut.", "de": "Richte einen unabhängigen Arbeitsbereich auf deinem Telefon ein und habe deine Projekte immer griffbereit.", "es": "Crea un espacio de trabajo independiente en tu teléfono y ten tus proyectos siempre a mano.", "fr": "Crée un espace de travail indépendant sur ton téléphone et garde tes projets à portée de main.", "it": "Crea un’area di lavoro indipendente sul tuo telefono e tieni i tuoi progetti sempre a portata di mano.", "ja": "スマートフォン上に独立したワークスペースを作成し、いつでもプロジェクトを手元に。", "ko": "휴대폰에 독립적인 작업 공간을 만들고 언제든지 프로젝트를 가까이 두세요.", "nl": "Maak een onafhankelijke werkruimte op je telefoon en houd je projecten binnen handbereik.", "pt": "Cria um espaço de trabalho independente no teu telemóvel e mantém os teus projetos sempre à mão.", "ru": "Создай автономное рабочее пространство на телефоне и держи свои проекты всегда под рукой.", "zh-Hans": "在手机上创建独立工作区，让你的项目随时触手可及。", "ar": "أنشئ مساحة عمل مستقلة على هاتفك واحتفظ بمشاريعك دائمًا في متناول يدك.", "bn": "আপনার ফোনে একটি স্বাধীন ওয়ার্কস্পেস তৈরি করুন এবং প্রকল্পগুলি সবসময় হাতের কাছে রাখুন।", "hi": "अपने फ़ोन पर एक स्वतंत्र कार्यक्षेत्र बनाएँ और अपनी परियोजनाओं को हमेशा पास रखें।", "id": "Buat ruang kerja mandiri di ponselmu dan simpan proyekmu agar selalu mudah dijangkau.", "vi": "Tạo không gian làm việc độc lập trên điện thoại và giữ các dự án luôn trong tầm tay.", "ur": "اپنے فون پر ایک خود مختار ورک اسپیس بنائیں اور اپنے پروجیکٹس کو ہمیشہ قریب رکھیں۔", "mr": "तुमच्या फोनवर स्वतंत्र कार्यक्षेत्र तयार करा आणि तुमचे प्रकल्प नेहमी हाताशी ठेवा.", "te": "మీ ఫోన్‌లో స్వతంత్ర వర్క్‌స్పేస్‌ను సృష్టించి, మీ ప్రాజెక్ట్‌లను ఎల్లప్పుడూ అందుబాటులో ఉంచండి.", "ta": "உங்கள் தொலைபேசியில் ஒரு தனிப்பட்ட பணியிடத்தை உருவாக்கி, உங்கள் திட்டங்களை எப்போதும் அருகில் வைத்திருங்கள்.", "fa": "یک فضای کاری مستقل روی تلفنت بساز و پروژه‌هایت را همیشه در دسترس نگه دار.", "pl": "Utwórz niezależną przestrzeń roboczą na telefonie i miej projekty zawsze pod ręką.", "uk": "Створи автономний робочий простір на телефоні та тримай проєкти завжди під рукою.", "th": "สร้างพื้นที่ทำงานอิสระบนโทรศัพท์ของคุณ และให้โปรเจกต์อยู่ใกล้มือคุณเสมอ", "ms": "Cipta ruang kerja bebas pada telefon anda dan pastikan projek sentiasa dalam jangkauan.", "ro": "Creează un spațiu de lucru independent pe telefon și ține proiectele mereu la îndemână.", "el": "Δημιούργησε έναν ανεξάρτητο χώρο εργασίας στο τηλέφωνό σου και κράτα τα έργα σου πάντα πρόχειρα.", "cs": "Vytvoř si v telefonu nezávislý pracovní prostor a měj projekty vždy po ruce.", "hu": "Hozz létre független munkaterületet a telefonodon, és tartsd a projektjeidet mindig kéznél."
    },
    "intro.title.agent": {
        "en": "Turn ideas into code.", "tr": "Fikirlerini koda dönüştür.", "de": "Mach aus Ideen Code.", "es": "Convierte ideas en código.", "fr": "Transforme tes idées en code.", "it": "Trasforma le idee in codice.", "ja": "アイデアをコードに。", "ko": "아이디어를 코드로 바꾸세요.", "nl": "Maak van ideeën code.", "pt": "Transforma ideias em código.", "ru": "Превращай идеи в код.", "zh-Hans": "把想法变成代码。", "ar": "حوّل الأفكار إلى برمجيات.", "bn": "ভাবনাকে কোডে রূপ দিন।", "hi": "विचारों को कोड में बदलें।", "id": "Ubah ide menjadi kode.", "vi": "Biến ý tưởng thành mã.", "ur": "خیالات کو کوڈ میں بدلیں۔", "mr": "कल्पनांना कोडमध्ये बदला.", "te": "ఆలోచనలను కోడ్‌గా మార్చండి.", "ta": "யோசனைகளை குறியீடாக மாற்றுங்கள்.", "fa": "ایده‌ها را به کد تبدیل کن.", "pl": "Zamieniaj pomysły w kod.", "uk": "Перетворюй ідеї на код.", "th": "เปลี่ยนไอเดียให้เป็นโค้ด", "ms": "Tukarkan idea menjadi kod.", "ro": "Transformă ideile în cod.", "el": "Κάνε τις ιδέες σου κώδικα.", "cs": "Proměň nápady v kód.", "hu": "Váltsd az ötleteidet kóddá."
    },
    "intro.description.agent": {
        "en": "Run your AI agent, developer tools, and approvals directly on your phone without a computer.", "tr": "Yapay zeka ajanını, geliştirme araçlarını ve onay süreçlerini bilgisayara gerek kalmadan doğrudan telefonunda çalıştır.", "de": "Führe KI-Agent, Entwicklertools, Genehmigungen direkt auf deinem Telefon ohne Computer aus.", "es": "Ejecuta el agente de IA, herramientas, aprobaciones directamente en tu teléfono sin ordenador.", "fr": "Exécute l’agent IA, les outils de développement, les approbations directement sur ton téléphone, sans ordinateur.", "it": "Esegui l'agente IA, gli strumenti di sviluppo, le approvazioni direttamente sul telefono senza computer.", "ja": "PC不要で、AIエージェント、開発ツールと承認をスマートフォン上で直接実行できます。", "ko": "컴퓨터 없이도 AI 에이전트, 개발 도구와 승인을 휴대폰에서 직접 실행하세요.", "nl": "Voer de AI-agent, ontwikkeltools, goedkeuringen direct op je telefoon uit zonder computer.", "pt": "Executa o agente de IA, ferramentas, aprovações diretamente no telemóvel, sem computador.", "ru": "Запускай ИИ-агента, инструменты разработки, подтверждения прямо на телефоне без компьютера.", "zh-Hans": "无需电脑，也能在手机上直接运行 AI 智能体、开发工具与审批。", "ar": "شغّل وكيل الذكاء الاصطناعي وأدوات التطوير والموافقات مباشرة على هاتفك دون الحاجة إلى كمبيوتر.", "bn": "কম্পিউটার ছাড়াই আপনার ফোনে সরাসরি এআই এজেন্ট, ডেভেলপমেন্ট টুল, অনুমোদন চালান।", "hi": "कंप्यूटर के बिना सीधे अपने फ़ोन पर AI एजेंट, डेवलपमेंट टूल, अनुमोदन चलाएँ।", "id": "Jalankan agen AI, alat pengembangan, persetujuan langsung di ponsel tanpa komputer.", "vi": "Chạy agent AI, công cụ phát triển, phê duyệt trực tiếp trên điện thoại mà không cần máy tính.", "ur": "کمپیوٹر کے بغیر براہ راست اپنے فون پر AI ایجنٹ، ڈیولپمنٹ ٹولز، منظوریوں کو چلائیں۔", "mr": "संगणकाशिवाय थेट तुमच्या फोनवर AI एजंट, विकास साधने, मंजुरी चालवा.", "te": "కంప్యూటర్ లేకుండానే AI ఏజెంట్, డెవలపర్ టూల్స్, ఆమోదాలను నేరుగా మీ ఫోన్‌లో అమలు చేయండి.", "ta": "கணினி இல்லாமல் உங்கள் தொலைபேசியிலேயே AI ஏஜென்ட், கருவிகள், ஒப்புதல்களை நேரடியாக இயக்குங்கள்.", "fa": "عامل هوش مصنوعی، ابزارهای توسعه، تأییدها را مستقیماً روی تلفن بدون کامپیوتر اجرا کن.", "pl": "Uruchamiaj agenta AI, narzędzia programistyczne, zatwierdzenia bezpośrednio na telefonie bez komputera.", "uk": "Запускай ШІ-агента, інструменти розробки, схвалення прямо на телефоні без комп’ютера.", "th": "เรียกใช้เอเจนต์ AI เครื่องมือพัฒนา การอนุมัติได้โดยตรงบนโทรศัพท์โดยไม่ต้องใช้คอมพิวเตอร์", "ms": "Jalankan ejen AI, alat pembangunan, kelulusan terus pada telefon anda tanpa komputer.", "ro": "Rulează agentul AI, instrumentele de dezvoltare, aprobările direct pe telefon, fără computer.", "el": "Εκτέλεσε τον AI agent, τα εργαλεία ανάπτυξης, τις εγκρίσεις απευθείας στο τηλέφωνό σου χωρίς υπολογιστή.", "cs": "Spouštěj AI agenta, vývojářské nástroje, schvalování přímo v telefonu bez počítače.", "hu": "Futtasd az AI-ügynököt, a fejlesztői eszközöket, a jóváhagyásokat közvetlenül a telefonodon számítógép nélkül."
    },
    "intro.title.ship": {
        "en": "Move forward safely.", "tr": "Güvenle ilerle.", "de": "Geh sicher weiter.", "es": "Avanza con seguridad.", "fr": "Avance en toute sécurité.", "it": "Vai avanti in sicurezza.", "ja": "安全に前へ進もう。", "ko": "안전하게 앞으로 나아가세요.", "nl": "Ga veilig vooruit.", "pt": "Avança em segurança.", "ru": "Двигайся вперёд уверенно.", "zh-Hans": "安全地继续前进。", "ar": "تقدّم بأمان.", "bn": "নিরাপদে এগিয়ে যান।", "hi": "सुरक्षित रूप से आगे बढ़ें।", "id": "Melangkah dengan aman.", "vi": "Tiến bước an toàn.", "ur": "محفوظ طریقے سے آگے بڑھیں۔", "mr": "सुरक्षितपणे पुढे जा.", "te": "సురక్షితంగా ముందుకు సాగండి.", "ta": "பாதுகாப்பாக முன்னேறுங்கள்.", "fa": "با امنیت به جلو برو.", "pl": "Idź naprzód bezpiecznie.", "uk": "Рухайся вперед безпечно.", "th": "ก้าวต่อไปอย่างปลอดภัย", "ms": "Teruskan dengan selamat.", "ro": "Mergi mai departe în siguranță.", "el": "Προχώρα με ασφάλεια.", "cs": "Postupuj bezpečně.", "hu": "Haladj biztonságosan."
    },
    "intro.description.ship": {
        "en": "Review local changes, create a new branch, and ship with confidence when you are ready.", "tr": "Yerel değişikliklerini incele, yeni bir dal oluştur ve hazır olduğunda güvenle yayınla.", "de": "Prüfe lokale Änderungen, erstelle einen neuen Branch und liefere mit Zuversicht aus, sobald du bereit bist.", "es": "Revisa los cambios locales, crea una nueva rama y publica con confianza cuando estés listo.", "fr": "Vérifie les modifications locales, crée une nouvelle branche et livre en toute confiance quand tu es prêt.", "it": "Esamina le modifiche locali, crea un nuovo branch e pubblica con sicurezza quando sei pronto.", "ja": "ローカルの変更を確認し、新しいブランチを作成して、準備ができたら自信を持って公開できます。", "ko": "로컬 변경 사항을 검토하고 새 브랜치를 만든 뒤 준비가 되면 자신 있게 배포하세요.", "nl": "Bekijk lokale wijzigingen, maak een nieuwe branch en lever met vertrouwen uit wanneer je klaar bent.", "pt": "Revê as alterações locais, cria uma nova branch e publica com confiança quando estiveres pronto.", "ru": "Проверяй локальные изменения, создавай новую ветку и выпускай с уверенностью, когда всё готово.", "zh-Hans": "检查本地更改，创建新分支，准备就绪后自信地发布。", "ar": "راجع التغييرات المحلية، وأنشئ فرعًا جديدًا، وانشر بثقة عندما تكون جاهزًا.", "bn": "স্থানীয় পরিবর্তনগুলি পর্যালোচনা করুন, নতুন শাখা তৈরি করুন এবং প্রস্তুত হলে আত্মবিশ্বাসের সাথে প্রকাশ করুন।", "hi": "स्थानीय परिवर्तनों की समीक्षा करें, एक नई शाखा बनाएँ और तैयार होने पर विश्वास के साथ जारी करें।", "id": "Tinjau perubahan lokal, buat cabang baru, dan rilis dengan percaya diri saat kamu siap.", "vi": "Xem lại các thay đổi cục bộ, tạo nhánh mới và tự tin phát hành khi bạn đã sẵn sàng.", "ur": "مقامی تبدیلیوں کا جائزہ لیں، نئی برانچ بنائیں اور تیار ہونے پر اعتماد کے ساتھ شائع کریں۔", "mr": "स्थानिक बदल तपासा, नवीन शाखा तयार करा आणि तयार झाल्यावर आत्मविश्वासाने प्रकाशित करा.", "te": "స్థానిక మార్పులను సమీక్షించండి, కొత్త బ్రాంచ్‌ను సృష్టించండి మరియు సిద్ధంగా ఉన్నప్పుడు నమ్మకంతో విడుదల చేయండి.", "ta": "உள்ளூர் மாற்றங்களை மதிப்பாய்வு செய்து, புதிய கிளையை உருவாக்கி, தயாரானதும் நம்பிக்கையுடன் வெளியிடுங்கள்.", "fa": "تغییرات محلی را بررسی کن، یک شاخه جدید بساز و وقتی آماده بودی با اطمینان منتشر کن.", "pl": "Przeglądaj zmiany lokalne, twórz nową gałąź i publikuj z pewnością, gdy będziesz gotowy.", "uk": "Переглядай локальні зміни, створюй нову гілку та публікуй з упевненістю, коли будеш готовий.", "th": "ตรวจสอบการเปลี่ยนแปลงในเครื่อง สร้างบรานช์ใหม่ และเผยแพร่อย่างมั่นใจเมื่อคุณพร้อม", "ms": "Semak perubahan setempat, cipta cawangan baharu dan hantar dengan yakin apabila anda bersedia.", "ro": "Verifică modificările locale, creează o ramură nouă și publică cu încredere când ești gata.", "el": "Έλεγξε τις τοπικές αλλαγές, δημιούργησε νέο κλάδο και δημοσίευσε με σιγουριά όταν είσαι έτοιμος.", "cs": "Zkontroluj místní změny, vytvoř novou větev a nasaď je s jistotou, až budeš připraven.", "hu": "Nézd át a helyi módosításokat, hozz létre egy új ágat, és publikálj magabiztosan, amikor készen állsz."
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
        "en": "Get started", "tr": "Başla", "de": "Loslegen", "es": "Empezar", "fr": "Commencer", "it": "Inizia", "ja": "始める", "ko": "시작하기", "nl": "Aan de slag", "pt": "Começar", "ru": "Начать", "zh-Hans": "开始", "ar": "ابدأ", "bn": "শুরু করুন", "hi": "शुरू करें", "id": "Mulai", "vi": "Bắt đầu", "ur": "شروع کریں", "mr": "सुरू करा", "te": "ప్రారంభించండి", "ta": "தொடங்குங்கள்", "fa": "شروع", "pl": "Rozpocznij", "uk": "Почати", "th": "เริ่มต้น", "ms": "Mula", "ro": "Începe", "el": "Ξεκίνα", "cs": "Začít", "hu": "Kezdés"
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
    "mobile.nav.menu": { "en": "Open navigation", "tr": "Gezinme menüsünü aç", "de": "Navigation öffnen", "es": "Abrir navegación", "fr": "Ouvrir la navigation", "it": "Apri la navigazione", "ja": "ナビゲーションを開く", "ko": "탐색 메뉴 열기", "nl": "Navigatie openen", "pt": "Abrir navegação", "ru": "Открыть меню навигации", "zh-Hans": "打开导航", "ar": "فتح قائمة التنقل", "bn": "নেভিগেশন খুলুন", "hi": "नेविगेशन खोलें", "id": "Buka navigasi", "vi": "Mở điều hướng", "ur": "نیویگیشن کھولیں", "mr": "नेव्हिगेशन उघडा", "te": "నావిగేషన్ తెరవండి", "ta": "வழிசெலுத்தலைத் திற", "fa": "باز کردن پیمایش", "pl": "Otwórz nawigację", "uk": "Відкрити навігацію", "th": "เปิดเมนูนำทาง", "ms": "Buka navigasi", "ro": "Deschide navigarea", "el": "Άνοιγμα πλοήγησης", "cs": "Otevřít navigaci", "hu": "Navigáció megnyitása" },
    "mobile.agent.dictate": { "en": "Dictate prompt", "tr": "İsteği sesle yaz", "de": "Prompt diktieren", "es": "Dictar el mensaje", "fr": "Dicter le prompt", "it": "Dettare il prompt", "ja": "プロンプトを音声入力", "ko": "프롬프트 받아쓰기", "nl": "Prompt dicteren", "pt": "Ditar o pedido", "ru": "Продиктовать запрос", "zh-Hans": "口述提示词", "ar": "إملاء الطلب", "bn": "প্রম্পট মুখে বলুন", "hi": "प्रॉम्प्ट बोलकर लिखें", "id": "Diktekan prompt", "vi": "Đọc chính tả lời nhắc", "ur": "پرامپٹ بول کر لکھیں", "mr": "प्रॉम्प्ट सांगा", "te": "ప్రాంప్ట్‌ను డిక్టేట్ చేయండి", "ta": "செய்தியை குரலால் உள்ளிடு", "fa": "گفتن درخواست", "pl": "Dyktuj polecenie", "uk": "Продиктувати запит", "th": "ป้อนข้อความด้วยเสียง", "ms": "Dikte prompt", "ro": "Dictează solicitarea", "el": "Υπαγόρευσε το μήνυμα", "cs": "Nadiktovat zadání", "hu": "Prompt diktálása" },
    "mobile.nav.code": { "en": "Code", "tr": "Kod", "de": "Code", "es": "Código", "fr": "Code", "it": "Codice", "ja": "コード", "ko": "코드", "nl": "Code", "pt": "Código", "ru": "Код", "zh-Hans": "代码", "ar": "الكود", "bn": "কোড", "hi": "कोड", "id": "Kode", "vi": "Mã", "ur": "کوڈ", "mr": "कोड", "te": "కోడ్", "ta": "குறியீடு", "fa": "کد", "pl": "Kod", "uk": "Код", "th": "โค้ด", "ms": "Kod", "ro": "Cod", "el": "Κώδικας", "cs": "Kód", "hu": "Kód" },
    "mobile.nav.agent": { "en": "Agent", "tr": "Ajan", "de": "Agent", "es": "Agente", "fr": "Agent", "it": "Agente", "ja": "エージェント", "ko": "에이전트", "nl": "Agent", "pt": "Agente", "ru": "Агент", "zh-Hans": "智能体", "ar": "الوكيل", "bn": "এজেন্ট", "hi": "एजेंट", "id": "Agen", "vi": "Agent", "ur": "ایجنٹ", "mr": "एजंट", "te": "ఏజెంట్", "ta": "ஏஜென்ட்", "fa": "عامل", "pl": "Agent", "uk": "Агент", "th": "เอเจนต์", "ms": "Ejen", "ro": "Agent", "el": "Agent", "cs": "Agent", "hu": "Ügynök" },
    "mobile.nav.terminal": { "en": "Terminal", "tr": "Terminal", "de": "Terminal", "es": "Terminal", "fr": "Terminal", "it": "Terminale", "ja": "ターミナル", "ko": "터미널", "nl": "Terminal", "pt": "Terminal", "ru": "Терминал", "zh-Hans": "终端", "ar": "الطرفية", "bn": "টার্মিনাল", "hi": "टर्मिनल", "id": "Terminal", "vi": "Terminal", "ur": "ٹرمینل", "mr": "टर्मिनल", "te": "టెర్మినల్", "ta": "டெர்மினல்", "fa": "ترمینال", "pl": "Terminal", "uk": "Термінал", "th": "เทอร์มินัล", "ms": "Terminal", "ro": "Terminal", "el": "Τερματικό", "cs": "Terminál", "hu": "Terminál" },
    "mobile.nav.preview": { "en": "Preview", "tr": "Önizleme", "de": "Vorschau", "es": "Vista previa", "fr": "Aperçu", "it": "Anteprima", "ja": "プレビュー", "ko": "미리보기", "nl": "Voorbeeld", "pt": "Pré-visualização", "ru": "Предпросмотр", "zh-Hans": "预览", "ar": "معاينة", "bn": "প্রিভিউ", "hi": "पूर्वावलोकन", "id": "Pratinjau", "vi": "Xem trước", "ur": "پیش منظر", "mr": "पूर्वदृश्य", "te": "ప్రివ్యూ", "ta": "முன்னோட்டம்", "fa": "پیش‌نمایش", "pl": "Podgląd", "uk": "Попередній перегляд", "th": "ตัวอย่าง", "ms": "Pratonton", "ro": "Previzualizare", "el": "Προεπισκόπηση", "cs": "Náhled", "hu": "Előnézet" },
    "mobile.nav.settings": { "en": "Settings", "tr": "Ayarlar", "de": "Einstellungen", "es": "Ajustes", "fr": "Réglages", "it": "Impostazioni", "ja": "設定", "ko": "설정", "nl": "Instellingen", "pt": "Definições", "ru": "Настройки", "zh-Hans": "设置", "ar": "الإعدادات", "bn": "সেটিংস", "hi": "सेटिंग्स", "id": "Pengaturan", "vi": "Cài đặt", "ur": "ترتیبات", "mr": "सेटिंग्ज", "te": "సెట్టింగ్‌లు", "ta": "அமைப்புகள்", "fa": "تنظیمات", "pl": "Ustawienia", "uk": "Налаштування", "th": "การตั้งค่า", "ms": "Tetapan", "ro": "Setări", "el": "Ρυθμίσεις", "cs": "Nastavení", "hu": "Beállítások" },
    "settings.tab.general": { "en": "General", "tr": "Genel", "de": "Allgemein", "es": "General", "fr": "Général", "it": "Generale", "ja": "一般", "ko": "일반", "nl": "Algemeen", "pt": "Geral", "ru": "Общие", "zh-Hans": "通用", "ar": "عام", "bn": "সাধারণ", "hi": "सामान्य", "id": "Umum", "vi": "Chung", "ur": "عمومی", "mr": "सामान्य", "te": "సాధారణ", "ta": "பொது", "fa": "عمومی", "pl": "Ogólne", "uk": "Загальні", "th": "ทั่วไป", "ms": "Umum", "ro": "Generale", "el": "Γενικά", "cs": "Obecné", "hu": "Általános" },
    "settings.tab.accounts": { "en": "Accounts", "tr": "Hesaplar", "de": "Konten", "es": "Cuentas", "fr": "Comptes", "it": "Account", "ja": "アカウント", "ko": "계정", "nl": "Accounts", "pt": "Contas", "ru": "Аккаунты", "zh-Hans": "账户", "ar": "الحسابات", "bn": "অ্যাকাউন্ট", "hi": "खाते", "id": "Akun", "vi": "Tài khoản", "ur": "اکاؤنٹس", "mr": "खाती", "te": "ఖాతాలు", "ta": "கணக்குகள்", "fa": "حساب‌ها", "pl": "Konta", "uk": "Облікові записи", "th": "บัญชี", "ms": "Akaun", "ro": "Conturi", "el": "Λογαριασμοί", "cs": "Účty", "hu": "Fiókok" },
    "settings.tab.repository": { "en": "Repo", "tr": "Depo", "de": "Repository", "es": "Repositorio", "fr": "Dépôt", "it": "Repository", "ja": "リポジトリ", "ko": "저장소", "nl": "Repo", "pt": "Repositório", "ru": "Репозиторий", "zh-Hans": "仓库", "ar": "المستودع", "bn": "রিপোজিটরি", "hi": "रिपॉज़िटरी", "id": "Repo", "vi": "Kho", "ur": "ریپوزٹری", "mr": "रेपॉझिटरी", "te": "రిపోజిటరీ", "ta": "களஞ்சியம்", "fa": "مخزن", "pl": "Repozytorium", "uk": "Репозиторій", "th": "คลังเก็บ", "ms": "Repositori", "ro": "Depozit", "el": "Αποθετήριο", "cs": "Repozitář", "hu": "Tároló" },
    "settings.tab.tools": { "en": "Tools", "tr": "Araçlar", "de": "Tools", "es": "Herramientas", "fr": "Outils", "it": "Strumenti", "ja": "ツール", "ko": "도구", "nl": "Tools", "pt": "Ferramentas", "ru": "Инструменты", "zh-Hans": "工具", "ar": "الأدوات", "bn": "টুল", "hi": "उपकरण", "id": "Alat", "vi": "Công cụ", "ur": "ٹولز", "mr": "साधने", "te": "సాధనాలు", "ta": "கருவிகள்", "fa": "ابزارها", "pl": "Narzędzia", "uk": "Інструменти", "th": "เครื่องมือ", "ms": "Alat", "ro": "Instrumente", "el": "Εργαλεία", "cs": "Nástroje", "hu": "Eszközök" },
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
    "mobile.agent.applyPlan": {
        "en": "Apply plan", "tr": "Planı uygula", "de": "Plan anwenden", "es": "Aplicar plan", "fr": "Appliquer le plan", "it": "Applica piano", "ja": "計画を適用", "ko": "계획 적용", "nl": "Plan toepassen", "pt": "Aplicar plano", "ru": "Применить план", "zh-Hans": "应用计划", "ar": "تطبيق الخطة", "bn": "পরিকল্পনা প্রয়োগ করুন", "hi": "योजना लागू करें", "id": "Terapkan rencana", "vi": "Áp dụng kế hoạch", "ur": "منصوبہ لاگو کریں", "mr": "योजना लागू करा", "te": "ప్రణాళికను వర్తింపజేయి", "ta": "திட்டத்தைப் பயன்படுத்து", "fa": "اعمال طرح", "pl": "Zastosuj plan", "uk": "Застосувати план", "th": "ใช้แผน", "ms": "Gunakan pelan", "ro": "Aplică planul", "el": "Εφαρμογή σχεδίου", "cs": "Použít plán", "hu": "Terv alkalmazása"
    },
    "mobile.agent.cancelPlan": {
        "en": "Cancel plan", "tr": "Planı iptal et", "de": "Plan abbrechen", "es": "Cancelar plan", "fr": "Annuler le plan", "it": "Annulla piano", "ja": "計画をキャンセル", "ko": "계획 취소", "nl": "Plan annuleren", "pt": "Cancelar plano", "ru": "Отменить план", "zh-Hans": "取消计划", "ar": "إلغاء الخطة", "bn": "পরিকল্পনা বাতিল করুন", "hi": "योजना रद्द करें", "id": "Batalkan rencana", "vi": "Hủy kế hoạch", "ur": "منصوبہ منسوخ کریں", "mr": "योजना रद्द करा", "te": "ప్రణాళికను రద్దు చేయి", "ta": "திட்டத்தை ரத்துசெய்", "fa": "لغو طرح", "pl": "Anuluj plan", "uk": "Скасувати план", "th": "ยกเลิกแผน", "ms": "Batalkan pelan", "ro": "Anulează planul", "el": "Ακύρωση σχεδίου", "cs": "Zrušit plán", "hu": "Terv elvetése"
    },
    "mobile.agent.continuePlan": {
        "en": "Continue plan", "tr": "Plana devam et", "de": "Plan fortsetzen", "es": "Continuar plan", "fr": "Poursuivre le plan", "it": "Continua piano", "ja": "計画を続行", "ko": "계획 계속", "nl": "Plan voortzetten", "pt": "Continuar plano", "ru": "Продолжить план", "zh-Hans": "继续计划", "ar": "متابعة الخطة", "bn": "পরিকল্পনা চালিয়ে যান", "hi": "योजना जारी रखें", "id": "Lanjutkan rencana", "vi": "Tiếp tục kế hoạch", "ur": "منصوبہ جاری رکھیں", "mr": "योजना सुरू ठेवा", "te": "ప్రణాళికను కొనసాగించు", "ta": "திட்டத்தைத் தொடர்", "fa": "ادامه طرح", "pl": "Kontynuuj plan", "uk": "Продовжити план", "th": "ทำตามแผนต่อ", "ms": "Teruskan pelan", "ro": "Continuă planul", "el": "Συνέχιση σχεδίου", "cs": "Pokračovat v plánu", "hu": "Terv folytatása"
    },
    "mobile.agent.planPaused": {
        "en": "Plan paused; queued messages are held.", "tr": "Plan duraklatıldı; kuyruktaki mesajlar bekletiliyor.", "de": "Plan pausiert; Nachrichten in der Warteschlange werden gehalten.", "es": "Plan pausado; los mensajes en cola están retenidos.", "fr": "Plan suspendu ; les messages en attente sont retenus.", "it": "Piano in pausa; i messaggi in coda sono trattenuti.", "ja": "計画を一時停止しました。キュー内のメッセージは保留中です。", "ko": "계획이 일시중지됨; 대기열의 메시지가 대기 중입니다.", "nl": "Plan gepauzeerd; berichten in de wachtrij worden vastgehouden.", "pt": "Plano em pausa; as mensagens em fila estão retidas.", "ru": "План приостановлен; сообщения в очереди удерживаются.", "zh-Hans": "计划已暂停；已暂缓队列中的消息。", "ar": "تم إيقاف الخطة مؤقتًا؛ الرسائل في قائمة الانتظار معلقة.", "bn": "পরিকল্পনা স্থগিত; সারির বার্তাগুলি রাখা হয়েছে।", "hi": "योजना रोक दी गई; कतार में संदेश रखे गए हैं।", "id": "Rencana dijeda; pesan dalam antrean ditahan.", "vi": "Đã tạm dừng kế hoạch; tin nhắn trong hàng đợi đang được giữ lại.", "ur": "منصوبہ موقوف؛ قطار کے پیغامات روکے گئے ہیں۔", "mr": "योजना थांबवली; रांगेतील संदेश रोखून धरले आहेत.", "te": "ప్రణాళిక నిలిపివేయబడింది; క్యూలో ఉన్న సందేశాలు ఉంచబడ్డాయి.", "ta": "திட்டம் இடைநிறுத்தப்பட்டது; வரிசையில் உள்ள செய்திகள் நிறுத்தி வைக்கப்பட்டுள்ளன.", "fa": "طرح متوقف شد؛ پیام‌های صف نگه داشته شده‌اند.", "pl": "Plan wstrzymany; wiadomości w kolejce są wstrzymane.", "uk": "План призупинено; повідомлення в черзі затримано.", "th": "หยุดแผนชั่วคราว ข้อความในคิวถูกระงับไว้", "ms": "Pelan dijeda; mesej beratur ditahan.", "ro": "Plan întrerupt; mesajele din coadă sunt reținute.", "el": "Το σχέδιο διακόπηκε προσωρινά· τα μηνύματα στην ουρά κρατούνται.", "cs": "Plán pozastaven; zprávy ve frontě jsou pozastaveny.", "hu": "Terv szüneteltetve; a sorban álló üzenetek várakoznak."
    },
    "mobile.agent.planSubtitle": {
        "en": "Review the project and prepare an implementation plan.", "tr": "Projeyi incele ve uygulama planı hazırla.", "de": "Prüfe das Projekt und erstelle einen Implementierungsplan.", "es": "Revisa el proyecto y prepara un plan de implementación.", "fr": "Examine le projet et prépare un plan de mise en œuvre.", "it": "Esamina il progetto e prepara un piano di implementazione.", "ja": "プロジェクトを確認して実装計画を立てます。", "ko": "프로젝트를 검토하고 구현 계획을 준비합니다.", "nl": "Bekijk het project en maak een implementatieplan.", "pt": "Revê o projeto e prepara um plano de implementação.", "ru": "Проверь проект и подготовь план реализации.", "zh-Hans": "审查项目并准备实施计划。", "ar": "راجع المشروع وجهّز خطة تنفيذ.", "bn": "প্রকল্প পর্যালোচনা করুন এবং একটি বাস্তবায়ন পরিকল্পনা তৈরি করুন।", "hi": "परियोजना की समीक्षा करें और कार्यान्वयन योजना तैयार करें।", "id": "Tinjau proyek dan siapkan rencana implementasi.", "vi": "Xem xét dự án và chuẩn bị kế hoạch triển khai.", "ur": "پروجیکٹ کا جائزہ لیں اور نفاذ کا منصوبہ تیار کریں۔", "mr": "प्रकल्प तपासा आणि अंमलबजावणीची योजना तयार करा.", "te": "ప్రాజెక్ట్‌ను సమీక్షించి అమలు ప్రణాళికను సిద్ధం చేయండి.", "ta": "திட்டத்தை மதிப்பாய்வு செய்து செயலாக்கத் திட்டத்தைத் தயாரிக்கவும்.", "fa": "پروژه را بررسی کن و برنامه اجرا آماده کن.", "pl": "Przejrzyj projekt i przygotuj plan wdrożenia.", "uk": "Переглянь проєкт і підготуй план реалізації.", "th": "ตรวจสอบโปรเจกต์และเตรียมแผนการนำไปใช้", "ms": "Semak projek dan sediakan pelan pelaksanaan.", "ro": "Revizuiește proiectul și pregătește un plan de implementare.", "el": "Εξέτασε το έργο και προετοίμασε ένα σχέδιο υλοποίησης.", "cs": "Zkontroluj projekt a připrav plán implementace.", "hu": "Tekintsd át a projektet, és készíts végrehajtási tervet."
    },
    "mobile.agent.queuedMessages": {
        "en": "Queued messages", "tr": "Kuyruktaki mesajlar", "de": "Warteschlangen-Nachrichten", "es": "Mensajes en cola", "fr": "Messages en attente", "it": "Messaggi in coda", "ja": "キュー内のメッセージ", "ko": "대기 중인 메시지", "nl": "Berichten in de wachtrij", "pt": "Mensagens em fila", "ru": "Сообщения в очереди", "zh-Hans": "队列中的消息", "ar": "الرسائل في قائمة الانتظار", "bn": "সারিবদ্ধ বার্তা", "hi": "कतारबद्ध संदेश", "id": "Pesan dalam antrean", "vi": "Tin nhắn trong hàng đợi", "ur": "قطار میں پیغامات", "mr": "रांगेतील संदेश", "te": "క్యూలో ఉన్న సందేశాలు", "ta": "வரிசையில் உள்ள செய்திகள்", "fa": "پیام‌های در صف", "pl": "Wiadomości w kolejce", "uk": "Повідомлення в черзі", "th": "ข้อความในคิว", "ms": "Mesej dalam barisan", "ro": "Mesaje în coadă", "el": "Μηνύματα στην ουρά", "cs": "Zprávy ve frontě", "hu": "Sorban álló üzenetek"
    },
    "mobile.agent.promote": {
        "en": "Run now", "tr": "Şimdi çalıştır", "de": "Jetzt ausführen", "es": "Ejecutar ahora", "fr": "Exécuter maintenant", "it": "Esegui ora", "ja": "今すぐ実行", "ko": "지금 실행", "nl": "Nu uitvoeren", "pt": "Executar agora", "ru": "Запустить сейчас", "zh-Hans": "立即运行", "ar": "تشغيل الآن", "bn": "এখন চালান", "hi": "अभी चलाएँ", "id": "Jalankan sekarang", "vi": "Chạy ngay", "ur": "ابھی چلائیں", "mr": "आता चालवा", "te": "ఇప్పుడే అమలు చేయి", "ta": "இப்போது இயக்கு", "fa": "هم‌اکنون اجرا کن", "pl": "Uruchom teraz", "uk": "Запустити зараз", "th": "เรียกใช้ตอนนี้", "ms": "Jalankan sekarang", "ro": "Rulează acum", "el": "Εκτέλεση τώρα", "cs": "Spustit nyní", "hu": "Futtatás most"
    },
    "mobile.queue.waitingForPlan": {
        "en": "Waiting for plan approval", "tr": "Plan onayı bekleniyor", "de": "Warten auf Plangenehmigung", "es": "Esperando aprobación del plan", "fr": "En attente de l’approbation du plan", "it": "In attesa di approvazione del piano", "ja": "計画の承認待ち", "ko": "계획 승인 대기 중", "nl": "Wachten op goedkeuring van plan", "pt": "A aguardar aprovação do plano", "ru": "Ожидание утверждения плана", "zh-Hans": "等待计划批准", "ar": "بانتظار الموافقة على الخطة", "bn": "পরিকল্পনা অনুমোদনের অপেক্ষায়", "hi": "योजना अनुमोदन की प्रतीक्षा है", "id": "Menunggu persetujuan rencana", "vi": "Đang chờ phê duyệt kế hoạch", "ur": "منصوبہ منظوری کا انتظار ہے", "mr": "योजना मंजुरीची प्रतीक्षा आहे", "te": "ప్రణాళిక ఆమోదం కోసం వేచి ఉంది", "ta": "திட்ட ஒப்புதலுக்கு காத்திருக்கிறது", "fa": "در انتظار تأیید طرح", "pl": "Oczekiwanie na zatwierdzenie planu", "uk": "Очікування схвалення плану", "th": "กำลังรอการอนุมัติแผน", "ms": "Menunggu kelulusan pelan", "ro": "Se așteaptă aprobarea planului", "el": "Αναμονή για έγκριση σχεδίου", "cs": "Čeká se na schválení plánu", "hu": "Várakozás a terv jóváhagyására"
    },
    "mobile.settings.providerStored": {
        "en": "API key stored on this device", "tr": "API anahtarı bu cihazda saklanıyor", "de": "API-Schlüssel auf diesem Gerät gespeichert", "es": "Clave de API guardada en este dispositivo", "fr": "Clé API enregistrée sur cet appareil", "it": "Chiave API memorizzata su questo dispositivo", "ja": "このデバイスにAPIキーを保存済み", "ko": "이 기기에 API 키 저장됨", "nl": "API-sleutel op dit apparaat opgeslagen", "pt": "Chave de API guardada neste dispositivo", "ru": "Ключ API сохранен на этом устройстве", "zh-Hans": "API 密钥已存储在此设备上", "ar": "مفتاح API مخزن على هذا الجهاز", "bn": "এই ডিভাইসে API কী সংরক্ষিত আছে", "hi": "इस डिवाइस पर API कुंजी संग्रहीत है", "id": "Kunci API disimpan di perangkat ini", "vi": "Khóa API đã lưu trên thiết bị này", "ur": "اس آلہ پر API کلید محفوظ ہے", "mr": "या डिव्हाइसवर API की सेव्ह केली आहे", "te": "ఈ పరికరంలో API కీ సేవ్ చేయబడింది", "ta": "இந்த சாதனத்தில் API சாவி சேமிக்கப்பட்டுள்ளது", "fa": "کلید API در این دستگاه ذخیره شده است", "pl": "Klucz API zapisany na tym urządzeniu", "uk": "Ключ API збережено на цьому пристрої", "th": "คีย์ API ถูกบันทึกไว้ในอุปกรณ์นี้", "ms": "Kunci API disimpan pada peranti ini", "ro": "Cheie API stocată pe acest dispozitiv", "el": "Το κλειδί API είναι αποθηκευμένο σε αυτή τη συσκευή", "cs": "Klíč API je uložen v tomto zařízení", "hu": "Az API-kulcs ezen az eszközön van tárolva"
    },
    "mobile.settings.providerMissing": {
        "en": "No API key saved for this provider", "tr": "Bu sağlayıcı için kayıtlı API anahtarı yok", "de": "Kein API-Schlüssel für diesen Anbieter gespeichert", "es": "No hay clave de API guardada para este proveedor", "fr": "Aucune clé API enregistrée pour ce fournisseur", "it": "Nessuna chiave API salvata per questo provider", "ja": "このプロバイダーのAPIキーは保存されていません", "ko": "이 제공업체에 저장된 API 키 없음", "nl": "Geen API-sleutel opgeslagen voor deze provider", "pt": "Nenhuma chave de API guardada para este fornecedor", "ru": "Для этого поставщика нет сохраненного ключа API", "zh-Hans": "未为此提供商保存 API 密钥", "ar": "لا يوجد مفتاح API محفوظ لهذا المزود", "bn": "এই প্রদানকারীর জন্য কোনও API কী সংরক্ষিত নেই", "hi": "इस प्रदाता के लिए कोई API कुंजी सहेजी नहीं गई है", "id": "Tidak ada kunci API yang disimpan untuk penyedia ini", "vi": "Chưa lưu khóa API nào cho nhà cung cấp này", "ur": "اس فراہم کنندہ کے لیے کوئی API کلید محفوظ نہیں ہے", "mr": "या प्रदात्यासाठी कोणतीही API की जतन केलेली नाही", "te": "ఈ ప్రొవైడర్ కోసం ఏ API కీ సేవ్ చేయబడలేదు", "ta": "இந்த வழங்குநருக்கு எந்த API சாவியும் சேமிக்கப்படவில்லை", "fa": "هیچ کلید API برای این ارائه‌دهنده ذخیره نشده است", "pl": "Brak zapisanego klucza API dla tego dostawcy", "uk": "Для цього постачальника не збережено ключ API", "th": "ไม่มีคีย์ API ที่บันทึกไว้สำหรับผู้ให้บริการนี้", "ms": "Tiada kunci API disimpan untuk pembekal ini", "ro": "Nicio cheie API salvată pentru acest furnizor", "el": "Δεν έχει αποθηκευτεί κλειδί API για αυτόν τον πάροχο", "cs": "Pro tohoto poskytovatele není uložen žádný klíč API", "hu": "Nincs mentett API-kulcs ehhez a szolgáltatóhoz"
    },
    "mobile.settings.providerOAuth": {
        "en": "Uses the signed-in OAuth account", "tr": "Giriş yapılmış OAuth hesabını kullanır", "de": "Verwendet das angemeldete OAuth-Konto", "es": "Usa la cuenta de OAuth conectada", "fr": "Utilise le compte OAuth connecté", "it": "Utilizza l'account OAuth connesso", "ja": "サインイン済みのOAuthアカウントを使用", "ko": "로그인된 OAuth 계정 사용", "nl": "Gebruikt het ingelogde OAuth-account", "pt": "Utiliza a conta OAuth com sessão iniciada", "ru": "Использует подключенную учетную запись OAuth", "zh-Hans": "使用已登录的 OAuth 帐户", "ar": "يستخدم حساب OAuth الذي تم تسجيل الدخول إليه", "bn": "সাইন-ইন করা OAuth অ্যাকাউন্ট ব্যবহার করে", "hi": "साइन-इन किए गए OAuth खाते का उपयोग करता है", "id": "Menggunakan akun OAuth yang masuk", "vi": "Sử dụng tài khoản OAuth đã đăng nhập", "ur": "سائن ان شدہ OAuth اکاؤنٹ استعمال کرتا ہے", "mr": "साइन-इन केलेले OAuth खाते वापरते", "te": "సైన్ ఇన్ చేసిన OAuth ఖాతాను ఉపయోగిస్తుంది", "ta": "உள்நுழைந்த OAuth கணக்கைப் பயன்படுத்துகிறது", "fa": "از حساب OAuth وارد شده استفاده می‌کند", "pl": "Używa zalogowanego konta OAuth", "uk": "Використовує підключений обліковий запис OAuth", "th": "ใช้บัญชี OAuth ที่ลงชื่อเข้าใช้แล้ว", "ms": "Menggunakan akaun OAuth yang dilog masuk", "ro": "Utilizează contul OAuth conectat", "el": "Χρησιμοποιεί τον συνδεδεμένο λογαριασμό OAuth", "cs": "Používá přihlášený účet OAuth", "hu": "A bejelentkezett OAuth-fiókot használja"
    },
    "mobile.agent.planSettingsSection": {
        "en": "Plan behavior", "tr": "Plan davranışı", "de": "Planverhalten", "es": "Comportamiento del plan", "fr": "Comportement du plan", "it": "Comportamento del piano", "ja": "計画の動作", "ko": "계획 동작", "nl": "Plangedrag", "pt": "Comportamento do plano", "ru": "Поведение плана", "zh-Hans": "计划行为", "ar": "سلوك الخطة", "bn": "পরিকল্পনার আচরণ", "hi": "योजना व्यवहार", "id": "Perilaku rencana", "vi": "Hành vi kế hoạch", "ur": "منصوبے کا طرز عمل", "mr": "योजना वर्तन", "te": "ప్రణాళిక ప్రవర్తన", "ta": "திட்ட நடத்தை", "fa": "رفتار طرح", "pl": "Zachowanie planu", "uk": "Поведінка плану", "th": "พฤติกรรมของแผน", "ms": "Tingkah laku pelan", "ro": "Comportamentul planului", "el": "Συμπεριφορά σχεδίου", "cs": "Chování plánu", "hu": "Terv viselkedése"
    },
    "mobile.agent.autoApprovePlans": {
        "en": "Automatically approve plans", "tr": "Planları otomatik onayla", "de": "Pläne automatisch genehmigen", "es": "Aprobar planes automáticamente", "fr": "Approuver automatiquement les plans", "it": "Approva automaticamente i piani", "ja": "計画を自動承認", "ko": "계획 자동 승인", "nl": "Plannen automatisch goedkeuren", "pt": "Aprovar planos automaticamente", "ru": "Автоматически утверждать планы", "zh-Hans": "自动批准计划", "ar": "الموافقة تلقائيًا على الخطط", "bn": "পরিকল্পনা স্বয়ংক্রিয়ভাবে অনুমোদন করুন", "hi": "योजनाओं को स्वचालित रूप से स्वीकृत करें", "id": "Setujui rencana secara otomatis", "vi": "Tự động phê duyệt kế hoạch", "ur": "منصوبوں کی خودکار منظوری دیں", "mr": "योजना आपोआप मंजूर करा", "te": "ప్రణాళికలను స్వయంచాలకంగా ఆమోదించు", "ta": "திட்டங்களை தானாகவே ஒப்புதல் அளிக்கவும்", "fa": "تأیید خودکار طرح‌ها", "pl": "Automatycznie zatwierdzaj plany", "uk": "Автоматично схвалювати плани", "th": "อนุมัติแผนโดยอัตโนมัติ", "ms": "Luluskan pelan secara automatik", "ro": "Aprobă automat planurile", "el": "Αυτόματη έγκριση σχεδίων", "cs": "Automaticky schvalovat plány", "hu": "Tervek automatikus jóváhagyása"
    },
    "mobile.agent.autoApprovePlansHint": {
        "en": "Apply a generated plan automatically while keeping tool approvals.", "tr": "Araç onaylarını korurken oluşturulan planı otomatik uygula.", "de": "Wendet einen generierten Plan automatisch an, während Tool-Genehmigungen beibehalten werden.", "es": "Aplica un plan generado automáticamente manteniendo las aprobaciones de herramientas.", "fr": "Applique automatiquement un plan généré tout en conservant les approbations des outils.", "it": "Applica automaticamente un piano generato mantenendo le approvazioni degli strumenti.", "ja": "ツールの承認を維持しながら、生成された計画を自動的に適用します。", "ko": "도구 승인을 유지하면서 생성된 계획을 자동으로 적용합니다.", "nl": "Pas een gegenereerd plan automatisch toe met behoud van toolgoedkeuringen.", "pt": "Aplica automaticamente um plano gerado mantendo as aprovações de ferramentas.", "ru": "Автоматически применять созданный план, сохраняя подтверждения инструментов.", "zh-Hans": "自动应用生成的计划，同时保留工具审批。", "ar": "تطبيق الخطة المنشأة تلقائيًا مع الاحتفاظ بموافقات الأدوات.", "bn": "টুল অনুমোদন বজায় রেখে উৎপন্ন পরিকল্পনা স্বয়ংক্রিয়ভাবে প্রয়োগ করুন।", "hi": "टूल अनुमोदनों को बनाए रखते हुए जनरेट की गई योजना स्वचालित रूप से लागू करें।", "id": "Terapkan rencana yang dibuat secara otomatis dengan tetap mempertahankan persetujuan alat.", "vi": "Tự động áp dụng kế hoạch đã tạo trong khi vẫn giữ phê duyệt công cụ.", "ur": "ٹول کی منظوری برقرار رکھتے ہوئے تیار کردہ منصوبہ خودکار طور پر لاگو کریں۔", "mr": "साधन मंजुरी कायम ठेवून तयार केलेली योजना आपोआप लागू करा.", "te": "టూల్ ఆమోదాలను కొనసాగిస్తూ రూపొందించిన ప్రణాళికను స్వయంచాలకంగా వర్తింపజేయండి.", "ta": "கருவி ஒப்புதல்களைப் பராமரிக்கும் போது உருவாக்கப்பட்ட திட்டத்தை தானாகவே பயன்படுத்தவும்.", "fa": "طرح ایجاد شده را ضمن حفظ تأییدیه‌های ابزار به‌طور خودکار اعمال کن.", "pl": "Automatycznie stosuj wygenerowany plan, zachowując zatwierdzenia narzędzi.", "uk": "Автоматично застосовувати створений план, зберігаючи схвалення інструментів.", "th": "ใช้แผนที่สร้างขึ้นโดยอัตโนมัติในขณะที่ยังคงการอนุมัติเครื่องมือไว้", "ms": "Gunakan pelan yang dijana secara automatik sambil mengekalkan kelulusan alat.", "ro": "Aplică automat un plan generat, păstrând aprobările instrumentelor.", "el": "Αυτόματη εφαρμογή ενός παραγόμενου σχεδίου διατηρώντας τις εγκρίσεις εργαλείων.", "cs": "Automaticky použije vygenerovaný plán při zachování schvalování nástrojů.", "hu": "Automatikusan alkalmazza a generált tervet az eszközjóváhagyások megtartása mellett."
    },
    "mobile.agent.subagentsSection": {
        "en": "Subagents", "tr": "Alt ajanlar", "de": "Subagenten", "es": "Subagentes", "fr": "Sous-agents", "it": "Subagenti", "ja": "サブエージェント", "ko": "서브에이전트", "nl": "Subagenten", "pt": "Subagentes", "ru": "Субагенты", "zh-Hans": "子代理", "ar": "الوكلاء الفرعيون", "bn": "সাব-এজেন্ট", "hi": "उप-एजेंट", "id": "Subagen", "vi": "Tác nhân phụ", "ur": "ذیلی ایجنٹ", "mr": "उप-एजंट", "te": "ఉప-ఏజెంట్లు", "ta": "துணை முகவர்கள்", "fa": "زیرعامل‌ها", "pl": "Subagenci", "uk": "Субагенти", "th": "เอเจนต์ย่อย", "ms": "Subejen", "ro": "Subagenți", "el": "Υποπράκτορες", "cs": "Subagenti", "hu": "Alügynökök"
    },
    "mobile.agent.subagents": {
        "en": "Use subagents", "tr": "Alt ajanları kullan", "de": "Subagenten verwenden", "es": "Usar subagentes", "fr": "Utiliser des sous-agents", "it": "Usa subagenti", "ja": "サブエージェントを使用", "ko": "서브에이전트 사용", "nl": "Subagents gebruiken", "pt": "Utilizar subagentes", "ru": "Использовать субагентов", "zh-Hans": "使用子代理", "ar": "استخدام الوكلاء الفرعيين", "bn": "সাব-এজেন্ট ব্যবহার করুন", "hi": "उप-एजेंट का उपयोग करें", "id": "Gunakan subagen", "vi": "Dùng tác nhân phụ", "ur": "ذیلی ایجنٹ استعمال کریں", "mr": "उप-एजंट वापरा", "te": "ఉప-ఏజెంట్లను ఉపయోగించు", "ta": "துணை முகவர்களைப் பயன்படுத்து", "fa": "استفاده از زیرعامل‌ها", "pl": "Używaj subagentów", "uk": "Використовувати субагентів", "th": "ใช้เอเจนต์ย่อย", "ms": "Guna subejen", "ro": "Folosește subagenți", "el": "Χρήση υποπρακτόρων", "cs": "Používat subagenty", "hu": "Alügynökök használata"
    },
    "mobile.agent.subagentsHint": {
        "en": "Hands large code searches to parallel subagents and keeps only their summary in the conversation. Each one is a separate model run; turn off to lower cost.", "tr": "Büyük kod aramalarını paralel alt ajanlara devreder, konuşmaya yalnızca özetleri girer. Her biri ayrı bir model çağrısıdır; maliyeti düşürmek için kapatın.", "de": "Übergibt große Codesuchen an parallele Subagenten und behält nur deren Zusammenfassung im Gespräch. Jeder ist ein eigener Modelllauf; zum Kostensparen ausschalten.", "es": "Delega las búsquedas grandes de código en subagentes paralelos y conserva solo su resumen en la conversación. Cada uno es una ejecución de modelo aparte; desactívalo para reducir el coste.", "fr": "Confie les grandes recherches de code à des sous-agents parallèles et ne garde que leur résumé dans la conversation. Chacun est une exécution de modèle distincte ; désactivez pour réduire le coût.", "it": "Affida le ricerche di codice più ampie a subagenti paralleli e conserva nella conversazione solo il loro riepilogo. Ognuno è un’esecuzione separata del modello; disattiva per ridurre i costi.", "ja": "大規模なコード検索を並列のサブエージェントに任せ、会話には要約だけを残します。それぞれが別のモデル実行になるため、コストを抑えるにはオフにしてください。", "ko": "대규모 코드 검색을 병렬 서브에이전트에 맡기고 대화에는 요약만 남깁니다. 각각 별도의 모델 실행이므로 비용을 줄이려면 끄세요.", "nl": "Draagt grote codezoekopdrachten over aan parallelle subagents en bewaart alleen hun samenvatting in het gesprek. Elke subagent is een aparte modelrun; schakel uit om kosten te besparen.", "pt": "Entrega as pesquisas de código grandes a subagentes paralelos e mantém apenas o resumo na conversa. Cada um é uma execução de modelo separada; desative para reduzir o custo.", "ru": "Передаёт большие поиски по коду параллельным субагентам и оставляет в разговоре только их сводку. Каждый — отдельный запуск модели; отключите, чтобы снизить расходы.", "zh-Hans": "将大型代码搜索交给并行的子代理，并只在对话中保留其摘要。每个子代理都是一次单独的模型运行；关闭可降低成本。", "ar": "يُسند عمليات البحث الكبيرة في الكود إلى وكلاء فرعيين متوازيين ويُبقي ملخصهم فقط في المحادثة. كل واحد منهم تشغيل مستقل للنموذج؛ أوقفه لتقليل التكلفة.", "bn": "বড় কোড অনুসন্ধান সমান্তরাল সাব-এজেন্টদের হাতে দেয় এবং কথোপকথনে শুধু তাদের সারাংশ রাখে। প্রতিটি আলাদা মডেল রান; খরচ কমাতে বন্ধ করুন।", "hi": "बड़ी कोड खोजें समानांतर उप-एजेंटों को सौंपता है और बातचीत में केवल उनका सारांश रखता है। प्रत्येक एक अलग मॉडल रन है; लागत कम करने के लिए बंद करें।", "id": "Menyerahkan pencarian kode yang besar ke subagen paralel dan hanya menyimpan ringkasannya dalam percakapan. Masing-masing adalah proses model terpisah; matikan untuk menekan biaya.", "vi": "Giao các lượt tìm kiếm mã lớn cho tác nhân phụ chạy song song và chỉ giữ lại bản tóm tắt trong cuộc trò chuyện. Mỗi tác nhân là một lượt chạy mô hình riêng; tắt để giảm chi phí.", "ur": "بڑی کوڈ تلاشیں متوازی ذیلی ایجنٹوں کے سپرد کرتا ہے اور گفتگو میں صرف ان کا خلاصہ رکھتا ہے۔ ہر ایک الگ ماڈل رن ہے؛ لاگت کم کرنے کے لیے بند کریں۔", "mr": "मोठे कोड शोध समांतर उप-एजंटांकडे सोपवते आणि संभाषणात फक्त त्यांचा सारांश ठेवते. प्रत्येक एक स्वतंत्र मॉडेल रन आहे; खर्च कमी करण्यासाठी बंद करा.", "te": "పెద్ద కోడ్ శోధనలను సమాంతర ఉప-ఏజెంట్లకు అప్పగించి, సంభాషణలో వాటి సారాంశాన్ని మాత్రమే ఉంచుతుంది. ప్రతి ఒక్కటి ప్రత్యేక మోడల్ రన్; ఖర్చు తగ్గించడానికి ఆఫ్ చేయండి.", "ta": "பெரிய குறியீடு தேடல்களை இணையான துணை முகவர்களிடம் ஒப்படைத்து, உரையாடலில் அவற்றின் சுருக்கத்தை மட்டும் வைத்திருக்கும். ஒவ்வொன்றும் தனி மாடல் இயக்கம்; செலவைக் குறைக்க அணைக்கவும்.", "fa": "جست‌وجوهای بزرگ کد را به زیرعامل‌های موازی می‌سپارد و فقط خلاصهٔ آن‌ها را در گفت‌وگو نگه می‌دارد. هر کدام یک اجرای جداگانهٔ مدل است؛ برای کاهش هزینه خاموش کنید.", "pl": "Przekazuje duże wyszukiwania w kodzie równoległym subagentom i zachowuje w rozmowie tylko ich podsumowanie. Każdy to osobne uruchomienie modelu; wyłącz, aby obniżyć koszt.", "uk": "Передає великі пошуки в коді паралельним субагентам і залишає в розмові лише їхній підсумок. Кожен — окремий запуск моделі; вимкніть, щоб зменшити витрати.", "th": "ส่งต่อการค้นหาโค้ดขนาดใหญ่ให้เอเจนต์ย่อยที่ทำงานคู่ขนาน และเก็บไว้ในบทสนทนาเฉพาะสรุปเท่านั้น แต่ละตัวเป็นการรันโมเดลแยกกัน ปิดเพื่อลดค่าใช้จ่าย", "ms": "Menyerahkan carian kod yang besar kepada subejen selari dan hanya menyimpan ringkasannya dalam perbualan. Setiap satu ialah larian model berasingan; matikan untuk mengurangkan kos.", "ro": "Predă căutările mari în cod unor subagenți paraleli și păstrează în conversație doar rezumatul lor. Fiecare este o rulare separată a modelului; dezactivează pentru a reduce costul.", "el": "Αναθέτει τις μεγάλες αναζητήσεις κώδικα σε παράλληλους υποπράκτορες και κρατά στη συνομιλία μόνο τη σύνοψή τους. Ο καθένας είναι ξεχωριστή εκτέλεση μοντέλου· απενεργοποιήστε για μικρότερο κόστος.", "cs": "Předává rozsáhlá hledání v kódu paralelním subagentům a v konverzaci ponechává jen jejich shrnutí. Každý je samostatný běh modelu; vypnutím snížíte náklady.", "hu": "A nagy kódkereséseket párhuzamos alügynökökre bízza, és a beszélgetésben csak az összefoglalójukat tartja meg. Mindegyik külön modellfuttatás; a költség csökkentéséhez kapcsolja ki."
    },
    "mobile.terminal.runtime": { "en": "Runtime", "tr": "Çalışma ortamı" },
    "mobile.terminal.phoneRuntime": { "en": "Phone", "tr": "Telefon" },
    "mobile.terminal.desktopRuntime": { "en": "Desktop", "tr": "Masaüstü" },
    "mobile.terminal.sessionActive": { "en": "Desktop shell active", "tr": "Masaüstü terminali açık" },
    "mobile.terminal.sessionPaused": { "en": "Desktop shell stopped", "tr": "Masaüstü terminali kapalı" },
    "mobile.terminal.reconnect": { "en": "Reconnect", "tr": "Yeniden bağlan" },
    "mobile.terminal.start": { "en": "Start", "tr": "Başlat" },
    "mobile.terminal.stop": { "en": "Stop", "tr": "Durdur" },
    "mobile.terminal.startFailed": { "en": "The desktop shell could not start.", "tr": "Masaüstü terminali başlatılamadı." },
    "mobile.terminal.approvalHint": { "en": "Approve on the paired desktop, then retry.", "tr": "Eşleşmiş masaüstünde onaylayıp yeniden deneyin." },
    "mobile.preview.open": { "en": "Open", "tr": "Aç" },
    "mobile.preview.port": { "en": "Desktop port", "tr": "Masaüstü portu" },
    "mobile.preview.sharePort": { "en": "Share port", "tr": "Portu paylaş" },
    "mobile.preview.stopSharing": { "en": "Stop sharing", "tr": "Paylaşımı durdur" },
    "mobile.preview.publicHint": { "en": "The URL is public until sharing is stopped.", "tr": "Paylaşım durdurulana kadar URL herkese açıktır." },
    "mobile.preview.approvalHint": { "en": "Approve port sharing on the paired desktop, then retry.", "tr": "Yeniden denemeden önce port paylaşımını eşleşmiş masaüstünde onaylayın." },
    "mobile.preview.error": { "en": "The preview could not be loaded.", "tr": "Önizleme yüklenemedi." },
}

# Keep the Android resource set focused.  The desktop catalog contains a few
# legacy strings with desktop-only escape syntax that AAPT correctly rejects;
# those strings are not part of the mobile UI and must not be shipped there.
MOBILE_KEYS = set(CORE_TRANSLATIONS)
MOBILE_KEYS.update({
    "mobile.pairing.confirm.title", "mobile.pairing.confirm.message",
    "rail.tasks", "rail.memory", "memory.vault.title",
    "memory.trust.prompt", "memory.trust.yes", "memory.trust.no",
    "memory.lesson.prompt", "memory.lesson.keep", "memory.lesson.forget",
    "vault.new", "vault.new.projectEntry", "vault.new.preference", "vault.delete.confirm",
    "vault.entry.keyLanguage", "vault.entry.value", "vault.entry.scope", "vault.entry.everywhere", "vault.entry.thisProject",
    "vault.section.project", "vault.section.profile",
    "project.missing.title", "project.missing.message", "project.missing.locate", "project.missing.readOnly",
    "sidebar.recent", "sidebar.noChats", "sidebar.noRecent", "sidebar.archiveChat",
    "archive.title", "archive.empty", "archive.restore",
    "common.cancel", "common.connect", "common.delete", "common.done", "common.download", "common.refresh", "common.remove", "common.save", "common.start", "common.stop",
    "settings.title", "settings.language", "settings.confirmBeforeExit", "settings.pluginsTitle", "settings.pluginsHint", "settings.reload", "settings.tab.providers", "router.provider",
    "settings.compactTrigger", "settings.compactTrigger.hint", "slash.compact",
    "settings.sandbox", "settings.sandboxOff", "settings.sandboxOn", "settings.sandboxName", "settings.sandboxEnter", "settings.sandboxMerge", "settings.sandboxDiscard", "settings.sandboxOrigin", "settings.sandboxBranch",
    "conversation.files", "conversation.terminal", "conversation.closeTerminal", "conversation.openTerminal", "conversation.queuedMessage", "conversation.you", "conversation.assistant", "conversation.tool",
    "conversation.activity.filesRead", "conversation.activity.filesChanged", "conversation.activity.commandsRun", "conversation.activity.webSearch", "conversation.activity.toolFailed",
    "conversation.activity.filesReading", "conversation.activity.filesChanging", "conversation.activity.commandsRunning", "conversation.activity.webSearching", "conversation.activity.otherRunning",
    "conversation.contextCompactedAuto", "status.contextCompacted", "mobile.activity.details", "mobile.activity.hideDetails",
    "permission.approvalTitle", "permission.allowOnce", "permission.reject", "tool.error",
    "agent.continue", "agent.messageQueued", "agent.steeringQueued", "agent.runningTool", "agent.chooseWorkspace", "agent.chooseModel",
    "conversation.steer", "plan.title", "plan.waitingApproval",
    "loop.minutesLabel", "loop.instructionLabel", "tasks.runNow", "tasks.field.name", "tasks.field.prompt", "tasks.cancel", "tasks.save",
    "modelPicker.model", "modelPicker.selectModel", "modelPicker.noModel", "modelPicker.effort", "modelPicker.effort.default", "modelPicker.effort.none", "modelPicker.effort.low", "modelPicker.effort.medium", "modelPicker.effort.high", "modelPicker.effort.xhigh", "modelPicker.effort.max",
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
    "mobile.agent.newConversation", "mobile.agent.plan", "mobile.agent.approvalRequired", "mobile.agent.allowTool", "mobile.agent.clarification", "mobile.agent.answer", "mobile.agent.ask", "mobile.agent.queue", "mobile.agent.send", "mobile.agent.model", "mobile.agent.close", "mobile.agent.user", "mobile.agent.error",
    "mobile.agent.fast",
    "notifications.title", "notifications.emptyTitle", "notifications.emptyBody", "notifications.markAllRead", "notifications.clearAll", "notifications.itemCount", "notifications.unreadCount", "notifications.question", "notifications.approval", "notifications.actionRequired", "notifications.responseReady", "notifications.operationFailed",
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
    "rail.media", "rail.bots", "rail.marketplace",
    "mobile.market.nativeUnavailable",
    "media.image", "media.video", "media.audio", "media.music", "media.modelMissing", "media.noOutput", "media.generationFailed", "media.videoTimeout", "media.unsupported", "media.unsupportedStatus", "media.openAudio", "media.audio.play", "media.audio.pause",
    "studio.preset.square", "studio.preset.story", "studio.preset.landscape", "studio.preset.thumbnail", "studio.preset.logo", "studio.preset.poster",
    "studio.category.social", "studio.category.uiux", "studio.category.presentation", "studio.category.other", "studio.home.sort.name", "studio.home.starred", "studio.home.star", "studio.home.unstar", "sidebar.sortLastUpdate", "studio.sample.brand", "studio.sample.text",
    "studio.projects", "studio.templates", "studio.music", "studio.library", "studio.home.search", "studio.projectName", "studio.newProject", "studio.rename", "studio.duplicate", "studio.deleteConfirm", "studio.copyOf", "studio.settings.title", "studio.imagePrompt", "studio.generateImage", "studio.export", "studio.music.track.generate",
    "studio.layers", "studio.layers.empty", "studio.layer.text", "studio.layer.shape", "studio.layer.front", "studio.layer.back",
    "studio.template.announcement", "studio.template.story", "studio.template.thumbnail", "studio.template.mobile", "studio.template.slide", "studio.template.logo", "studio.sample.title", "studio.sample.detail",
    "studio.music.new", "studio.music.empty", "studio.music.mix", "studio.music.track", "studio.music.track.empty", "studio.music.trackCount", "studio.music.bpm", "studio.music.key", "studio.music.mute", "studio.music.solo", "studio.music.track.delete",
    "bots.preset.assistant", "bots.preset.researcher", "bots.preset.coder", "bots.new", "bots.edit", "bots.clear", "bots.send", "bots.empty.title", "bots.empty.detail", "bots.placeholder", "bots.name", "bots.instructions", "bots.instructionsHelp", "bots.status.waiting", "bots.error.noReply", "bots.workspace", "bots.workspaceHelp", "bots.agentIn",
    "market.tab.plugins", "market.tab.skills", "market.tab.starters", "market.review.verified", "market.review.pending", "market.permissions", "market.homepage", "market.sourceCode", "market.error.invalidResponse", "market.publish.error.nativeOnly", "market.field.type", "marketplace.empty", "local.installed",
    "market.area.core", "market.area.community", "market.area.experimental", "market.area.communityExperimental", "market.featured", "market.stat.downloads", "market.risk", "market.signed", "market.field.version", "market.field.license", "market.field.source", "library.all", "permission.moreInfo",
    "market.category.coding", "market.category.git", "market.category.qa", "market.category.devops", "market.category.browser", "market.category.web", "market.category.backend", "market.category.mobile", "market.category.models", "market.category.integrations", "market.category.workspace", "market.category.productivity", "market.category.tools", "market.category.design", "market.category.documents", "market.category.authoring", "market.category.community", "market.category.other",
    "market.owned", "market.related", "market.source.private", "market.source.public", "market.unpublish", "market.unpublish.confirmMessage", "market.report", "market.report.title", "market.report.reason", "market.report.details", "market.report.submit", "market.report.malware", "market.report.credentialTheft", "market.report.exfiltration", "market.report.deceptive", "market.report.spam", "market.report.copyright", "sidebar.other",
    "market.account", "market.signIn", "market.signIn.email", "market.signIn.title", "market.email", "market.password", "market.likeSignIn", "market.unlike", "sidebar.signOut", "common.cancel",
})

MOBILE_KEYS.update(MOBILE_NOTICE_KEYS)
MOBILE_KEYS.update(NO_PROJECT_KEYS)
# Copy button on chat code blocks; the macOS catalog already carries the translations.
MOBILE_KEYS.add("conversation.copy")
# Native clarification card; use the existing cross-platform translations.
MOBILE_KEYS.update({"ask.defaultHeader", "ask.other", "ask.customPlaceholder", "ask.next", "ask.skipShort", "ask.submit"})

# English source values for the mobile-only keys. Every non-English value is
# supplied by MOBILE_TRANSLATIONS in translation_catalog.py before generation.
MOBILE_DEFAULTS = {
    "mobile.pairing.confirm.title": "Connect to %@?",
    "mobile.pairing.confirm.message": "Pairing code %@. Only continue if this matches the code shown on your computer.",
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
    "mobile.activity.details": "Show details",
    "mobile.activity.hideDetails": "Hide details",
    "mobile.agent.newConversation": "New conversation",
    "mobile.agent.plan": "Plan mode (read-only)",
    "mobile.agent.approvalRequired": "Approval required",
    "mobile.agent.allowTool": "Allow %@ to run on this phone?",
    "mobile.agent.clarification": "Agent clarification required",
    "mobile.agent.answer": "Answer",
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
    "mobile.market.nativeUnavailable": "Native desktop plugins cannot run on mobile.",
}

MOBILE_DEFAULTS.update(zip(MOBILE_NOTICE_KEYS, NOTICE_ENGLISH))
MOBILE_DEFAULTS.update(zip(NO_PROJECT_KEYS, NO_PROJECT_ENGLISH))


def localized_values(locale: str) -> dict[str, str]:
    if locale != "en":
        missing = sorted(set(MOBILE_DEFAULTS) - set(MOBILE_TRANSLATIONS))
        if missing:
            raise ValueError(f"missing mobile translations: {', '.join(missing)}")
        incomplete = sorted(key for key in MOBILE_DEFAULTS if locale not in MOBILE_TRANSLATIONS[key])
        if incomplete:
            raise ValueError(f"incomplete mobile translations for {locale}: {', '.join(incomplete)}")
        incomplete_core = sorted(
            key for key, translations in CORE_TRANSLATIONS.items()
            if locale not in translations and locale not in MOBILE_TRANSLATIONS.get(key, {})
        )
        if incomplete_core:
            raise ValueError(f"incomplete core mobile translations for {locale}: {', '.join(incomplete_core)}")
    # Some pre-existing macOS locale files predate the newest desktop keys.
    # Unioning with English keeps the mobile catalogs structurally complete;
    # the mobile checker still catches accidental key drift on either platform.
    source_values = read_strings(MAC_RESOURCES / "en.lproj" / "Localizable.strings")
    if locale != "en":
        source = MAC_RESOURCES / f"{locale}.lproj" / "Localizable.strings"
        source_values.update(read_strings(source))
    shared_file = SHARED_RESOURCES / ("Localization.resx" if locale == "en" else f"Localization.{locale}.resx")
    shared_values = {
        item.get("name"): (item.findtext("value") or "")
        for item in ET.parse(shared_file).getroot().findall("data")
        if item.get("name")
    }
    values = {key: source_values.get(key, shared_values.get(key, MOBILE_DEFAULTS.get(key, key))) for key in MOBILE_KEYS}
    if "mobile.agent.fast" in MOBILE_KEYS:
        values["mobile.agent.fast"] = source_values.get("mobile.agent.fast") or {
            "en": "Fast mode",
            "tr": "Hızlı mod",
        }.get(locale, shared_values.get("modelPicker.fast", "Fast mode"))
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
        value = android_format(values[key])
        has_formatter = re.search(r"%(?:\d+\$)?[sd]", value) is not None
        formatted = "" if has_formatter else ' formatted="false"' if "%" in value else ""
        lines.append(f'    <string name="{name}"{formatted}>{android_value(value)}</string>')
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
