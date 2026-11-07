"""Tests de la découverte TMDB (recommandations, collections), TMDB simulé."""
import io
import json
import re
import tempfile
import unittest
import urllib.parse

import discovery
import localize


class FakeTMDB:
    def __init__(self):
        self.requests = []

    def __call__(self, req, timeout=None):
        path = urllib.parse.urlsplit(req.full_url).path
        self.requests.append(path)
        routes = {
            "/3/find/tt0133093": {"movie_results": [{"id": 603}], "tv_results": []},
            "/3/movie/603/recommendations": {"results": [
                {"id": 604, "media_type": "movie", "title": "Matrix Reloaded", "release_date": "2003-05-15",
                 "poster_path": "/p604.jpg", "backdrop_path": "/b604.jpg"},
                {"id": 999, "media_type": "movie", "title": "Sans IMDb", "release_date": "2020-01-01"},
                {"id": 1399, "media_type": "tv", "name": "Game of Thrones", "first_air_date": "2011-04-17",
                 "poster_path": "/../evil"},
            ]},
            "/3/movie/603": {"id": 603, "belongs_to_collection": {"id": 2344, "name": "Matrix - Saga"}},
            "/3/collection/2344": {"name": "Matrix - Saga", "parts": [
                {"id": 605, "title": "Matrix Revolutions", "release_date": "2003-11-05"},
                {"id": 603, "title": "Matrix", "release_date": "1999-03-30", "poster_path": "/p603.jpg"},
                {"id": 604, "title": "Matrix Reloaded", "release_date": "2003-05-15"},
            ]},
            "/3/movie/603/external_ids": {"imdb_id": "tt0133093"},
            "/3/movie/604/external_ids": {"imdb_id": "tt0234215"},
            "/3/movie/605/external_ids": {"imdb_id": "tt0242653"},
            "/3/movie/999/external_ids": {"imdb_id": None},
            "/3/tv/1399/external_ids": {"imdb_id": "tt0944947"},
            "/3/find/tt0000001": {"movie_results": [{"id": 1}], "tv_results": []},
            "/3/movie/1": {"id": 1, "belongs_to_collection": None},
        }
        body = routes.get(path)
        if body is None:
            raise localize.urllib.error.HTTPError(req.full_url, 404, "absent", {}, None)
        return io.BytesIO(json.dumps(body).encode())


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake = FakeTMDB()
        self.logs = []
        loc = localize.TrailerLocalizer("cle-secrete", None, opener=self.fake, log=self.logs.append)
        self.finder = discovery.Discovery(loc, self.tmp.name, log=self.logs.append)

    def tearDown(self):
        self.tmp.cleanup()

    def test_recommendations_keep_only_titles_with_imdb(self):
        items = self.finder.recommendations("tt0133093", "movie")
        self.assertEqual([i["imdb"] for i in items], ["tt0234215", "tt0944947"])
        self.assertEqual(items[0], {"imdb": "tt0234215", "type": "movie", "title": "Matrix Reloaded", "year": 2003,
                                    "poster": "https://image.tmdb.org/t/p/w342/p604.jpg",
                                    "background": "https://image.tmdb.org/t/p/w1280/b604.jpg"})
        self.assertEqual(items[1]["type"], "series")
        self.assertIsNone(items[1]["poster"])  # chemin d'image douteux refusé
        # Cache : aucun nouvel appel.
        before = len(self.fake.requests)
        self.assertEqual(self.finder.recommendations("tt0133093", "movie"), items)
        self.assertEqual(len(self.fake.requests), before)

    def test_collection_is_sorted_by_release(self):
        saga = self.finder.collection("tt0133093")
        self.assertEqual(saga["name"], "Matrix - Saga")
        self.assertEqual([p["imdb"] for p in saga["parts"]], ["tt0133093", "tt0234215", "tt0242653"])
        self.assertEqual(saga["parts"][0]["year"], 1999)
        self.assertIsNone(self.finder.collection("tt0000001"))

    def test_disabled_without_key_and_bad_ids(self):
        loc = localize.TrailerLocalizer("", None, opener=self.fake)
        finder = discovery.Discovery(loc, None)
        self.assertFalse(finder.enabled)
        self.assertIsNone(finder.recommendations("tt0133093", "movie"))
        self.assertIsNone(self.finder.recommendations("../etc", "movie"))
        self.assertFalse(any("cle-secrete" in line for line in self.logs))

    def test_image_paths(self):
        self.assertEqual(discovery.image("/a.jpg", "w342"), "https://image.tmdb.org/t/p/w342/a.jpg")
        for bad in [None, "a.jpg", "/../x", "/" + "a" * 300]:
            self.assertIsNone(discovery.image(bad, "w342"))
        self.assertTrue(re.match(r"^https://image\.tmdb\.org/", discovery.IMAGE_BASE))


if __name__ == "__main__":
    unittest.main()
