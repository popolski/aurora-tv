#!/usr/bin/env python3
"""aurora-trailers : bandes-annonces pour l'app Aurora (Apple TV), à héberger sur le NAS.

Les addons Stremio ne donnent que des identifiants YouTube, que l'Apple TV ne peut
pas lire directement. Ce service télécharge la bande-annonce avec yt-dlp (1080p
maximum, H.264 + AAC ; l'app la lit sans le son en fond, avec le son à la demande),
la garde en cache et la sert en HTTP avec prise en charge des plages (Range).

Points d'entrée :
  GET  /health                 état du service (JSON)
  GET  /trailer/<id>.mp4       bande-annonce (téléchargée à la première demande)
  GET  /trailer/<id>.preview.mp4  extrait de 30 s, sans le son (carrousel Top Shelf)
  GET  /trailer/for/<fiche>.mp4?type=movie&yt=<id>   bande-annonce d'une fiche, en français
       si possible (VF, sinon VOSTFR, sinon VO ; TMDB, clé TMDB_API_KEY) ; aussi .preview.mp4
  GET  /resolve/<fiche>.json?type=movie&yt=<id>      choix fait pour une fiche (diagnostic)
  GET  /topshelf/<id>.jpg?bg=…&logo=…&title=…  image du carrousel avec le titre incrusté
  POST /prefetch               {"ids": ["<id>", ...]} ou {"items": [{"id", "type", "yt"}]} :
                               préparation en arrière-plan

Réservé au réseau local : n'exposez pas ce port sur Internet.
Aucune dépendance hors bibliothèque standard, à part yt-dlp (et ffmpeg, facultatif).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import localize

try:  # Pillow : facultatif (images du carrousel Top Shelf)
    import topshelf
except ImportError:  # pragma: no cover - dépend de l'image Docker
    topshelf = None

ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
TOPSHELF_PATH_RE = re.compile(r"^/topshelf/([A-Za-z0-9][A-Za-z0-9:_.-]{0,63})\.jpg$")
TRAILER_PATH_RE = re.compile(r"^/trailer/([A-Za-z0-9_-]{11})(\.preview)?\.mp4$")
ITEM_TRAILER_PATH_RE = re.compile(r"^/trailer/for/([A-Za-z0-9][A-Za-z0-9:_.-]{0,63}?)(\.preview)?\.mp4$")
RESOLVE_PATH_RE = re.compile(r"^/resolve/([A-Za-z0-9][A-Za-z0-9:_.-]{0,63})\.json$")
TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "")
PREVIEW_START = int(os.environ.get("PREVIEW_START", "5"))
PREVIEW_SECONDS = int(os.environ.get("PREVIEW_SECONDS", "30"))
# Fichiers du cache : « <id>.av.mp4 » (image + son). Les anciens « <id>.mp4 » (image seule,
# première version du service) sont supprimés au démarrage.
OLD_FILE_RE = re.compile(r"^[A-Za-z0-9_-]{11}\.mp4$")

CACHE_DIR = os.environ.get("CACHE_DIR", "/cache")
CACHE_MAX_MB = int(os.environ.get("CACHE_MAX_MB", "4000"))
PORT = int(os.environ.get("PORT", "8787"))
MAX_HEIGHT = int(os.environ.get("MAX_HEIGHT", "1080"))
MAX_PARALLEL = int(os.environ.get("MAX_PARALLEL", "2"))
DOWNLOAD_TIMEOUT = int(os.environ.get("DOWNLOAD_TIMEOUT", "180"))
WAIT_SECONDS = int(os.environ.get("WAIT_SECONDS", "120"))
FAILURE_TTL = int(os.environ.get("FAILURE_TTL", str(6 * 3600)))
MAX_PREFETCH = 30
CHUNK = 256 * 1024


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def is_valid_id(value):
    return isinstance(value, str) and ID_RE.match(value) is not None


def parse_range(header, size):
    """« bytes=a-b » → (début, fin incluse), None si absent, ValueError si non satisfaisable."""
    if not header:
        return None
    m = re.match(r"^bytes=(\d*)-(\d*)$", header.strip())
    if not m or (m.group(1) == "" and m.group(2) == ""):
        raise ValueError("plage invalide")
    if m.group(1) == "":  # suffixe : les N derniers octets
        length = int(m.group(2))
        if length == 0:
            raise ValueError("plage vide")
        return max(0, size - length), size - 1
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else size - 1
    if start >= size or end < start:
        raise ValueError("plage hors du fichier")
    return start, min(end, size - 1)


def video_format(max_height, can_merge):
    """H.264 + AAC, lisibles par l'Apple TV. Sans ffmpeg, pas d'assemblage possible :
    on se contente d'un fichier déjà complet (souvent 360p)."""
    single = f"b[ext=mp4][vcodec^=avc1][height<={max_height}]/b[ext=mp4]"
    if not can_merge:
        return single
    return (f"bv*[vcodec^=avc1][height<={max_height}][ext=mp4]+ba[ext=m4a]"
            f"/bv*[vcodec^=avc1][height<=720]+ba[ext=m4a]/{single}")


