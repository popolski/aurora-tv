#!/usr/bin/env python3
"""aurora-trailers : bandes-annonces pour l'app Aurora (Apple TV), à héberger sur le NAS.

Les addons Stremio ne donnent que des identifiants YouTube, que l'Apple TV ne peut
pas lire directement. Ce service télécharge la piste vidéo de la bande-annonce
avec yt-dlp (1080p maximum, H.264, sans le son : l'app la lit en sourdine), la
garde en cache et la sert en HTTP avec prise en charge des plages (Range).

Points d'entrée :
  GET  /health                 état du service (JSON)
  GET  /trailer/<id>.mp4       bande-annonce (téléchargée à la première demande)
  POST /prefetch               {"ids": ["<id>", ...]} : préparation en arrière-plan

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
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
TRAILER_PATH_RE = re.compile(r"^/trailer/([A-Za-z0-9_-]{11})\.mp4$")

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


def video_format(max_height):
    # Piste vidéo seule (l'app coupe le son) en H.264, lisible par l'Apple TV.
    return (f"bv*[vcodec^=avc1][height<={max_height}][ext=mp4]"
            f"/bv*[vcodec^=avc1][height<=720]"
            f"/b[ext=mp4][height<={max_height}]")


class Cache:
    def __init__(self, directory, max_mb):
        self.directory = directory
        self.max_bytes = max_mb * 1024 * 1024
        self.work = os.path.join(directory, "tmp")
        os.makedirs(self.work, exist_ok=True)
        self.lock = threading.Lock()
        self.pending = {}   # id -> threading.Event
        self.failures = {}  # id -> horodatage de l'échec
        self.slots = threading.Semaphore(MAX_PARALLEL)

    def path(self, yt_id):
        return os.path.join(self.directory, f"{yt_id}.mp4")

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
        cmd = ["yt-dlp", "--no-playlist", "--no-progress", "--quiet", "--no-warnings",
               "--max-filesize", "300M", "-f", video_format(MAX_HEIGHT),
               "-o", stem + ".%(ext)s", "--", f"https://www.youtube.com/watch?v={yt_id}"]
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
        """MP4 classique, index en tête, sans piste audio (si ffmpeg est présent)."""
        if shutil.which("ffmpeg") is None:
            return False
        cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", source,
               "-map", "0:v:0", "-c", "copy", "-an", "-movflags", "+faststart", "-f", "mp4", target]
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


def make_handler(cache):
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
                    "ytdlp": ytdlp_version(),
                    "ffmpeg": shutil.which("ffmpeg") is not None,
                    "cached": len(entries),
                    "cacheMB": round(sum(e[1] for e in entries) / 1048576, 1),
                })
                return
            m = TRAILER_PATH_RE.match(path)
            if not m:
                self._error(HTTPStatus.NOT_FOUND, "inconnu")
                return
            yt_id = m.group(1)
            file_path = cache.ensure(yt_id, wait=WAIT_SECONDS)
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
            except (ValueError, AttributeError):
                self._error(HTTPStatus.BAD_REQUEST, "JSON invalide")
                return
            queued = 0
            for yt_id in ids:
                if not cache.cached(yt_id) and not cache.recently_failed(yt_id):
                    cache.ensure(yt_id, wait=0)
                    queued += 1
            self._json(HTTPStatus.ACCEPTED, {"queued": queued})

    return Handler


def main():
    cache = Cache(CACHE_DIR, CACHE_MAX_MB)
    version = ytdlp_version()
    log(f"aurora-trailers sur le port {PORT}, cache {CACHE_DIR} ({CACHE_MAX_MB} Mo max), "
        f"yt-dlp {version or 'absent'}, ffmpeg {'présent' if shutil.which('ffmpeg') else 'absent'}")
    if version is None:
        log("attention : yt-dlp est introuvable, aucune bande-annonce ne pourra être préparée")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(cache))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
