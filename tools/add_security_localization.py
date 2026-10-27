#!/usr/bin/env python3
"""One-off: add the remote-control and mobile pairing copy to the catalogs."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "tools" / "ui_catalog.py"
CATALOG = ROOT / "tools" / "translation_catalog.py"

REMOTE_ENABLE = (
    "Allow remote control",
    "Uzaktan denetime izin ver|Fernsteuerung erlauben|Permitir el control remoto|Autoriser le contrôle à distance|Consenti il controllo remoto|"
    "リモート制御を許可|원격 제어 허용|Afstandsbediening toestaan|Permitir controlo remoto|Разрешить удалённое управление|允许远程控制|"
    "السماح بالتحكم عن بُعد|রিমোট নিয়ন্ত্রণের অনুমতি দিন|रिमोट नियंत्रण की अनुमति दें|Izinkan kendali jarak jauh|"
    "Cho phép điều khiển từ xa|ریموٹ کنٹرول کی اجازت دیں|रिमोट कंट्रोलला परवानगी द्या|రిమోట్ కంట్రోల్‌కు అనుమతించు|"
    "ரிமோட் கட்டுப்பாட்டை அனுமதிக்கவும்|اجازهٔ کنترل از راه دور|Zezwól na zdalne sterowanie|Дозволити дистанційне керування|"
    "อนุญาตให้ควบคุมจากระยะไกล|Benarkan kawalan jauh|Permite controlul de la distanță|Επίτρεψη απομακρυσμένο έλεγχο|"
    "Povolit vzdálené ovládání|Távoli vezérlés engedélyezése",
)
REMOTE_SHARE_LAN = (
    "Share with the local network",
    "Yerel ağ ile paylaş|Mit dem lokalen Netzwerk teilen|Compartir con la red local|Partager avec le réseau local|"
    "Condividi con la rete locale|ローカルネットワークと共有|로컬 네트워크와 공유|Delen met het lokale netwerk|"
    "Partilhar com a rede local|Доступ в локальной сети|与本地网络共享|المشاركة مع الشبكة المحلية|"
    "স্থানীয় নেটওয়ার্কের সঙ্গে ভাগ করুন|स्थानीय नेटवर्क के साथ साझा करें|Bagikan dengan jaringan lokal|"
    "Chia sẻ với mạng nội bộ|مقامی نیٹ ورک کے ساتھ شیئر کریں|स्थानिक नेटवर्कसोबत सामायिक करा|"
    "స్థానిక నెట్‌వర్క్‌తో పంచుకోండి|உள்ளூர் நெட்வர்க்குடன் பகிர்ந்துகொள்ளவும்|هم‌رسانی با شبکهٔ محلی|"
    "Udostępnij w sieci lokalnej|Поділитися в локальній мережі|แชร์กับเครือข่ายท้องถิ่น|"
    "Kongsi dengan rangkaian tempatan|Partajează cu rețeaua locală|Κοινή χρήση με το τοπικό δίκτυο|"
    "Sdílet v místní síti|Megosztás a helyi hálózattal",
)
REMOTE_ENABLE_HINT = (
    "The remote gateway is off. Turn it on to pair a phone.",
    "Uzak ağ geçidi kapalı. Bir telefon eşlemek için açın.|Das Remote-Gateway ist aus. Schalte es ein, um ein Telefon zu koppeln.|"
    "La pasarela remota está desactivada. Actívala para vincular un teléfono.|La passerelle distante est désactivée. Activez-la pour coupler un téléphone.|"
    "Il gateway remoto è spento. Accendilo per collegare un telefono.|リモートゲートウェイはオフです。電話をペアリングするにはオンにしてください。|"
    "원격 게이트웨이가 꺼져 있습니다. 휴대폰을 연결하려면 켜세요.|De externe gateway staat uit. Zet hem aan om een telefoon te koppelen.|"
    "O gateway remoto está desligado. Ligue-o para emparelhar um telefone.|Удалённый шлюз выключен. Включите его, чтобы связать телефон.|"
    "远程网关已关闭。开启后即可配对手机。|البوابة البعيدة متوقفة. شغّلها لإقران هاتف.|"
    "রিমোট গেটওয়ে বন্ধ আছে। ফোন জোড়া লাগাতে চালু করুন।|रिमोट गेटवे बंद है। फ़ोन जोड़ने के लिए इसे चालू करें।|"
    "Gateway remote mati. Aktifkan untuk memasangkan ponsel.|Cổng từ xa đang tắt. Bật lên để ghép nối điện thoại.|"
    "ریموٹ گیٹ وے بند ہے۔ فون جوڑنے کے لیے اسے آن کریں۔|रिमोट गेटवे बंद आहे. फोन जोडण्यासाठी सुरू करा.|"
    "రిమోట్ గేట్‌వే ఆఫ్‌లో ఉంది. ఫోన్‌ను జత చేయడానికి దాన్ని ఆన్ చేయండి.|"
    "ரிமோட் கேட்வே ஆஃப் உள்ளது. தொலைபேசியை இணைக்க அதை இயக்கவும்.|دروازهٔ دوردست خاموش است. برای جفت‌کردن گوشی آن را روشن کنید.|"
    "Zdalna brama jest wyłączona. Włącz ją, aby sparować telefon.|Віддалений шлюз вимкнено. Увімкніть його, щоб зв'язати телефон.|"
    "เกตเวย์ระยะไกลปิดอยู่ เปิดเพื่อจับคู่โทรศัพท์|Gateway jarak jauh dimatikan. Aktifkannya untuk memasangkan telefon.|"
    "Poarta la distanță este oprită. Pornește-o pentru a împerechea un telefon.|Η απομακρυσμένη πύλη είναι κλειστή. Ενεργοποιήστε την για να αντιστοιχίσετε ένα τηλέφωνο.|"
    "Vzdálená brána je vypnutá. Zapněte ji ke spárování telefonu.|A távoli átjáró ki van kapcsolva. Kapcsold be a telefon párosításához.",
)
PAIR_TITLE = (
    "Connect to %@?",
    "%@ adresine bağlanılsın mı?|Mit %@ verbinden?|¿Conectar con %@?|Se connecter à %@ ?|Connettersi a %@?|"
    "%@ に接続しますか？|%@에 연결할까요?|Verbinden met %@?|Ligar a %@?|Подключиться к %@?|连接到 %@？|"
    "هل تريد الاتصال بـ %@؟|%@ এর সঙ্গে সংযোগ করবেন?|%@ से कनेक्ट करें?|Hubungkan ke %@?|Kết nối với %@?|"
    "%@ سے مربوط کریں؟|%@ सोबत जोडायचे?|%@ కు కనెక్ట్ అయ్యాలా?|%@ உடன் இணைக்கவுமா?|به %@ متصل می‌شوید؟|"
    "Połączyć z %@?|Підключитися до %@?|เชื่อมต่อกับ %@?|Sambungkan dengan %@?|Conectare la %@?|Σύνδεση στο %@;|"
    "Připojit k %@?|Kapcsolódás a(z) %@ címhez?",
)
PAIR_MESSAGE = (
    "Pairing code %@. Only continue if this matches the code shown on your computer.",
    "Eşleştirme kodu %@. Yalnızca bilgisayarınızda gösterilen kodla eşleşiyorsa devam edin.|"
    "Kopplungscode %@. Fahren Sie nur fort, wenn er mit dem auf Ihrem Computer angezeigten Code übereinstimmt.|"
    "Código de vinculación %@. Continúa solo si coincide con el código que aparece en tu ordenador.|"
    "Code d'appairage %@. Continuez uniquement s'il correspond au code affiché sur votre ordinateur.|"
    "Codice di abbinamento %@. Continua solo se corrisponde al codice mostrato sul computer.|"
    "ペアリングコード %@。コンピューターに表示されているコードと一致する場合のみ続行してください。|"
    "페어링 코드 %@. 컴퓨터에 표시된 코드와 일치할 때만 계속하세요.|"
    "Koppelingscode %@. Ga alleen verder als deze overeenkomt met de code op je computer.|"
    "Código de emparelhamento %@. Só continue se corresponder ao código apresentado no seu computador.|"
    "Код сопряжения %@. Продолжайте, только если он совпадает с кодом на вашем компьютере.|"
    "配对码 %@。仅当它与电脑上显示的代码一致时才继续。|رمز الإقران %@. تابع فقط إذا كان مطابقًا للرمز المعروض على حاسوبك.|"
    "পেয়ারিং কোড %@। কম্পিউটারে দেখানো কোডের সঙ্গে মিললেই কেবল এগিয়ে যান।|"
    "पेयरिंग कोड %@। तभी आगे बढ़ें जब यह आपके कंप्यूटर पर दिखाए गए कोड से मेल खाता हो।|"
    "Kode pemasangan %@. Lanjutkan hanya jika cocok dengan kode yang ditampilkan di komputer Anda.|"
    "Mã ghép nối %@. Chỉ tiếp tục nếu khớp với mã hiển thị trên máy tính của bạn.|"
    "پیئرنگ کوڈ %@۔ آگے بڑھیں صرف اس صورت میں جب یہ آپ کے کمپیوٹر پر دکھایا گیا کوڈ ہے۔|"
    "पेअरिंग कोड %@. पुढे जा फक्त तेव्हाच जर तो तुमच्या संगणकावर दाखवलेल्या कोडशी जुळत असेल.|"
    "జతచేసే కోడ్ %@. మీ కంప్యూటర్‌పై చూపిన కోడ్‌తో సరిపోలితే మాత్రమే కొనసాగండి.|"
    "இணைக்கும் குறியீடு %@. உங்கள் கணினியில் காட்டப்படும் குறியீட்டுடன் பொருந்தும்போதே தொடரவும்.|"
    "کد جفت‌سازی %@. تنها در صورتی ادامه دهید که با کد نمایش‌داده‌شده روی رایانه شما یکسان باشد.|"
    "Kod parowania %@. Kontynuuj tylko wtedy, gdy odpowiada kodowi pokazanemu na komputerze.|"
    "Код сполучення %@. Продовжуйте, лише якщо він збігається з кодом, показаним на вашому комп'ютері.|"
    "รหัสการจับคู่ %@. เฉพาะเมื่อตรงกับรหัสที่แสดงบนคอมพิวเตอร์ของคุณเท่านั้น|"
    "Kod pasangan %@. Teruskan hanya jika ia sepadan dengan kod yang dipaparkan pada komputer anda.|"
    "Cod de asociere %@. Continuați numai dacă se potrivește cu codul afișat pe computerul dvs.|"
    "Κωδικός σύζευξης %@. Συνεχίστε μόνο αν ταιριάζει με τον κωδικό που εμφανίζεται στον υπολογιστή σας.|"
    "Kód párování %@. Pokračujte pouze tehdy, pokud odpovídá kódu zobrazenému na vašem počítači.|"
    "Párosító kód: %@. Csak akkor folytassa, ha megegyezik a számítógépén látható kóddal.",
)


def insert_after(text: str, anchor: str, block: str) -> str:
    index = text.index(anchor)
    end = text.index("\n", index) + 1
    return text[:end] + block + text[end:]


ui = UI.read_text(encoding="utf-8")
if '"remote.enable"' not in ui:
    entries = ""
    for key, value in (
        ("remote.enable", REMOTE_ENABLE),
        ("remote.shareLan", REMOTE_SHARE_LAN),
        ("remote.enableHint", REMOTE_ENABLE_HINT),
    ):
        english, packed = value
        entries += f'    "{key}": ("{english}", "{packed}"),\n'
    ui = insert_after(ui, '    "remote.tunnel.disable": (', entries)
    ui = ui.replace(
        '    "remote.scan", "remote.lan", "remote.code", "remote.expires", "remote.newCode", "remote.copyLink", "remote.pairingLink", "remote.tunnel.enable", "remote.hint",',
        '    "remote.scan", "remote.lan", "remote.code", "remote.expires", "remote.newCode", "remote.copyLink", "remote.pairingLink", "remote.tunnel.enable", "remote.hint",\n'
        '    "remote.enable", "remote.shareLan", "remote.enableHint",',
    )
    UI.write_text(ui, encoding="utf-8")
    print("ui_catalog.py updated")

catalog = CATALOG.read_text(encoding="utf-8")
if '"mobile.pairing.confirm.title"' not in catalog:
    block = (
        "\nMOBILE_TRANSLATIONS.update(rows({\n"
        f'    "mobile.pairing.confirm.title": "{PAIR_TITLE[0]}",\n'
        f'    "mobile.pairing.confirm.message": "{PAIR_MESSAGE[0]}",\n'
        "}))\n"
    )
    # The packed translations live beside the English value.
    block = block.replace(
        f'"{PAIR_TITLE[0]}"',
        f'"{PAIR_TITLE[0]}", "{PAIR_TITLE[1]}"',
    ).replace(
        f'"{PAIR_MESSAGE[0]}"',
        f'"{PAIR_MESSAGE[0]}", "{PAIR_MESSAGE[1]}"',
    )
    catalog = insert_after(catalog, "MOBILE_TRANSLATIONS = rows({", "\n" + block)
    CATALOG.write_text(catalog, encoding="utf-8")
    print("translation_catalog.py updated")
