"""Découverte via TMDB (clé TMDB_API_KEY du NAS) : recommandations et collections.

- recommandations : titres proches d'une fiche (« Parce que vous avez regardé… ») ;
- collection : saga d'un film selon TMDB, en complément de Wikidata.

Aurora n'ouvre que des fiches à identifiant IMDb (Cinemeta) : chaque titre TMDB est
converti par /external_ids (correspondance gardée sans limite de durée). Réponses
gardées 3 jours. Sans clé, rien n'est appelé.
"""
import json
import os
import threading
import time
import urllib.error
from concurrent.futures import ThreadPoolExecutor

import localize

IMAGE_BASE = "https://image.tmdb.org/t/p/"
RESULT_TTL = 3 * 86400
ERROR_TTL = 15 * 60


def image(path, size):
    if not isinstance(path, str) or not path.startswith("/") or ".." in path or len(path) > 200:
        return None
    return f"{IMAGE_BASE}{size}{path}"


def year_of(value):
    if isinstance(value, str) and len(value) >= 4 and value[:4].isdigit():
        return int(value[:4])
    return None


class Discovery:
    def __init__(self, localizer, cache_dir, log=print):
        self.loc = localizer
        self.log = log
        self.path = os.path.join(cache_dir, "discovery.json") if cache_dir else None
        self.lock = threading.Lock()
        self.results = {}
        self.imdb = {}   # « movie:603 » → « tt0133093 » (ou "" si aucun)
        self._load()

    @property
    def enabled(self):
        return self.loc.enabled

    def _load(self):
        if not self.path:
            return
        try:
            with open(self.path, encoding="utf-8") as f:
                data = json.load(f)
            self.results = data.get("results", {}) if isinstance(data, dict) else {}
            self.imdb = data.get("imdb", {}) if isinstance(data, dict) else {}
        except (OSError, ValueError):
            pass

    def _save(self):
        if not self.path:
            return
        with self.lock:
            if len(self.results) > 2000:
                for k in sorted(self.results, key=lambda k: self.results[k].get("until", 0))[:500]:
                    del self.results[k]
            payload = {"results": self.results, "imdb": self.imdb}
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def _cached(self, key, compute):
        now = time.time()
        with self.lock:
            entry = self.results.get(key)
        if entry and entry.get("until", 0) > now:
            return entry.get("value")
        try:
            value, ttl = compute(), RESULT_TTL
        except urllib.error.HTTPError as e:
            self.log(f"TMDB ({key}) : erreur HTTP {e.code}")
            value, ttl = None, ERROR_TTL
        except (urllib.error.URLError, OSError, ValueError) as e:
            self.log(f"TMDB ({key}) : injoignable ({type(e).__name__})")
            value, ttl = None, ERROR_TTL
        with self.lock:
            self.results[key] = {"value": value, "until": now + ttl}
        self._save()
        return value

    def _imdb_of(self, media, tmdb_id):
        key = f"{media}:{tmdb_id}"
        with self.lock:
            if key in self.imdb:
                return self.imdb[key] or None
        try:
            data = self.loc._get(f"/{media}/{int(tmdb_id)}/external_ids", {})
        except (urllib.error.URLError, OSError, ValueError, TypeError):
            return None
        imdb = data.get("imdb_id") if isinstance(data, dict) else None
        imdb = imdb if isinstance(imdb, str) and localize.IMDB_RE.match(imdb) else ""
        with self.lock:
            self.imdb[key] = imdb
        return imdb or None

    def _with_imdb(self, media_items):
        """[(media, résultat TMDB)] → [(identifiant IMDb, media, résultat)], ordre conservé."""
        with ThreadPoolExecutor(max_workers=6) as pool:
            ids = list(pool.map(lambda mr: self._imdb_of(mr[0], mr[1].get("id")), media_items))
        return [(imdb, media, r) for imdb, (media, r) in zip(ids, media_items) if imdb]

    def recommendations(self, item_id, kind, limit=15):
        if not self.enabled or not localize.ITEM_RE.match(item_id or ""):
            return None

        def compute():
            target = self.loc._tmdb_target(item_id, kind)
            if not target:
                return []
            media, tmdb_id = target
            data = self.loc._get(f"/{media}/{tmdb_id}/recommendations", {"language": "fr-FR", "page": 1})
            results = [r for r in (data.get("results") or []) if isinstance(r, dict) and r.get("id")][:limit + 5]
            pairs = [(r.get("media_type") if r.get("media_type") in ("movie", "tv") else media, r) for r in results]
            items = []
            for imdb, m, r in self._with_imdb(pairs)[:limit]:
                items.append({
                    "imdb": imdb,
                    "type": "series" if m == "tv" else "movie",
                    "title": r.get("title") or r.get("name") or imdb,
                    "year": year_of(r.get("release_date") or r.get("first_air_date")),
                    "poster": image(r.get("poster_path"), "w342"),
                    "background": image(r.get("backdrop_path"), "w1280"),
                })
            return items

        return self._cached(f"reco:{kind}:{item_id}", compute)

    def collection(self, item_id):
        if not self.enabled or not localize.ITEM_RE.match(item_id or ""):
            return None

        def compute():
            target = self.loc._tmdb_target(item_id, "movie")
            if not target or target[0] != "movie":
                return None
            details = self.loc._get(f"/movie/{target[1]}", {"language": "fr-FR"})
            ref = details.get("belongs_to_collection") if isinstance(details, dict) else None
            if not isinstance(ref, dict) or not ref.get("id"):
                return None
            data = self.loc._get(f"/collection/{int(ref['id'])}", {"language": "fr-FR"})
            parts = [p for p in (data.get("parts") or []) if isinstance(p, dict) and p.get("id")]
            # Ordre de sortie ; les titres sans date (annoncés) à la fin.
            parts.sort(key=lambda p: (p.get("release_date") or "9999", p.get("title") or ""))
            out = [{"imdb": imdb, "title": p.get("title") or imdb, "year": year_of(p.get("release_date")),
                    "poster": image(p.get("poster_path"), "w342")}
                   for imdb, _, p in self._with_imdb([("movie", p) for p in parts])]
            if len(out) < 2:
                return None
            return {"name": data.get("name") or ref.get("name") or "Saga", "parts": out}

        return self._cached(f"collection:{item_id}", compute)
