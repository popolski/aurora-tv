"""Tests du choix de langue des bandes-annonces (TMDB simulé, aucun accès réseau)."""
import io
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.parse

import localize


def video(key, lang, name, kind="Trailer", official=True, size=1080, published="2026-01-01T00:00:00.000Z"):
    return {"site": "YouTube", "key": key, "iso_639_1": lang, "name": name, "type": kind,
            "official": official, "size": size, "published_at": published}


class FakeTMDB:
    """Répond comme l'API TMDB v3 et garde les requêtes reçues."""

    def __init__(self, videos=None, find=None, status=None):
        self.videos = videos or []
        self.find = find if find is not None else {"movie_results": [{"id": 278}], "tv_results": []}
        self.status = status
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        if self.status:
            raise urllib.error.HTTPError(req.full_url, self.status, "erreur", {}, None)
        path = urllib.parse.urlsplit(req.full_url).path
        body = self.find if path.startswith("/3/find/") else {"results": self.videos}
        return io.BytesIO(json.dumps(body).encode())


class ClassifyTests(unittest.TestCase):
    def test_languages(self):
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "fr", "Bande-annonce VF")), "vf")
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "fr", "Bande-annonce officielle")), "vf")
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "fr", "Bande-annonce VOSTFR")), "vostfr")
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "en", "Trailer (VOSTF)")), "vostfr")
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "en", "Official Trailer")), "vo")
        self.assertEqual(localize.classify(video("aaaaaaaaaaa", "en", "Trailer VFF")), "vf")

    def test_unusable_videos(self):
        self.assertIsNone(localize.classify(video("aaaaaaaaaaa", "fr", "Making-of", kind="Featurette")))
        self.assertIsNone(localize.classify(dict(video("aaaaaaaaaaa", "fr", "VF"), site="Vimeo")))
        self.assertIsNone(localize.classify(video("../etc/pass", "fr", "VF")))
        self.assertIsNone(localize.classify("pas une vidéo"))

    def test_pick_prefers_vf_then_vostfr_then_vo(self):
        vo = video("vovovovovov", "en", "Official Trailer")
        vost = video("vostvostvos", "fr", "Bande-annonce VOSTFR")
        teaser_vf = video("teaservfvfv", "fr", "Teaser VF", kind="Teaser")
        vf = video("vfvfvfvfvfv", "fr", "Bande-annonce VF")
        self.assertEqual(localize.pick([vo, vost, teaser_vf, vf]), ("vfvfvfvfvfv", "vf"))
        self.assertEqual(localize.pick([vo, vost]), ("vostvostvos", "vostfr"))
        self.assertEqual(localize.pick([vo]), ("vovovovovov", "vo"))
        self.assertIsNone(localize.pick([]))

    def test_pick_newest_among_equals(self):
        old = video("oldoldoldol", "fr", "Bande-annonce VF", published="2025-01-01T00:00:00.000Z")
        new = video("newnewnewne", "fr", "Bande-annonce 2 VF", published="2026-03-01T00:00:00.000Z")
        self.assertEqual(localize.pick([old, new])[0], "newnewnewne")


class LocalizerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.logs = []

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, fake, key="cle-v3-secrete"):
        return localize.TrailerLocalizer(key, self.tmp.name, opener=fake, log=self.logs.append)

    def test_chooses_french_and_caches(self):
        fake = FakeTMDB(videos=[video("vovovovovov", "en", "Official Trailer"),
                                video("vfvfvfvfvfv", "fr", "Bande-annonce VF")])
        loc = self.make(fake)
        self.assertEqual(loc.choose("tt0111161", "movie", ["addonaddona"]), ("vfvfvfvfvfv", "vf"))
        self.assertEqual(len(fake.requests), 2)  # /find puis /videos
        videos_url = fake.requests[1].full_url
        self.assertIn("/3/movie/278/videos", videos_url)
        self.assertIn("include_video_language=fr%2Cen%2Cnull", videos_url)
        # Deuxième demande : cache mémoire, puis cache disque (nouvelle instance).
        self.assertEqual(loc.choose("tt0111161", "movie", []), ("vfvfvfvfvfv", "vf"))
        self.assertEqual(len(fake.requests), 2)
        again = self.make(FakeTMDB())
        self.assertEqual(again.choose("tt0111161", "movie", []), ("vfvfvfvfvfv", "vf"))

    def test_series_and_tmdb_ids(self):
        fake = FakeTMDB(videos=[video("vostvostvos", "fr", "Bande-annonce VOSTFR")],
                        find={"movie_results": [], "tv_results": [{"id": 1396}]})
        loc = self.make(fake)
        self.assertEqual(loc.choose("tt0903747", "series", []), ("vostvostvos", "vostfr"))
        self.assertIn("/3/tv/1396/videos", fake.requests[1].full_url)
        fake2 = FakeTMDB(videos=[video("vfvfvfvfvfv", "fr", "VF")])
        self.assertEqual(self.make(fake2).choose("tmdb:603", "movie", []), ("vfvfvfvfvfv", "vf"))
        self.assertEqual(len(fake2.requests), 1)  # pas de /find pour un identifiant TMDB

    def test_vo_only_keeps_addon_trailer(self):
        fake = FakeTMDB(videos=[video("tmdbvovovov", "en", "Official Trailer")])
        self.assertEqual(self.make(fake).choose("tt0111161", "movie", ["addonaddona"]), ("addonaddona", "vo"))

    def test_fallbacks(self):
        # Sans clé : aucun appel, bande-annonce de l'addon.
        fake = FakeTMDB()
        loc = localize.TrailerLocalizer("", self.tmp.name, opener=fake)
        self.assertFalse(loc.enabled)
        self.assertEqual(loc.choose("tt0111161", "movie", ["bad", "addonaddona"]), ("addonaddona", "vo"))
        self.assertEqual(fake.requests, [])
        # Fiche hors IMDb/TMDB (kitsu…) : pas d'appel non plus.
        loc2 = self.make(FakeTMDB())
        self.assertEqual(loc2.choose("kitsu:1", "series", ["addonaddona"]), ("addonaddona", "vo"))
        # Rien du tout.
        self.assertEqual(self.make(FakeTMDB(videos=[])).choose("tt0000001", "movie", []), (None, None))

    def test_errors_never_log_the_key(self):
        loc = self.make(FakeTMDB(status=401), key="cle-v3-secrete")
        self.assertEqual(loc.choose("tt0111161", "movie", ["addonaddona"]), ("addonaddona", "vo"))
        self.assertTrue(any("401" in line for line in self.logs))
        self.assertFalse(any("cle-v3-secrete" in line for line in self.logs))
        with open(os.path.join(self.tmp.name, "localized.json")) as f:
            self.assertNotIn("cle-v3-secrete", f.read())

    def test_v4_token_goes_in_header(self):
        fake = FakeTMDB(videos=[video("vfvfvfvfvfv", "fr", "VF")])
        self.make(fake, key="eyJhbGciOi.jeton.v4").choose("tt0111161", "movie", [])
        req = fake.requests[0]
        self.assertEqual(req.get_header("Authorization"), "Bearer eyJhbGciOi.jeton.v4")
        self.assertNotIn("api_key", req.full_url)


if __name__ == "__main__":
    unittest.main()
