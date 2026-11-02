#!/usr/bin/env python3
"""Génère les images du mode démo d'Aurora (films et séries inventés).

Affiches, images de fond, logos et vignettes d'épisodes sont dessinés ici, sans
aucune image protégée : ils servent aux captures d'écran de la documentation.
Usage : python3 scripts/generate-demo-assets.py   (nécessite Pillow)
Sortie : docs/demo-assets/
"""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(__file__), "..")
OUT = os.path.join(ROOT, "docs", "demo-assets")
FONT = os.path.join(ROOT, "App", "Resources", "Fonts", "Manrope-ExtraBold.ttf")

# id, titre, ciel haut, ciel bas, accent, sol, motif
TITLES = [
    ("tt9900001", "La Dernière Aurore", (18, 10, 48), (232, 112, 92), (255, 196, 120), (24, 14, 38), "mountains"),
    ("tt9900002", "Marée Basse", (12, 32, 58), (88, 150, 170), (230, 236, 220), (10, 26, 40), "waves"),
    ("tt9900003", "Le Phare des Brumes", (40, 46, 60), (150, 160, 170), (255, 230, 160), (22, 24, 30), "lighthouse"),
    ("tt9900004", "Neuf Lunes", (16, 18, 52), (70, 60, 140), (240, 236, 210), (20, 16, 40), "moons"),
    ("tt9900005", "Sable Rouge", (120, 40, 20), (240, 150, 70), (255, 220, 150), (90, 30, 18), "dunes"),
    ("tt9900006", "Minuit Pile", (6, 8, 20), (30, 40, 80), (255, 210, 90), (8, 10, 18), "city"),
    ("tt9900007", "Vertige Bleu", (10, 40, 90), (60, 160, 220), (255, 255, 255), (8, 30, 60), "cliff"),
    ("tt9900008", "Le Bal des Lucioles", (14, 30, 24), (40, 90, 70), (250, 240, 140), (8, 20, 14), "fireflies"),
    ("tt9900009", "Orbite Basse", (2, 4, 12), (20, 30, 60), (120, 200, 255), (2, 4, 10), "planet"),
    ("tt9900010", "Les Saisons d'Ana", (60, 40, 70), (230, 180, 160), (255, 240, 220), (40, 28, 40), "sun"),
    ("tt9910001", "Les Cartographes", (20, 40, 40), (120, 170, 150), (255, 220, 140), (14, 30, 28), "mountains"),
    ("tt9910002", "Ligne 7", (14, 14, 24), (70, 50, 90), (255, 120, 120), (10, 10, 16), "city"),
]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def scene(w, h, top, bottom, accent, ground, motif, seed):
    rnd = random.Random(seed)
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=lerp(top, bottom, (y / h) ** 1.2))
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    cx, cy, r = w * rnd.uniform(0.55, 0.75), h * rnd.uniform(0.32, 0.45), min(w, h) * 0.16
    if motif in ("sun", "mountains", "dunes", "cliff", "waves", "lighthouse"):
        g.ellipse([cx - r * 2.4, cy - r * 2.4, cx + r * 2.4, cy + r * 2.4], fill=accent + (60,))
        g.ellipse([cx - r, cy - r, cx + r, cy + r], fill=accent + (235,))
    if motif in ("moons",):
        for i in range(9):
            a = i / 9 * math.pi * 2
            x, y = w * 0.5 + math.cos(a) * w * 0.28, h * 0.4 + math.sin(a) * h * 0.18
            rr = min(w, h) * 0.035
            g.ellipse([x - rr, y - rr, x + rr, y + rr], fill=accent + (220,))
    if motif in ("planet",):
        g.ellipse([cx - r * 1.6, cy - r * 1.6, cx + r * 1.6, cy + r * 1.6], fill=accent + (200,))
        g.ellipse([cx - r * 2.6, cy - r * 0.35, cx + r * 2.6, cy + r * 0.35], outline=(230, 240, 255, 160), width=max(2, w // 300))
    if motif in ("planet", "city", "moons", "fireflies"):
        for _ in range(int(w * h / 9000)):
            x, y = rnd.uniform(0, w), rnd.uniform(0, h * 0.7)
            s = rnd.uniform(0.6, 2.2)
            c = accent if motif == "fireflies" else (255, 255, 255)
            g.ellipse([x - s, y - s, x + s, y + s], fill=c + (int(rnd.uniform(90, 230)),))
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.004))
    img.paste(glow, (0, 0), glow)
    d = ImageDraw.Draw(img)
    base = h * 0.72
    if motif in ("mountains", "cliff", "lighthouse", "sun", "moons", "fireflies"):
        for layer in range(3):
            pts = [(0, h)]
            amp = h * (0.12 - layer * 0.03)
            off = rnd.uniform(0, 6)
            for x in range(0, w + 20, 20):
                y = base + layer * h * 0.06 - abs(math.sin(x / w * 5 + off + layer)) * amp - math.sin(x / w * 13 + off) * amp * 0.25
                pts.append((x, y))
            pts.append((w, h))
            d.polygon(pts, fill=lerp(ground, bottom, 0.35 - layer * 0.15))
    if motif in ("waves", "dunes"):
        for layer in range(4):
            pts = [(0, h)]
            for x in range(0, w + 20, 20):
                pts.append((x, base + layer * h * 0.05 + math.sin(x / w * 9 + layer * 1.7) * h * 0.02))
            pts.append((w, h))
            d.polygon(pts, fill=lerp(ground, bottom, 0.45 - layer * 0.1))
    if motif == "city":
        x = 0
        while x < w:
            bw = rnd.uniform(w * 0.03, w * 0.08)
            bh = rnd.uniform(h * 0.15, h * 0.5)
            d.rectangle([x, h - bh, x + bw, h], fill=ground)
            for wy in range(int(h - bh + 10), int(h - 10), 18):
                for wx in range(int(x + 6), int(x + bw - 6), 14):
                    if rnd.random() < 0.35:
                        d.rectangle([wx, wy, wx + 5, wy + 8], fill=accent)
            x += bw + rnd.uniform(2, 10)
    if motif == "lighthouse":
        lx = w * 0.3
        d.polygon([(lx - w * 0.02, base), (lx + w * 0.02, base), (lx + w * 0.012, base - h * 0.32), (lx - w * 0.012, base - h * 0.32)], fill=(230, 226, 220))
        d.polygon([(lx, base - h * 0.33), (w, base - h * 0.45), (w, base - h * 0.25)], fill=(255, 240, 190))
    vignette = Image.new("L", (w, h), 0)
    ImageDraw.Draw(vignette).ellipse([-w * 0.2, -h * 0.2, w * 1.2, h * 1.2], fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(min(w, h) * 0.12))
    img = Image.composite(img, Image.new("RGB", (w, h), (0, 0, 0)), vignette)
    noise = Image.effect_noise((w, h), 18).convert("RGB")
    return Image.blend(img, noise, 0.04)


