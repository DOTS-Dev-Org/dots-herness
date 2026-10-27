#!/usr/bin/env python3
"""Render three Turkish HerNess social-video variations with Pillow and FFmpeg."""

from __future__ import annotations

import math
import subprocess
import sys
import wave
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parent
ASSETS = ROOT / "assets"
RENDERS = ROOT / "renders"
AUDIO = ROOT / "audio"
POSTERS = ROOT / "posters"
WIDTH, HEIGHT, FPS, DURATION = 1080, 1920, 30, 15
FRAMES = FPS * DURATION
SAMPLE_RATE = 44_100

FONT_REGULAR = "/System/Library/Fonts/Supplemental/Arial.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_CACHE: dict[tuple[int, bool], ImageFont.FreeTypeFont] = {}


VARIANTS = [
    {
        "id": "01-workspace",
        "name": "HerNess — Tek çalışma alanı",
        "background": "background-glass.png",
        "panel": "home",
        "accent": (86, 157, 255),
        "intro": "Fikrini işe\ndönüştür.",
        "middle": "Kodunu keşfet.\nİncele. Geliştir.",
        "late": "Projeler, botlar,\ngörevler bir arada.",
        "ending": "Yapay zekâ çalışma alanın.",
        "end_chip": "PROJELER  ·  BOTLAR  ·  GÖREVLER",
        "voice": [
            "Fikrini işe dönüştür.",
            "Kodunu keşfet, incele ve geliştir.",
            "Botlar, görevler, tek çalışma alanı.",
            "HerNess. Yapay zekâ çalışma alanın.",
        ],
        "music": [110.00, 164.81, 220.00, 329.63],
        "caption": [
            "Fikrini işe dönüştür.",
            "Kodunu keşfet. İncele. Geliştir.",
            "Botlar, görevler, tek çalışma alanı.",
            "HerNess. Yapay zekâ çalışma alanın.",
        ],
    },
    {
        "id": "02-build",
        "name": "HerNess — Kod geliştirme",
        "background": "background-workspace.png",
        "panel": "home",
        "accent": (68, 183, 255),
        "intro": "Projeni aç.\nOdaklan.",
        "middle": "Kodu keşfet.\nSonraki adımı gör.",
        "late": "İhtiyacına göre\nmodelini seç.",
        "ending": "Fikrinden çalışan çözüme.",
        "end_chip": "ANLA  ·  İNCELE  ·  GELİŞTİR",
        "voice": [
            "Projeni aç. Hemen odaklan.",
            "Kod tabanını keşfet, incele, geliştir.",
            "İhtiyacına göre modeli seç.",
            "HerNess ile üretmeye devam et.",
        ],
        "music": [82.41, 123.47, 185.00, 246.94],
        "caption": [
            "Projeni aç. Hemen odaklan.",
            "Kod tabanını keşfet, incele, geliştir.",
            "İhtiyacına göre modeli seç.",
            "HerNess ile üretmeye devam et.",
        ],
    },
    {
        "id": "03-tasks",
        "name": "HerNess — Planlı görevler",
        "background": "background-orbit.png",
        "panel": "tasks",
        "accent": (168, 126, 255),
        "intro": "Tekrarlayan işleri\nplanla.",
        "middle": "Günlük özetler.\nE-posta takibi.",
        "late": "Görevlerin\naynı yerde.",
        "ending": "Gününe alan aç.",
        "end_chip": "PLANLI GÖREVLER  ·  ÖZET  ·  TAKİP",
        "voice": [
            "Tekrarlayan işleri planla.",
            "Günlük özetler ve e-posta takibi.",
            "Görevlerin HerNess ile otomatik çalışsın.",
            "HerNess. Gününe alan aç.",
        ],
        "music": [87.31, 130.81, 174.61, 261.63],
        "caption": [
            "Tekrarlayan işleri planla.",
            "Günlük özetler ve e-posta takibi.",
            "Görevlerin HerNess ile otomatik çalışsın.",
            "HerNess. Gününe alan aç.",
        ],
    },
]


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    key = (size, bold)
    if key not in FONT_CACHE:
        path = FONT_BOLD if bold else FONT_REGULAR
        FONT_CACHE[key] = ImageFont.truetype(path, size=size)
    return FONT_CACHE[key]


