"""Tests des images du carrousel Top Shelf (aucun accès réseau : téléchargement simulé)."""
import io
import os
import sys
import tempfile
import unittest

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import topshelf  # noqa: E402


def jpeg(color, size=(1280, 720)):
    out = io.BytesIO()
    Image.new("RGB", size, color).save(out, "JPEG")
    return out.getvalue()


def png_logo():
    out = io.BytesIO()
    Image.new("RGBA", (800, 300), (255, 255, 255, 255)).save(out, "PNG")
    return out.getvalue()


class TopShelfTests(unittest.TestCase):
    def test_only_known_https_hosts(self):
        self.assertTrue(topshelf.is_allowed_image_url("https://images.metahub.space/background/large/tt1/img"))
        self.assertTrue(topshelf.is_allowed_image_url("https://image.tmdb.org/t/p/original/x.jpg"))
        for bad in ["http://images.metahub.space/x", "https://192.168.1.10/x", "https://evil.example/x",
                    "https://user@images.metahub.space/x", "file:///etc/passwd", "not a url"]:
            self.assertFalse(topshelf.is_allowed_image_url(bad), bad)

    def test_compose_title_without_logo(self):
        data = topshelf.compose(jpeg((40, 90, 160)), None, "Un titre de film assez long pour passer à la ligne")
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.size, (1920, 1080))
            # Le titre blanc est à gauche, au-dessus de 58 % de la hauteur ; la droite reste le fond.
            self.assertGreater(max(image.crop((96, 400, 900, 626)).convert("L").getdata()), 200)
            self.assertLess(image.getpixel((1800, 900))[0], 120)

    def test_compose_with_logo(self):
        data = topshelf.compose(jpeg((200, 60, 60)), png_logo(), "Ignoré")
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.size, (1920, 1080))
            self.assertGreater(image.getpixel((200, 560))[0], 230)  # logo blanc

    def test_ensure_caches_and_validates(self):
        calls = []

        def fetcher(url):
            calls.append(url)
            return jpeg((10, 10, 10)) if "background" in url else png_logo()

        with tempfile.TemporaryDirectory() as directory:
            bg = "https://images.metahub.space/background/large/tt1/img"
            logo = "https://images.metahub.space/logo/medium/tt1/img"
            first = topshelf.ensure(directory, "tt1", bg, logo, "Film", fetcher)
            second = topshelf.ensure(directory, "tt1", bg, logo, "Film", fetcher)
            self.assertEqual(first, second)
            self.assertEqual(len(calls), 2)  # deuxième appel servi par le cache
            with self.assertRaises(ValueError):
                topshelf.ensure(directory, "../x", bg, None, "", fetcher)
            with self.assertRaises(ValueError):
                topshelf.ensure(directory, "tt2", "https://evil.example/bg.jpg", None, "", fetcher)
            # Logo refusé : ignoré, l'image est faite avec le nom.
            path = topshelf.ensure(directory, "tt3", bg, "http://192.168.1.1/logo.png", "Film", fetcher)
            self.assertTrue(os.path.isfile(path))


if __name__ == "__main__":
    unittest.main()