def fit_font(draw, text, max_width, start):
    size = start
    while size > 20:
        font = ImageFont.truetype(FONT, size)
        if draw.textlength(text, font=font) <= max_width:
            return font
        size -= 4
    return ImageFont.truetype(FONT, 20)


def logo(title):
    font = ImageFont.truetype(FONT, 120)
    probe = ImageDraw.Draw(Image.new("L", (10, 10)))
    w = int(probe.textlength(title.upper(), font=font)) + 40
    img = Image.new("RGBA", (w, 170), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((20, 18), title.upper(), font=font, fill=(255, 255, 255, 255))
    img.thumbnail((900, 240))
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    for i, (mid, title, top, bottom, accent, ground, motif) in enumerate(TITLES):
        bg = scene(1920, 1080, top, bottom, accent, ground, motif, i)
        bg.save(os.path.join(OUT, f"{mid}-bg.jpg"), quality=82, optimize=True)
        poster = scene(600, 900, top, bottom, accent, ground, motif, i + 100)
        shade = Image.new("L", (600, 900), 0)
        sd = ImageDraw.Draw(shade)
        for y in range(620, 900):
            sd.line([(0, y), (600, y)], fill=int(200 * (y - 620) / 280))
        poster = Image.composite(Image.new("RGB", (600, 900), (0, 0, 0)), poster, shade)
        d = ImageDraw.Draw(poster)
        font = fit_font(d, title.upper(), 540, 64)
        tw = d.textlength(title.upper(), font=font)
        d.text(((600 - tw) / 2, 780), title.upper(), font=font, fill=(255, 255, 255))
        poster.save(os.path.join(OUT, f"{mid}-poster.jpg"), quality=84, optimize=True)
        logo(title).save(os.path.join(OUT, f"{mid}-logo.png"), optimize=True)
        if mid.startswith("tt991"):
            for season in (1, 2):
                for ep in range(1, 9):
                    thumb = scene(640, 360, lerp(top, bottom, 0.1 * ep % 1), bottom, accent, ground, motif, i * 100 + season * 10 + ep)
                    thumb.save(os.path.join(OUT, f"{mid}-s{season}e{ep}.jpg"), quality=78, optimize=True)
    print("images écrites dans", OUT)


if __name__ == "__main__":
    main()
