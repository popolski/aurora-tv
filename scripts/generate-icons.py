#!/usr/bin/env python3
"""Génère les icônes tvOS en couches (Back/Middle/Front) et les images Top Shelf de Lanterne.

Usage : python3 scripts/generate-icons.py  (nécessite Pillow)
Les fichiers sont écrits dans App/Resources/Assets.xcassets.
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "Resources", "Assets.xcassets")
INFO = {"author": "xcode", "version": 1}
BG_TOP, BG_BOTTOM = (16, 20, 31), (6, 8, 13)
AMBER = (242, 179, 91)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def gradient(w, h):
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(int(BG_TOP[i] * (1 - t) + BG_BOTTOM[i] * t) for i in range(3))
        d.line([(0, y), (w, y)], fill=c + (255,))
    return img


def glow(w, h, cx, cy, r):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    steps = 40
    for i in range(steps, 0, -1):
        rr = r * i / steps
        a = int(150 * (1 - i / steps) ** 1.6)
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=AMBER + (a,))
    return img.filter(ImageFilter.GaussianBlur(r * 0.08))


def lantern(w, h, cx, cy, s):
    """Silhouette de lanterne : anse, chapeau, verre lumineux, socle."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cream = (250, 238, 214, 255)
    lw = max(2, int(s * 0.05))
    # Anse
    d.arc([cx - s * 0.28, cy - s * 0.95, cx + s * 0.28, cy - s * 0.45], 180, 360, fill=cream, width=lw)
    # Chapeau
    d.polygon([(cx - s * 0.42, cy - s * 0.48), (cx + s * 0.42, cy - s * 0.48), (cx + s * 0.30, cy - s * 0.62), (cx - s * 0.30, cy - s * 0.62)], fill=cream)
    # Verre (lumineux)
    d.rounded_rectangle([cx - s * 0.32, cy - s * 0.46, cx + s * 0.32, cy + s * 0.42], radius=s * 0.12, fill=AMBER + (255,), outline=cream, width=lw)
    # Flamme
    d.ellipse([cx - s * 0.10, cy - s * 0.18, cx + s * 0.10, cy + s * 0.20], fill=(255, 250, 235, 255))
    # Montants
    d.line([(cx, cy - s * 0.46), (cx, cy - s * 0.22)], fill=cream, width=lw)
    # Socle
    d.rounded_rectangle([cx - s * 0.46, cy + s * 0.40, cx + s * 0.46, cy + s * 0.54], radius=s * 0.04, fill=cream)
    return img


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
            cx, cy = w / 2, h * 0.52
            if layer == "Back":
                img = gradient(w, h)
            elif layer == "Middle":
                img = glow(w, h, cx, cy, h * 0.55)
            else:
                img = lantern(w, h, cx, cy, h * 0.42)
            imgs.append((scale, img))
        save_layer(stack_dir, layer, imgs)


def top_shelf(name, base_w, base_h):
    set_dir = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets", f"{name}.imageset")
    entries = []
    for scale in ["1x", "2x"]:
        k = int(scale[0])
        w, h = base_w * k, base_h * k
        img = gradient(w, h)
        img.alpha_composite(glow(w, h, w * 0.5, h * 0.55, h * 0.6))
        img.alpha_composite(lantern(w, h, w * 0.5, h * 0.55, h * 0.36))
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
