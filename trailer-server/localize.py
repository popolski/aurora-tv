"""Choix de la langue des bandes-annonces : VF, sinon VOSTFR, sinon VO.

Les addons Stremio (Cinemeta) ne donnent en général que la bande-annonce
originale. TMDB (themoviedb.org) répertorie aussi les bandes-annonces
françaises publiées sur YouTube, avec leur langue et leur titre
(« Bande-annonce VF », « … VOSTFR »). Ce module interroge TMDB avec la clé
`TMDB_API_KEY` (gratuite, propre à l'utilisateur, jamais journalisée) et garde
le choix en cache. Sans clé, ou si TMDB n'a rien, la bande-annonce de l'addon
est utilisée telle quelle.
"""
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TMDB_API = "https://api.themoviedb.org/3"
YT_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
IMDB_RE = re.compile(r"^tt\d{5,10}$")
TMDB_RE = re.compile(r"^tmdb:(\d{1,10})$")
# Identifiants de fiche acceptés (Stremio : tt…, tmdb:…, kitsu:…, etc.).
ITEM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_.-]{0,63}$")

LANG_ORDER = {"vf": 0, "vostfr": 1, "vo": 2}
VF_NAME_RE = re.compile(r"\b(vf|vff|vfq|version fran[cç]aise|doubl[ée]e?)\b", re.IGNORECASE)
VOST_NAME_RE = re.compile(r"\bvost|sous[- ]titr", re.IGNORECASE)

SUCCESS_TTL = 7 * 86400
EMPTY_TTL = 86400       # TMDB n'a rien : on réessaie le lendemain
ERROR_TTL = 15 * 60     # TMDB injoignable : réessai rapide


def classify(video):
    """Langue d'une vidéo TMDB (« vf », « vostfr », « vo ») ou None si inutilisable."""
    if not isinstance(video, dict):
        return None
    if video.get("site") != "YouTube" or not YT_RE.match(str(video.get("key", ""))):
        return None
    if video.get("type") not in ("Trailer", "Teaser"):
        return None
    name = str(video.get("name") or "")
    if VOST_NAME_RE.search(name):
        return "vostfr"
    if video.get("iso_639_1") == "fr" or VF_NAME_RE.search(name):
        return "vf"
    return "vo"


def pick(videos):
    """Meilleure bande-annonce : langue (VF > VOSTFR > VO), bande-annonce plutôt
    que teaser, officielle, meilleure définition, la plus récente."""
    candidates = []
    for v in videos or []:
        lang = classify(v)
        if lang is None:
            continue
        published = str(v.get("published_at") or "")
        candidates.append(((LANG_ORDER[lang], 0 if v.get("type") == "Trailer" else 1,
                            0 if v.get("official") else 1, -int(v.get("size") or 0)),
                           published, v["key"], lang))
    if not candidates:
        return None
    # Tri stable : d'abord la plus récente, puis les critères principaux.
    candidates.sort(key=lambda c: c[1], reverse=True)
    candidates.sort(key=lambda c: c[0])
    best = candidates[0]
    return best[2], best[3]


class TrailerLocalizer:
    def __init__(self, api_key, cache_dir, opener=None, log=print):
        self.api_key = (api_key or "").strip()
        self.path = os.path.join(cache_dir, "localized.json") if cache_dir else None
        self.opener = opener or urllib.request.urlopen
        self.log = log
        self.lock = threading.Lock()
        self.entries = self._load()

    @property
    def enabled(self):
        return bool(self.api_key)

    # Cache disque : {"movie:tt…": {"id": "…" | None, "lang": "vf", "until": 1700000000}}
    def _load(self):
        if not self.path:
            return {}
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save(self):
        if not self.path:
            return
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.entries, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def _get(self, path, params):
        params = dict(params)
        headers = {"Accept": "application/json"}
        # Jeton « lecture » v4 (JWT) en en-tête, clé v3 en paramètre.
        if self.api_key.startswith("eyJ"):
            headers["Authorization"] = "Bearer " + self.api_key
        else:
            params["api_key"] = self.api_key
        url = f"{TMDB_API}{path}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers=headers)
        with self.opener(req, timeout=8) as r:
            return json.loads(r.read().decode("utf-8"))

    def _tmdb_target(self, item_id, kind):
        """(« movie » | « tv », identifiant TMDB) ou None."""
        media = "tv" if kind == "series" else "movie"
        m = TMDB_RE.match(item_id)
        if m:
            return media, m.group(1)
        if not IMDB_RE.match(item_id):
            return None
        found = self._get(f"/find/{item_id}", {"external_source": "imdb_id"})
        first = (found.get(f"{media}_results") or [])
        other = (found.get("tv_results" if media == "movie" else "movie_results") or [])
        if first:
            return media, str(first[0].get("id"))
        if other:  # type mal annoncé par l'addon
            return ("tv" if media == "movie" else "movie"), str(other[0].get("id"))
        return None

    def lookup(self, item_id, kind):
        """(identifiant YouTube, langue) d'après TMDB, ou None. Mis en cache."""
        if not self.enabled or not ITEM_RE.match(item_id or ""):
            return None
        key = f"{kind}:{item_id}"
        now = time.time()
        with self.lock:
            entry = self.entries.get(key)
        if entry and entry.get("until", 0) > now:
            return (entry["id"], entry.get("lang", "vo")) if entry.get("id") else None
        result, ttl = None, EMPTY_TTL
        try:
            target = self._tmdb_target(item_id, kind)
            if target:
                media, tmdb_id = target
                data = self._get(f"/{media}/{tmdb_id}/videos",
                                 {"language": "fr-FR", "include_video_language": "fr,en,null"})
                result = pick(data.get("results"))
            ttl = SUCCESS_TTL if result else EMPTY_TTL
        except urllib.error.HTTPError as e:
            # Message sans l'adresse (qui peut contenir la clé).
            self.log(f"TMDB {item_id} : erreur HTTP {e.code}{' (clé TMDB refusée ?)' if e.code == 401 else ''}")
            ttl = ERROR_TTL
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.log(f"TMDB {item_id} : injoignable ({type(e).__name__})")
            ttl = ERROR_TTL
        with self.lock:
            self.entries[key] = {"id": result[0] if result else None,
                                 "lang": result[1] if result else None,
                                 "until": now + ttl}
            if len(self.entries) > 5000:  # borne : on retire les plus anciennes
                for k in sorted(self.entries, key=lambda k: self.entries[k].get("until", 0))[:1000]:
                    del self.entries[k]
            self._save()
        if result:
            self.log(f"bande-annonce {item_id} : {result[1].upper()} ({result[0]})")
        return result

    def choose(self, item_id, kind, fallback_ids):
        """Bande-annonce à servir : TMDB (VF > VOSTFR > VO), sinon celle de l'addon."""
        found = self.lookup(item_id, kind)
        fallback = next((i for i in fallback_ids if YT_RE.match(i)), None)
        if found:
            # TMDB n'a que la VO : on garde celle de l'addon si elle existe (déjà en cache, souvent).
            if found[1] == "vo" and fallback:
                return fallback, "vo"
            return found
        return (fallback, "vo") if fallback else (None, None)
