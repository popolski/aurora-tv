"""Tests du service aurora-trailers (sans réseau : yt-dlp est remplacé par un faux)."""
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import server  # noqa: E402

FAKE_YTDLP = """#!/bin/sh
# Faux yt-dlp : écrit un fichier de 1000 octets à l'emplacement demandé (-o), ou échoue pour « failfailfai ».
out=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
case "$a" in *failfailfai*) echo "ERROR: Video unavailable" >&2; exit 1;; esac
if [ "$1" = "--version" ]; then echo "2099.01.01"; exit 0; fi
target=$(echo "$out" | sed 's/%(ext)s/mp4/')
head -c 1000 /dev/zero > "$target"
"""


class ParsingTests(unittest.TestCase):
    def test_ids(self):
        self.assertTrue(server.is_valid_id("dQw4w9WgXcQ"))
        self.assertFalse(server.is_valid_id("../../etc/x"))
        self.assertFalse(server.is_valid_id("short"))
        self.assertFalse(server.is_valid_id(None))

    def test_ranges(self):
        self.assertIsNone(server.parse_range(None, 100))
        self.assertEqual(server.parse_range("bytes=0-1", 100), (0, 1))
        self.assertEqual(server.parse_range("bytes=10-", 100), (10, 99))
        self.assertEqual(server.parse_range("bytes=-10", 100), (90, 99))
        self.assertEqual(server.parse_range("bytes=50-500", 100), (50, 99))
        for bad in ["bytes=100-", "bytes=5-2", "bytes=-", "items=0-1", "bytes=-0"]:
            with self.assertRaises(ValueError, msg=bad):
                server.parse_range(bad, 100)


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        bindir = os.path.join(cls.tmp.name, "bin")
        os.makedirs(bindir)
        fake = os.path.join(bindir, "yt-dlp")
        with open(fake, "w") as f:
            f.write(FAKE_YTDLP)
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        cls.old_path = os.environ["PATH"]
        # Sans ffmpeg dans ce PATH réduit : on teste le chemin « fichier conservé tel quel ».
        os.environ["PATH"] = bindir + os.pathsep + "/bin" + os.pathsep + "/usr/bin"
        cls.cache = server.Cache(os.path.join(cls.tmp.name, "cache"), max_mb=1)
        cls.httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(cls.cache))
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        os.environ["PATH"] = cls.old_path
        cls.tmp.cleanup()

    def get(self, path, headers=None):
        req = urllib.request.Request(self.base + path, headers=headers or {})
        return urllib.request.urlopen(req, timeout=20)

    def test_download_then_range(self):
        with self.get("/trailer/abcdefghijk.mp4") as r:
            self.assertEqual(r.status, 200)
            self.assertEqual(r.headers["Content-Type"], "video/mp4")
            self.assertEqual(len(r.read()), 1000)
        with self.get("/trailer/abcdefghijk.mp4", {"Range": "bytes=0-1"}) as r:
            self.assertEqual(r.status, 206)
            self.assertEqual(r.headers["Content-Range"], "bytes 0-1/1000")
            self.assertEqual(len(r.read()), 2)

    def test_failure_is_remembered(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/trailer/failfailfai.mp4")
        self.assertEqual(ctx.exception.code, 404)
        self.assertTrue(self.cache.recently_failed("failfailfai"))

    def test_rejects_bad_paths(self):
        for path in ["/trailer/../../etc/passwd", "/trailer/abc.mp4", "/other"]:
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                self.get(path)
            self.assertEqual(ctx.exception.code, 404)

    def test_prefetch_and_health(self):
        body = json.dumps({"ids": ["zzzzzzzzzzz", "bad id", "../x"]}).encode()
        req = urllib.request.Request(self.base + "/prefetch", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            self.assertEqual(r.status, 202)
            self.assertEqual(json.loads(r.read())["queued"], 1)
        with self.get("/health") as r:
            self.assertTrue(json.loads(r.read())["ok"])

    def test_old_video_only_files_are_dropped(self):
        directory = os.path.join(self.tmp.name, "old")
        os.makedirs(directory)
        old = os.path.join(directory, "bbbbbbbbbbb.mp4")
        open(old, "wb").close()
        cache = server.Cache(directory, max_mb=10)
        self.assertFalse(os.path.exists(old))
        self.assertTrue(cache.path("bbbbbbbbbbb").endswith("bbbbbbbbbbb.av.mp4"))

    def test_format_needs_ffmpeg_to_merge(self):
        self.assertIn("+ba", server.video_format(1080, True))
        self.assertNotIn("+ba", server.video_format(1080, False))

    def test_eviction_keeps_cache_under_limit(self):
        cache = server.Cache(os.path.join(self.tmp.name, "small"), max_mb=0)
        p = cache.path("aaaaaaaaaaa")
        with open(p, "wb") as f:
            f.write(b"x" * 10)
        cache.evict()
        self.assertFalse(os.path.exists(p))


if __name__ == "__main__":
    unittest.main()