class Cache:
    def __init__(self, directory, max_mb):
        self.directory = directory
        self.max_bytes = max_mb * 1024 * 1024
        self.work = os.path.join(directory, "tmp")
        os.makedirs(self.work, exist_ok=True)
        for name in os.listdir(directory):
            if OLD_FILE_RE.match(name):
                try:
                    os.remove(os.path.join(directory, name))
                except OSError:
                    pass
        self.lock = threading.Lock()
        self.pending = {}   # id -> threading.Event
        self.failures = {}  # id -> horodatage de l'échec
        self.slots = threading.Semaphore(MAX_PARALLEL)

    def path(self, yt_id):
        return os.path.join(self.directory, f"{yt_id}.av.mp4")

    def cached(self, yt_id):
        p = self.path(yt_id)
        return p if os.path.isfile(p) else None

    def recently_failed(self, yt_id):
        at = self.failures.get(yt_id)
        return at is not None and time.time() - at < FAILURE_TTL

    def ensure(self, yt_id, wait):
        """Renvoie le chemin du fichier ; le télécharge si besoin (attend au plus `wait` s)."""
        p = self.cached(yt_id)
        if p:
            return p
        with self.lock:
            if self.recently_failed(yt_id):
                return None
            event = self.pending.get(yt_id)
            if event is None:
                event = threading.Event()
                self.pending[yt_id] = event
                threading.Thread(target=self._download, args=(yt_id, event), daemon=True).start()
        if wait > 0:
            event.wait(wait)
        return self.cached(yt_id)

    def _download(self, yt_id, event):
        try:
            with self.slots:
                if self.cached(yt_id):
                    return
                ok = self._fetch(yt_id)
                with self.lock:
                    if ok:
                        self.failures.pop(yt_id, None)
                    else:
                        self.failures[yt_id] = time.time()
                if ok:
                    self.evict()
        finally:
            with self.lock:
                self.pending.pop(yt_id, None)
            event.set()

    def _fetch(self, yt_id):
        started = time.time()
        stem = os.path.join(self.work, yt_id)
        for leftover in self._work_files(yt_id):
            os.remove(leftover)
        can_merge = shutil.which("ffmpeg") is not None
        cmd = ["yt-dlp", "--no-playlist", "--no-progress", "--quiet", "--no-warnings",
               "--max-filesize", "300M", "-f", video_format(MAX_HEIGHT, can_merge),
               "-o", stem + ".%(ext)s"]
        if can_merge:
            cmd += ["--merge-output-format", "mp4"]
        cmd += ["--", f"https://www.youtube.com/watch?v={yt_id}"]
        try:
            subprocess.run(cmd, check=True, timeout=DOWNLOAD_TIMEOUT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except FileNotFoundError:
            log("yt-dlp introuvable : installez-le (pip install yt-dlp)")
            return False
        except subprocess.TimeoutExpired:
            log(f"{yt_id} : délai dépassé")
            self._cleanup(yt_id)
            return False
        except subprocess.CalledProcessError as e:
            detail = (e.stderr or b"").decode("utf-8", "replace").strip().splitlines()
            log(f"{yt_id} : échec yt-dlp ({detail[-1] if detail else e.returncode})")
            self._cleanup(yt_id)
            return False
        files = [f for f in self._work_files(yt_id) if not f.endswith(".part")]
        if not files:
            log(f"{yt_id} : aucun fichier produit")
            return False
        source = files[0]
        final = self.path(yt_id)
        if not self._remux(source, final + ".tmp"):
            shutil.move(source, final + ".tmp")
        os.replace(final + ".tmp", final)
        self._cleanup(yt_id)
        size_mb = os.path.getsize(final) / 1048576
        log(f"{yt_id} : prêt ({size_mb:.1f} Mo, {time.time() - started:.0f} s)")
        return True

    @staticmethod
    def _remux(source, target):
        """MP4 classique, index en tête (si ffmpeg est présent)."""
        if shutil.which("ffmpeg") is None:
            return False
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", source,
               "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-movflags", "+faststart", "-f", "mp4", target]
        try:
            subprocess.run(cmd, check=True, timeout=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except (subprocess.SubprocessError, OSError):
            if os.path.exists(target):
                os.remove(target)
            return False

    def _work_files(self, yt_id):
        return [os.path.join(self.work, f) for f in os.listdir(self.work) if f.startswith(yt_id + ".")]

    def _cleanup(self, yt_id):
        for f in self._work_files(yt_id):
            try:
                os.remove(f)
            except OSError:
                pass

    def preview(self, yt_id):
        """Extrait court et muet de la bande-annonce (créé à la demande, puis gardé en cache)."""
        full = self.cached(yt_id)
        if not full:
            return None
        target = os.path.join(self.directory, f"{yt_id}.preview.mp4")
        if os.path.isfile(target):
            return target
        if shutil.which("ffmpeg") is None:
            return full  # sans ffmpeg : la bande-annonce entière
        tmp = os.path.join(self.work, f"{yt_id}.preview.mp4")
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(PREVIEW_START), "-i", full,
               "-t", str(PREVIEW_SECONDS), "-map", "0:v:0", "-c", "copy", "-an",
               "-movflags", "+faststart", "-f", "mp4", tmp]
        try:
            subprocess.run(cmd, check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.replace(tmp, target)
            return target
        except (subprocess.SubprocessError, OSError):
            if os.path.exists(tmp):
                os.remove(tmp)
            return full

    def entries(self):
        out = []
        for name in os.listdir(self.directory):
            p = os.path.join(self.directory, name)
            if name.endswith(".mp4") and os.path.isfile(p):
                st = os.stat(p)
                out.append((st.st_mtime, st.st_size, p))
        return out

    def evict(self):
        """Supprime les bandes-annonces les moins récemment vues au-delà de la taille maximale."""
        entries = sorted(self.entries())
        total = sum(size for _, size, _ in entries)
        while entries and total > self.max_bytes:
            _, size, p = entries.pop(0)
            try:
                os.remove(p)
                total -= size
                log(f"cache plein : {os.path.basename(p)} supprimé")
            except OSError:
                pass

    def touch(self, path):
        try:
            os.utime(path, None)
        except OSError:
            pass


def ytdlp_version():
    try:
        out = subprocess.run(["yt-dlp", "--version"], capture_output=True, timeout=20, check=True)
        return out.stdout.decode().strip()
    except (OSError, subprocess.SubprocessError):
        return None


def item_query(path):
    """(type, identifiants YouTube de repli) d'après la requête ?type=…&yt=…"""
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
    kind = "series" if (query.get("type") or ["movie"])[0] == "series" else "movie"
    fallback = [i for i in query.get("yt", []) if is_valid_id(i)][:5]
    return kind, fallback


def make_handler(cache, localizer=None):
    if localizer is None:
        localizer = localize.TrailerLocalizer("", None, log=log)

    class Handler(BaseHTTPRequestHandler):
        server_version = "aurora-trailers/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # journal réduit
            pass

        def _json(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _error(self, status, message):
            self._json(status, {"error": message})

        def do_GET(self):  # noqa: N802
            self._serve(head=False)

        def do_HEAD(self):  # noqa: N802
            self._serve(head=True)

        def _serve(self, head):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                entries = cache.entries()
                self._json(HTTPStatus.OK, {
                    "ok": True,
                    "audio": True,
                    "preview": True,
                    "topshelf": topshelf is not None,
                    "localized": localizer.enabled,
                    "ytdlp": ytdlp_version(),
                    "ffmpeg": shutil.which("ffmpeg") is not None,
                    "cached": len(entries),
                    "cacheMB": round(sum(e[1] for e in entries) / 1048576, 1),
                })
                return
            ts = TOPSHELF_PATH_RE.match(path)
            if ts:
                self._serve_topshelf(ts.group(1), head)
                return
            rs = RESOLVE_PATH_RE.match(path)
            if rs:
                kind, fallback = item_query(self.path)
                yt_id, lang = localizer.choose(rs.group(1), kind, fallback)
                self._json(HTTPStatus.OK, {"id": yt_id, "language": lang, "tmdb": localizer.enabled})
                return
            item = ITEM_TRAILER_PATH_RE.match(path)
            if item:
                kind, fallback = item_query(self.path)
                yt_id, lang = localizer.choose(item.group(1), kind, fallback)
                if not yt_id:
                    self._error(HTTPStatus.NOT_FOUND, "aucune bande-annonce pour cette fiche")
                    return
                self._serve_trailer(yt_id, bool(item.group(2)), head, lang)
                return
            m = TRAILER_PATH_RE.match(path)
            if not m:
                self._error(HTTPStatus.NOT_FOUND, "inconnu")
                return
            self._serve_trailer(m.group(1), bool(m.group(2)), head, None)

        def _serve_trailer(self, yt_id, preview, head, lang):
            file_path = cache.ensure(yt_id, wait=WAIT_SECONDS)
            if file_path and preview:
                file_path = cache.preview(yt_id)
            if not file_path:
                status = HTTPStatus.NOT_FOUND if cache.recently_failed(yt_id) else HTTPStatus.GATEWAY_TIMEOUT
                self._error(status, "bande-annonce indisponible")
                return
            cache.touch(file_path)
            size = os.path.getsize(file_path)
            try:
                rng = parse_range(self.headers.get("Range"), size)
            except ValueError:
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = rng if rng else (0, size - 1)
            length = end - start + 1
            self.send_response(HTTPStatus.PARTIAL_CONTENT if rng else HTTPStatus.OK)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "public, max-age=86400")
            if lang:
                self.send_header("X-Trailer-Language", lang)
            if rng:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            try:
                with open(file_path, "rb") as f:
                    f.seek(start)
                    remaining = length
                    while remaining > 0:
                        chunk = f.read(min(CHUNK, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass  # le lecteur a interrompu la lecture : normal

        def _serve_topshelf(self, item_id, head):
            if topshelf is None:
                self._error(HTTPStatus.NOT_IMPLEMENTED, "Pillow absent")
                return
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            first = lambda key: (query.get(key) or [None])[0]  # noqa: E731
            try:
                file_path = topshelf.ensure(os.path.join(cache.directory, "topshelf"), item_id,
                                            first("bg"), first("logo"), first("title"))
            except ValueError as e:
                self._error(HTTPStatus.BAD_REQUEST, str(e))
                return
            except OSError as e:
                log(f"topshelf {item_id} : image indisponible ({e})")
                self._error(HTTPStatus.BAD_GATEWAY, "image indisponible")
                return
            size = os.path.getsize(file_path)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            if head:
                return
            try:
                with open(file_path, "rb") as f:
                    shutil.copyfileobj(f, self.wfile, CHUNK)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):  # noqa: N802
            if self.path.split("?", 1)[0] != "/prefetch":
                self._error(HTTPStatus.NOT_FOUND, "inconnu")
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 16 * 1024:
                self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "taille invalide")
                return
            try:
                payload = json.loads(self.rfile.read(length))
                ids = [i for i in payload.get("ids", []) if is_valid_id(i)][:MAX_PREFETCH]
                items = [it for it in payload.get("items", []) if isinstance(it, dict)
                         and localize.ITEM_RE.match(str(it.get("id", "")))][:MAX_PREFETCH]
            except (ValueError, AttributeError, TypeError):
                self._error(HTTPStatus.BAD_REQUEST, "JSON invalide")
                return
            queued = 0
            for yt_id in ids:
                if not cache.cached(yt_id) and not cache.recently_failed(yt_id):
                    cache.ensure(yt_id, wait=0)
                    queued += 1
            if items:
                # Choix de la langue (appels TMDB) hors de la requête : réponse immédiate.
                threading.Thread(target=prefetch_items, args=(cache, localizer, items), daemon=True).start()
                queued += len(items)
            self._json(HTTPStatus.ACCEPTED, {"queued": queued})

    return Handler


def prefetch_items(cache, localizer, items):
    for it in items:
        kind = "series" if it.get("type") == "series" else "movie"
        fallback = [i for i in (it.get("yt") or []) if isinstance(i, str) and is_valid_id(i)][:5]
        yt_id, _ = localizer.choose(str(it["id"]), kind, fallback)
        if yt_id and not cache.cached(yt_id) and not cache.recently_failed(yt_id):
            cache.ensure(yt_id, wait=0)


def clean_topshelf(directory, max_age=14 * 86400):
    folder = os.path.join(directory, "topshelf")
    if not os.path.isdir(folder):
        return
    now = time.time()
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        try:
            if now - os.path.getmtime(path) > max_age:
                os.remove(path)
        except OSError:
            pass


def main():
    try:
        cache = Cache(CACHE_DIR, CACHE_MAX_MB)
        clean_topshelf(CACHE_DIR)
    except PermissionError:
        log(f"impossible d'écrire dans {CACHE_DIR} : le dossier monté n'est pas accessible en écriture "
            f"pour l'utilisateur du conteneur (uid {os.getuid()}). Utilisez le volume Docker nommé "
            f"de compose.yaml (« trailers-cache:/cache ») plutôt qu'un dossier partagé du NAS.")
        time.sleep(60)  # évite une boucle de redémarrage trop rapide
        return 1
    version = ytdlp_version()
    log(f"aurora-trailers sur le port {PORT}, cache {CACHE_DIR} ({CACHE_MAX_MB} Mo max), "
        f"yt-dlp {version or 'absent'}, ffmpeg {'présent' if shutil.which('ffmpeg') else 'absent'}, "
        f"images Top Shelf {'oui' if topshelf else 'non (Pillow absent)'}")
    if version is None:
        log("attention : yt-dlp est introuvable, aucune bande-annonce ne pourra être préparée")
    localizer = localize.TrailerLocalizer(TMDB_API_KEY, CACHE_DIR, log=log)
    log("bandes-annonces en français : " + ("oui (TMDB)" if localizer.enabled
        else "non (ajoutez TMDB_API_KEY dans le fichier .env, voir README)"))
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(cache, localizer))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