def ease_out(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return 1 - (1 - value) ** 3


def text_width(draw: ImageDraw.ImageDraw, value: str, selected_font: ImageFont.FreeTypeFont) -> float:
    return draw.textlength(value, font=selected_font)


def draw_centered(
    draw: ImageDraw.ImageDraw,
    value: str,
    y: int,
    selected_font: ImageFont.FreeTypeFont,
    fill: tuple[int, ...],
    max_width: int = 920,
    spacing: int = 14,
    align: str = "center",
) -> int:
    lines: list[str] = []
    for paragraph in value.split("\n"):
        words = paragraph.split()
        current = ""
        for word in words:
            attempt = word if not current else f"{current} {word}"
            if text_width(draw, attempt, selected_font) <= max_width or not current:
                current = attempt
            else:
                lines.append(current)
                current = word
        if current:
            lines.append(current)
    final_text = "\n".join(lines)
    draw.multiline_text(
        (WIDTH // 2, y), final_text, font=selected_font, fill=fill,
        anchor="ma", align=align, spacing=spacing, stroke_width=0,
    )
    bbox = draw.multiline_textbbox((WIDTH // 2, y), final_text, font=selected_font, anchor="ma", spacing=spacing)
    return bbox[3] - bbox[1]


def draw_centered_layer(
    frame: Image.Image,
    value: str,
    y: int,
    selected_font: ImageFont.FreeTypeFont,
    fill: tuple[int, ...],
    max_width: int = 920,
    spacing: int = 14,
) -> int:
    alpha = fill[3] if len(fill) > 3 else 255
    layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    opaque = (fill[0], fill[1], fill[2], 255)
    height = draw_centered(draw, value, y, selected_font, opaque, max_width, spacing)
    if alpha != 255:
        layer.putalpha(layer.getchannel("A").point(lambda px: int(px * alpha / 255)))
    frame.alpha_composite(layer)
    return height


def draw_left(draw: ImageDraw.ImageDraw, value: str, xy: tuple[int, int], size: int, fill, bold=False):
    draw.text(xy, value, font=font(size, bold), fill=fill)


def rounded(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def mascot(size: int) -> Image.Image:
    image = Image.open(ASSETS / "herness-mascot.webp").convert("RGBA")
    image.thumbnail((size, size), Image.Resampling.LANCZOS)
    return image


def make_home_panel(logo: Image.Image) -> Image.Image:
    w, h = 960, 680
    panel = Image.new("RGBA", (w, h), (18, 20, 25, 250))
    draw = ImageDraw.Draw(panel)
    rounded(draw, (1, 1, w - 2, h - 2), 30, (19, 22, 28, 248), (112, 132, 168, 190), 2)
    draw.rounded_rectangle((2, 2, w - 2, 64), radius=28, fill=(30, 34, 43, 255))
    draw.rectangle((2, 36, w - 2, 65), fill=(30, 34, 43, 255))
    logo_small = logo.copy()
    logo_small.thumbnail((40, 40), Image.Resampling.LANCZOS)
    panel.alpha_composite(logo_small, (20, 12))
    draw_left(draw, "Dots Harness", (72, 18), 23, (236, 239, 246), True)
    draw.ellipse((w - 42, 24, w - 30, 36), fill=(94, 166, 255, 255))

    draw.rounded_rectangle((2, 65, 83, h - 2), radius=0, fill=(23, 26, 32, 255))
    nav = [("H", "Anasayfa"), ("M", "Media"), ("G", "Görevler"), ("B", "Botlar"), ("A", "Market"), ("H", "Hafıza")]
    yy = 94
    for idx, (glyph, label) in enumerate(nav):
        selected = idx == 0
        if selected:
            rounded(draw, (12, yy - 6, 73, yy + 45), 13, (48, 60, 78, 255))
        draw.text((42, yy), glyph, font=font(18, True), fill=(112, 174, 255) if selected else (145, 153, 168), anchor="mt")
        draw.text((42, yy + 26), label, font=font(10, True), fill=(219, 224, 233) if selected else (134, 141, 154), anchor="mt")
        yy += 72

    draw_left(draw, "DOTS HerNess üzerinde ne yapalım?", (120, 97), 29, (242, 244, 248), True)
    icon = logo.copy()
    icon.thumbnail((104, 104), Image.Resampling.LANCZOS)
    panel.alpha_composite(icon, ((w - 83 - icon.width) // 2 + 40, 146))
    draw.text(((w + 83) // 2, 259), "DOTS HerNess üzerinde ne yapalım?", font=font(22, True), fill=(225, 229, 237), anchor="mt")
    draw.text(((w + 83) // 2, 293), "Projende başla, fikrini adım adım hayata geçir.", font=font(15), fill=(153, 161, 176), anchor="mt")

    actions = [
        ("Kod tabanını keşfet", "Projenin nasıl bir araya geldiğini anla", (70, 145, 255)),
        ("Bir şey geliştir", "Özellik, uygulama veya araç ekle", (151, 116, 255)),
        ("Kodu incele", "Geri bildirim ve somut öneriler al", (62, 186, 235)),
        ("Hata düzelt", "Sorunları bul ve çöz", (255, 153, 94)),
    ]
    card_w, card_h = 382, 112
    for idx, (title, subtitle, color) in enumerate(actions):
        col, row = idx % 2, idx // 2
        x, y = 121 + col * 400, 351 + row * 132
        rounded(draw, (x, y, x + card_w, y + card_h), 18, (34, 38, 47, 255), (66, 74, 88, 255), 1)
        rounded(draw, (x + 17, y + 24, x + 58, y + 65), 13, (*color, 45))
        draw.ellipse((x + 30, y + 37, x + 44, y + 51), fill=(*color, 255))
        draw_left(draw, title, (x + 75, y + 21), 19, (235, 238, 244), True)
        draw_left(draw, subtitle, (x + 75, y + 53), 13, (161, 169, 183))
    return panel


def make_tasks_panel(logo: Image.Image) -> Image.Image:
    w, h = 960, 680
    panel = Image.new("RGBA", (w, h), (18, 20, 25, 250))
    draw = ImageDraw.Draw(panel)
    rounded(draw, (1, 1, w - 2, h - 2), 30, (19, 22, 28, 248), (112, 132, 168, 190), 2)
    draw.rounded_rectangle((2, 2, w - 2, 64), radius=28, fill=(30, 34, 43, 255))
    draw.rectangle((2, 36, w - 2, 65), fill=(30, 34, 43, 255))
    logo_small = logo.copy()
    logo_small.thumbnail((40, 40), Image.Resampling.LANCZOS)
    panel.alpha_composite(logo_small, (20, 12))
    draw_left(draw, "Görevler", (72, 18), 23, (236, 239, 246), True)
    rounded(draw, (w - 179, 14, w - 20, 51), 12, (56, 125, 237, 255))
    draw.text((w - 100, 32), "+  Yeni görev", font=font(15, True), fill=(255, 255, 255), anchor="mm")

    icon = logo.copy()
    icon.thumbnail((88, 88), Image.Resampling.LANCZOS)
    panel.alpha_composite(icon, ((w - icon.width) // 2, 79))
    draw.text((w // 2, 171), "Bir görev planla", font=font(24, True), fill=(235, 238, 244), anchor="mt")
    draw.text((w // 2, 206), "HerNess yinelenen işleri senin yerine çalıştırır.", font=font(15), fill=(157, 165, 180), anchor="mt")
    draw_left(draw, "Öneriler", (42, 257), 17, (184, 191, 204), True)

    rows = [
        ("Günlük özet", "Son çalışmaları ve öncelikleri özetle.", "Hafta içi 08:00", (246, 181, 91)),
        ("E-posta takibi", "Önemli e-postaları kontrol et.", "Hafta içi 09:00", (74, 155, 242)),
        ("Hafta sonu okuması", "İlgine uygun bir yazı bul.", "Haftalık", (190, 97, 220)),
        ("Haftalık inceleme", "Kısa bir durum güncellemesi hazırla.", "Cuma 16:00", (82, 180, 151)),
    ]
    for idx, (title, subtitle, schedule, color) in enumerate(rows):
        col, row = idx % 2, idx // 2
        x, y = 30 + col * 455, 291 + row * 164
        card_w, card_h = 430, 145
        rounded(draw, (x, y, x + card_w, y + card_h), 18, (27, 31, 39, 255), (64, 73, 88, 255), 1)
        rounded(draw, (x + 18, y + 22, x + 66, y + 70), 15, (*color, 45))
        draw.ellipse((x + 34, y + 38, x + 50, y + 54), fill=(*color, 255))
        draw_left(draw, title, (x + 83, y + 19), 18, (235, 238, 244), True)
        draw_left(draw, subtitle, (x + 83, y + 54), 13, (165, 173, 187))
        draw_left(draw, schedule, (x + 83, y + 98), 12, (129, 140, 156))
    return panel


def background_for(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGB")
    fitted = ImageOps.fit(image, (WIDTH, HEIGHT), method=Image.Resampling.LANCZOS, centering=(0.5, 0.52))
    enlarged = ImageOps.fit(image, (int(WIDTH * 1.045), int(HEIGHT * 1.045)), method=Image.Resampling.LANCZOS, centering=(0.5, 0.52))
    return enlarged


def dark_overlay() -> Image.Image:
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (7, 10, 18, 0))
    draw = ImageDraw.Draw(overlay)
    for y in range(HEIGHT):
        p = y / HEIGHT
        alpha = int(30 + 28 * max(0, 1 - abs(p - 0.45) / 0.55) + 36 * max(0, (p - 0.73) / 0.27))
        draw.line((0, y, WIDTH, y), fill=(6, 8, 16, min(112, alpha)))
    return overlay


def make_ui_layers(panel: Image.Image, size: tuple[int, int]) -> tuple[Image.Image, Image.Image]:
    card = panel.resize(size, Image.Resampling.LANCZOS)
    shadow = Image.new("RGBA", (size[0] + 70, size[1] + 70), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((35, 35, 35 + size[0], 35 + size[1]), radius=34, fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    return card, shadow


def synth_music(path: Path, chord: list[float], version: int) -> None:
    beat = 60 / (88 + version * 5)
    duration = DURATION + 0.2
    total = int(SAMPLE_RATE * duration)
    notes = chord
    pulse_freq = [440.0, 493.88, 392.0][version - 1]
    with wave.open(str(path), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for n in range(total):
            t = n / SAMPLE_RATE
            beat_phase = t % beat
            chord_phase = t % (beat * 4)
            attack = min(1.0, t / 0.75)
            release = min(1.0, max(0.0, (duration - t) / 1.25))
            pad = 0.0
            for i, freq in enumerate(notes):
                phase = (0.3 if i % 2 else 0.0) + i * 0.22
                wobble = 1 + 0.002 * math.sin(2 * math.pi * 0.12 * t + phase)
                pad += math.sin(2 * math.pi * freq * wobble * t + phase) / (1.4 + i * 0.4)
                pad += 0.22 * math.sin(2 * math.pi * freq * 2 * t + phase) / (1.5 + i)
            pad *= 0.036 * attack * release
            bell_env = math.exp(-chord_phase * 1.8)
            bell = 0.022 * bell_env * math.sin(2 * math.pi * pulse_freq * t)
            kick_env = math.exp(-beat_phase * 20)
            kick = 0.055 * kick_env * math.sin(2 * math.pi * (64 - 20 * min(1, beat_phase * 8)) * beat_phase)
            tick_env = math.exp(-beat_phase * 55)
            tick = 0.008 * tick_env * math.sin(2 * math.pi * 1850 * t)
            sample = (pad + bell + kick + tick) * 0.82
            left = max(-0.92, min(0.92, sample * (0.96 + 0.04 * math.sin(t * 0.35))))
            right = max(-0.92, min(0.92, sample * (0.96 - 0.04 * math.sin(t * 0.35))))
            frames.extend(int(left * 32767).to_bytes(2, "little", signed=True))
            frames.extend(int(right * 32767).to_bytes(2, "little", signed=True))
        out.writeframes(frames)


def make_audio(variant: dict, index: int) -> Path:
    AUDIO.mkdir(parents=True, exist_ok=True)
    line_files: list[Path] = []
    for line_index, line in enumerate(variant["voice"]):
        stem = AUDIO / f"{variant['id']}-voice-{line_index + 1}.aiff"
        subprocess.run(
            ["/usr/bin/say", "-v", "Yelda", "-r", "176", "-o", str(stem), line],
            check=True,
        )
        line_files.append(stem)

    music = AUDIO / f"{variant['id']}-music.wav"
    synth_music(music, variant["music"], index)
    mixed = AUDIO / f"{variant['id']}-mix.wav"
    inputs: list[str] = []
    filters: list[str] = []
    starts = [220, 3650, 7350, 11150]
    for i, path in enumerate(line_files):
        inputs.extend(["-i", str(path)])
        filters.append(f"[{i}:a]aresample={SAMPLE_RATE},aformat=channel_layouts=stereo,volume=1.18,adelay={starts[i]}|{starts[i]}[v{i}]")
    music_index = len(line_files)
    inputs.extend(["-i", str(music)])
    filters.append(f"[{music_index}:a]volume=0.23,afade=t=in:st=0:d=0.8,afade=t=out:st=13.6:d=1.25[m]")
    stream_inputs = "".join(f"[v{i}]" for i in range(len(line_files))) + "[m]"
    filters.append(
        f"{stream_inputs}amix=inputs={len(line_files) + 1}:duration=longest:dropout_transition=0:weights='1 1 1 1 0.35':normalize=0,alimiter=limit=0.92,atrim=0:{DURATION}[out]"
    )
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *inputs,
        "-filter_complex", ";".join(filters), "-map", "[out]", "-t", str(DURATION),
        "-c:a", "pcm_s16le", str(mixed),
    ]
    subprocess.run(command, check=True)
    return mixed


def draw_chip(frame: Image.Image, text: str, center_y: int, accent, opacity: int = 255) -> None:
    selected_font = font(23, True)
    width = int(selected_font.getlength(text)) + 56
    x = (WIDTH - width) // 2
    layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    rounded(draw, (x, center_y, x + width, center_y + 54), 27, (*accent, 52), (*accent, 255), 2)
    draw.text((WIDTH // 2, center_y + 27), text, font=selected_font, fill=(246, 248, 255, 255), anchor="mm")
    if opacity != 255:
        layer.putalpha(layer.getchannel("A").point(lambda px: int(px * opacity / 255)))
    frame.alpha_composite(layer)


def add_ui(frame: Image.Image, ui_card: Image.Image, ui_shadow: Image.Image, t: float) -> None:
    start, stop = 2.55, 11.72
    if t < start or t > stop:
        return
    opacity = min(ease_out((t - start) / 0.55), max(0.0, (stop - t) / 0.48), 1.0)
    if opacity <= 0:
        return
    slide = 54 * (1 - ease_out((t - start) / 0.65))
    x = (WIDTH - ui_card.width) // 2
    y = int(700 + slide)
    sh = ui_shadow.copy()
    shadow_alpha = sh.getchannel("A").point(lambda a: int(a * opacity * 0.72))
    sh.putalpha(shadow_alpha)
    frame.alpha_composite(sh, (x - 35, y - 18))
    card = ui_card.copy()
    alpha = card.getchannel("A").point(lambda a: int(a * opacity))
    card.putalpha(alpha)
    frame.alpha_composite(card, (x, y))


def scene_text(variant: dict, t: float) -> tuple[str, str]:
    if t < 3.55:
        return variant["intro"], variant["caption"][0]
    if t < 7.45:
        return variant["middle"], variant["caption"][1]
    if t < 11.35:
        return variant["late"], variant["caption"][2]
    return "", variant["caption"][3]


def render_frame(variant: dict, base_bg: Image.Image, dark: Image.Image, logo: Image.Image, ui_card: Image.Image, ui_shadow: Image.Image, frame_no: int) -> Image.Image:
    t = frame_no / FPS
    max_x, max_y = base_bg.width - WIDTH, base_bg.height - HEIGHT
    drift_x = int(max_x * (0.5 + 0.16 * math.sin(t * 0.22)))
    drift_y = int(max_y * (0.45 + 0.15 * math.sin(t * 0.17 + 0.4)))
    crop = base_bg.crop((drift_x, drift_y, drift_x + WIDTH, drift_y + HEIGHT)).convert("RGBA")
    frame = Image.alpha_composite(crop, dark)

    # Slow-moving accent glows keep the background alive without competing with captions.
    draw = ImageDraw.Draw(frame)
    accent = variant["accent"]
    glow_x = int(WIDTH * (0.16 + 0.68 * (0.5 + 0.5 * math.sin(t * 0.25 + 1.2))))
    if t < 11.5:
        draw.ellipse((glow_x - 5, 585, glow_x + 5, 595), fill=(*accent, 255))
        draw.line((78, 613, 1002, 613), fill=(24, 39, 68, 255), width=2)

    if t < 11.5:
        logo_small = logo.copy()
        logo_small.thumbnail((74, 74), Image.Resampling.LANCZOS)
        frame.alpha_composite(logo_small, (79, 75))
        brand_draw = ImageDraw.Draw(frame)
        brand_draw.text((172, 94), "HerNess", font=font(36, True), fill=(250, 250, 253, 255))
        brand_draw.text((174, 137), "YAPAY ZEKÂ ÇALIŞMA ALANI", font=font(14, True), fill=(*accent, 245))

        headline, caption = scene_text(variant, t)
        if t < 3.55:
            phase, span = t, 3.55
        elif t < 7.45:
            phase, span = t - 3.55, 3.9
        else:
            phase, span = t - 7.45, 3.9
        fade = min(1.0, phase / 0.24, (span - phase) / 0.18)
        opacity = int(255 * max(0.0, fade))
        lift = int((1 - ease_out(min(1, phase / 0.38))) * 26)
        title_y = 252 + lift
        draw_centered_layer(frame, headline, title_y, font(83, True), (248, 249, 252, opacity), max_width=950, spacing=13)

        add_ui(frame, ui_card, ui_shadow, t)
        if 7.5 <= t < 11.5:
            mini = "PROJELER  ·  BOTLAR  ·  GÖREVLER" if variant["panel"] == "home" else "GÜNLÜK ÖZET  ·  TAKİP  ·  PLAN"
            draw_chip(frame, mini, 1460, accent, int(255 * min(1.0, (t - 7.5) / 0.35)))
    else:
        outro_alpha = int(255 * min(1.0, (t - 11.35) / 0.35))
        logo_big = logo.copy()
        logo_big.thumbnail((320, 320), Image.Resampling.LANCZOS)
        a = logo_big.getchannel("A").point(lambda px: int(px * (outro_alpha / 255)))
        logo_big.putalpha(a)
        frame.alpha_composite(logo_big, ((WIDTH - logo_big.width) // 2, 465))
        draw = ImageDraw.Draw(frame)
        draw_centered_layer(frame, "HerNess", 830, font(104, True), (251, 251, 253, outro_alpha), max_width=980)
        draw_centered_layer(frame, variant["ending"], 1000, font(42, True), (*accent, outro_alpha), max_width=950, spacing=12)
        draw_chip(frame, variant["end_chip"], 1195, accent, outro_alpha)
        draw_centered_layer(frame, "DOTS", 1740, font(22, True), (219, 224, 236, int(outro_alpha * 0.72)), max_width=500)

    # Soft closing vignette and safe-area rails are part of the shared brand finish.
    if t > 14.3:
        fade = max(0, min(1, (15 - t) / 0.7))
        shade = Image.new("RGBA", (WIDTH, HEIGHT), (5, 7, 13, int(190 * (1 - fade))))
        frame = Image.alpha_composite(frame, shade)
    return frame.convert("RGB")


def write_srt(variant: dict) -> None:
    starts = [(0.22, 3.45), (3.65, 7.25), (7.35, 11.1), (11.2, 14.75)]
    def stamp(seconds: float) -> str:
        whole = int(seconds)
        millis = int(round((seconds - whole) * 1000))
        if millis == 1000:
            whole += 1
            millis = 0
        return f"00:00:{whole:02d},{millis:03d}"
    rows = []
    for i, (begin, end) in enumerate(starts):
        rows.extend([str(i + 1), f"{stamp(begin)} --> {stamp(end)}", variant["caption"][i], ""])
    (ROOT / f"{variant['id']}.srt").write_text("\n".join(rows), encoding="utf-8")


def render_video(variant: dict, index: int, logo: Image.Image, home_panel: Image.Image, task_panel: Image.Image, dark: Image.Image) -> None:
    bg = background_for(ASSETS / variant["background"])
    panel = task_panel if variant["panel"] == "tasks" else home_panel
    ui_size = (948, int(panel.height * 948 / panel.width))
    ui_card, ui_shadow = make_ui_layers(panel, ui_size)
    mixed_audio = make_audio(variant, index)
    output = RENDERS / f"{variant['id']}.mp4"
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{WIDTH}x{HEIGHT}",
        "-framerate", str(FPS), "-i", "pipe:0", "-i", str(mixed_audio),
        "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264", "-preset", "fast",
        "-crf", "19", "-pix_fmt", "yuv420p", "-r", str(FPS), "-c:a", "aac",
        "-b:a", "192k", "-t", str(DURATION), "-movflags", "+faststart", str(output),
    ]
    encoder = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    assert encoder.stdin is not None
    for frame_no in range(FRAMES):
        image = render_frame(variant, bg, dark, logo, ui_card, ui_shadow, frame_no)
        encoder.stdin.write(image.tobytes())
        if frame_no % (FPS * 3) == 0:
            print(f"{variant['id']}: {frame_no // FPS:02d}s / {DURATION}s", flush=True)
        if frame_no == 390:
            POSTERS.mkdir(parents=True, exist_ok=True)
            image.save(POSTERS / f"{variant['id']}.jpg", quality=92, optimize=True)
    encoder.stdin.close()
    error = encoder.stderr.read().decode("utf-8", "replace") if encoder.stderr else ""
    code = encoder.wait()
    if code != 0:
        raise RuntimeError(f"FFmpeg failed for {variant['id']}: {error}")
    write_srt(variant)
    print(f"Rendered {output}", flush=True)


def main() -> int:
    for path in (ASSETS / "herness-mascot.webp", *(ASSETS / v["background"] for v in VARIANTS)):
        if not path.exists():
            raise FileNotFoundError(path)
    RENDERS.mkdir(parents=True, exist_ok=True)
    logo = mascot(340)
    home_panel = make_home_panel(logo)
    task_panel = make_tasks_panel(logo)
    dark = dark_overlay()
    for index, variant in enumerate(VARIANTS, 1):
        render_video(variant, index, logo, home_panel, task_panel, dark)
    print("All three 1080x1920, 30 fps MP4s are ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit("Rendering stopped because FFmpeg closed its input pipe.")
