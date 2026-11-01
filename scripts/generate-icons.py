#!/usr/bin/env python3
"""Génère les icônes tvOS en couches (Back/Middle/Front) et les images Top Shelf d'Aurora.

Icône : un A plein sans barre, dessiné comme un sommet, devant la lueur de l'aube.

Usage : python3 scripts/generate-icons.py  (nécessite Pillow)
Les fichiers sont écrits dans App/Resources/Assets.xcassets.
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Assets.xcassets")
FONT = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Fonts", "Manrope-ExtraBold.ttf")
INFO = {"author": "xcode", "version": 1}
NIGHT = (20, 10, 32)
PEACH, ROSE, VIOLET = (255, 178, 122), (226, 102, 138), (42, 19, 64)
AMBER = PEACH  # couleur d'accent de l'app
SS = 4  # suréchantillonnage pour des bords nets


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def background(w, h):
    return Image.new("RGBA", (w, h), NIGHT + (255,))


def glow(w, h, cx, cy, r):
    """Lueur radiale pêche → rose → nuit (l'aube derrière le sommet)."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    steps = 90
    for i in range(steps, 0, -1):
        t = i / steps  # 1 = bord, 0 = centre
        if t < 0.35:
            k = t / 0.35
            c = tuple(int(PEACH[j] * (1 - k) + ROSE[j] * k) for j in range(3))
            a = int(255 * (1 - 0.2 * k))
        else:
            k = (t - 0.35) / 0.65
            c = tuple(int(ROSE[j] * (1 - k) + VIOLET[j] * k) for j in range(3))
            a = int(204 * (1 - k))
        rr = r * t
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=c + (a,))
    return img.filter(ImageFilter.GaussianBlur(r * 0.04))


def peak(w, h, cx, cy, s):
    """Le A en sommet : coordonnées de la maquette (cadre 400×240, s = 1 pour 240 px de haut)."""
    big = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    pts = [(200, 46), (278, 194), (242, 194), (200, 112), (158, 194), (122, 194)]
    d.polygon([((cx + (x - 200) * s) * SS, (cy + (y - 120) * s) * SS) for x, y in pts], fill=(255, 255, 255, 255))
    return big.resize((w, h), Image.LANCZOS)



def save_layer(stack_dir, layer, images):
    layer_dir = os.path.join(stack_dir, f"{layer}.imagestacklayer")
    write_json(os.path.join(layer_dir, "Contents.json"), {"info": INFO})
    set_dir = os.path.join(layer_dir, "Content.imageset")
    entries = []
    for scale, img in images:
        name = f"{layer.lower()}@{scale}.png"
        img.save(os.path.join(set_dir if os.makedirs(set_dir, exist_ok=True) is None else set_dir, name))
        entries.append({"idiom": "tv", "scale": scale, "filename": name})
    write_json(os.path.join(set_dir, "Contents.json"), {"images": entries, "info": INFO})


def stack(name, base_w, base_h, scales):
    stack_dir = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets", f"{name}.imagestack")
    write_json(os.path.join(stack_dir, "Contents.json"), {
        "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Middle.imagestacklayer"}, {"filename": "Back.imagestacklayer"}],
        "info": INFO})
    for layer in ["Back", "Middle", "Front"]:
        imgs = []
        for scale in scales:
            k = int(scale[0])
            w, h = base_w * k, base_h * k
            s = h / 240
            if layer == "Back":
                img = background(w, h)
            elif layer == "Middle":
                img = glow(w, h, w / 2, h * 0.62, w * 0.42)
            else:
                img = peak(w, h, w / 2, h / 2, s)
            imgs.append((scale, img))
        save_layer(stack_dir, layer, imgs)


def top_shelf(name, base_w, base_h):
    set_dir = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets", f"{name}.imageset")
    entries = []
    for scale in ["1x", "2x"]:
        k = int(scale[0])
        w, h = base_w * k, base_h * k
        img = background(w, h)
        img.alpha_composite(glow(w, h, w * 0.5, h * 0.62, h * 0.95))
        img.alpha_composite(peak(w, h, w * 0.5, h * 0.44, h / 240 * 0.62))
        font = ImageFont.truetype(FONT, int(h * 0.11))
        d = ImageDraw.Draw(img)
        d.text((w * 0.5, h * 0.80), "Aurora", font=font, fill=(255, 255, 255, 255), anchor="mm")
        fname = f"{name.replace(' ', '-').lower()}@{scale}.png"
        os.makedirs(set_dir, exist_ok=True)
        img.convert("RGB").save(os.path.join(set_dir, fname))
        entries.append({"idiom": "tv", "scale": scale, "filename": fname})
    write_json(os.path.join(set_dir, "Contents.json"), {"images": entries, "info": INFO})


def main():
    write_json(os.path.join(ROOT, "Contents.json"), {"info": INFO})
    brand = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
    write_json(os.path.join(brand, "Contents.json"), {
        "assets": [
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        ],
        "info": INFO})
    stack("App Icon", 400, 240, ["1x", "2x"])
    stack("App Icon - App Store", 1280, 768, ["1x"])
    top_shelf("Top Shelf Image", 1920, 720)
    top_shelf("Top Shelf Image Wide", 2320, 720)
    write_json(os.path.join(ROOT, "AccentColor.colorset", "Contents.json"), {
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": f"{AMBER[0] / 255:.3f}", "green": f"{AMBER[1] / 255:.3f}", "blue": f"{AMBER[2] / 255:.3f}", "alpha": "1.000"}}}],
        "info": INFO})


if __name__ == "__main__":
    main()
