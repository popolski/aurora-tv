"""Images du carrousel Top Shelf avec le titre du film incrusté.

tvOS n'affiche pas le titre dans le carrousel « détaillé » : il doit faire partie de
l'image. L'extension de l'Apple TV dispose de trop peu de mémoire pour composer ces
images elle-même ; ce module le fait sur le NAS (Pillow), et garde le résultat en cache.

Sécurité : les adresses d'images viennent des addons (données non fiables). Seules
des adresses HTTPS vers une liste d'hôtes d'images connus sont acceptées (pas de
requête vers le réseau local ni vers un hôte arbitraire), avec une taille maximale.
"""
import hashlib
import io
import os
import re
import urllib.parse
import urllib.request

from PIL import Image, ImageDraw, ImageFilter, ImageFont

WIDTH, HEIGHT = 1920, 1080
MAX_DOWNLOAD = 15 * 1024 * 1024
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$")
DEFAULT_HOSTS = ("images.metahub.space,live.metahub.space,episodes.metahub.space,image.tmdb.org,"
                 "m.media-amazon.com,artworks.thetvdb.com,assets.fanart.tv")
ALLOWED_HOSTS = {h.strip().lower() for h in os.environ.get("TOPSHELF_IMAGE_HOSTS", DEFAULT_HOSTS).split(",") if h.strip()}
FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts", "Manrope-ExtraBold.ttf")


def is_allowed_image_url(url):
    try:
        parts = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    return parts.scheme == "https" and (parts.hostname or "").lower() in ALLOWED_HOSTS and not parts.username


def cache_name(item_id, background, logo, title):
    digest = hashlib.sha256("|".join([item_id, background, logo or "", title or "", "v1"]).encode()).hexdigest()[:20]
    return f"{item_id.replace(':', '_')}-{digest}.jpg"


def fetch(url, timeout=10):
    if not is_allowed_image_url(url):
        raise ValueError("adresse d'image refusée")
    request = urllib.request.Request(url, headers={"User-Agent": "aurora-trailers/1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 (hôtes filtrés)
        data = response.read(MAX_DOWNLOAD + 1)
    if len(data) > MAX_DOWNLOAD:
        raise ValueError("image trop lourde")
    return data


def _cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    resized = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.LANCZOS)
    left = (resized.width - width) // 2
    top = (resized.height - height) // 2
    return resized.crop((left, top, left + width, top + height))


def _left_shade(width, height, strength=0.62, extent=0.62):
    """Voile noir dégradé de la gauche vers le centre."""
    shade = Image.new("L", (width, 1))
    stop = int(width * extent)
    for x in range(width):
        alpha = strength * max(0.0, 1 - x / stop) if x < stop else 0
        shade.putpixel((x, 0), int(255 * alpha))
    return shade.resize((width, height))


def _font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default(size=size)


def _wrap(draw, text, font, max_width, max_lines=2):
    words, lines, current = text.split(), [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if draw.textlength(candidate, font=font) <= max_width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1].rstrip(".,;:") + "…"
    return lines


def compose(background_bytes, logo_bytes, title):
    """JPEG 1920×1080 : fond recadré, voile à gauche, logo (ou nom) à gauche, au-dessus
    de la zone où tvOS affiche ses propres textes (bas de l'écran)."""
    with Image.open(io.BytesIO(background_bytes)) as raw:
        raw.draft("RGB", (WIDTH, HEIGHT))
        canvas = _cover(raw.convert("RGB"), WIDTH, HEIGHT)
    black = Image.new("RGB", (WIDTH, HEIGHT), (0, 0, 0))
    canvas = Image.composite(black, canvas, _left_shade(WIDTH, HEIGHT))

    left = int(WIDTH * 0.05)
    bottom = int(HEIGHT * 0.58)            # bas du titre, depuis le haut
    box_w, box_h = int(WIDTH * 0.36), int(HEIGHT * 0.20)
    layer = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))

    logo = None
    if logo_bytes:
        try:
            with Image.open(io.BytesIO(logo_bytes)) as raw_logo:
                logo = raw_logo.convert("RGBA")
                logo.thumbnail((box_w, box_h), Image.LANCZOS)
        except OSError:
            logo = None
    if logo is not None:
        layer.alpha_composite(logo, (left, bottom - logo.height))
    elif title:
        size = 92 if len(title) <= 28 else 72
        font = _font(size)
        draw = ImageDraw.Draw(layer)
        lines = _wrap(draw, title, font, int(WIDTH * 0.45))
        line_height = int(size * 1.12)
        y = bottom - line_height * len(lines)
        for line in lines:
            draw.text((left, y), line, font=font, fill=(255, 255, 255, 255))
            y += line_height

    # Ombre douce sous le titre, pour la lisibilité sur les fonds clairs.
    alpha = layer.getchannel("A")
    shadow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(14)).point(lambda a: int(a * 0.55)))
    result = canvas.convert("RGBA")
    result.alpha_composite(shadow, (0, 4))
    result.alpha_composite(layer)

    out = io.BytesIO()
    result.convert("RGB").save(out, "JPEG", quality=86, optimize=True)
    return out.getvalue()


def ensure(directory, item_id, background, logo, title, fetcher=fetch):
    """Chemin de l'image composée (créée si besoin). ValueError si les paramètres sont refusés."""
    if not ID_RE.match(item_id or ""):
        raise ValueError("identifiant invalide")
    if not background or not is_allowed_image_url(background):
        raise ValueError("image de fond refusée")
    if logo and not is_allowed_image_url(logo):
        logo = None
    title = (title or "")[:200]
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, cache_name(item_id, background, logo, title))
    if os.path.isfile(path):
        return path
    background_bytes = fetcher(background)
    logo_bytes = None
    if logo:
        try:
            logo_bytes = fetcher(logo)
        except (OSError, ValueError):
            logo_bytes = None
    data = compose(background_bytes, logo_bytes, title)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return path
