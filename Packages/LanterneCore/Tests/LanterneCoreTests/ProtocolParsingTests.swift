import Foundation
import Testing
@testable import LanterneCore

@Suite("Manifestes")
struct ManifestTests {
    @Test func decodesCinemetaLikeManifest() throws {
        let m = try Fixture.decode(AddonManifest.self, "cinemeta_manifest.json")
        #expect(m.id == "com.linvo.cinemeta")
        #expect(m.name == "Cinemeta")
        #expect(m.logo?.host == "example.com")
        #expect(m.background == nil, "une chaîne vide doit donner nil")
        #expect(m.types == ["movie", "series"])
        #expect(m.resources.map(\.name) == ["catalog", "meta", "addon_catalog"])
        // Doublon (movie/top) et catalogue invalide ignorés.
        #expect(m.catalogs.count == 3)
        let top = try #require(m.catalogs.first)
        #expect(top.supportsSearch && top.supportsSkip)
        #expect(top.genreOptions == ["Action", "Comedy", "Drama"])
        #expect(top.isBrowsableWithoutExtra)
        let year = m.catalogs[2]
        #expect(year.requiredExtras.map(\.name) == ["genre"])
        #expect(!year.isBrowsableWithoutExtra)
    }

    @Test func resourceSupportFollowsStremioRules() throws {
        let m = try Fixture.decode(AddonManifest.self, "cinemeta_manifest.json")
        #expect(m.supports(resource: "meta", type: "series", id: "tt0944947"))
        #expect(!m.supports(resource: "meta", type: "series", id: "kitsu:123"), "préfixe non déclaré")
        #expect(!m.supports(resource: "meta", type: "channel", id: "tt1"), "type non déclaré par la ressource")
        #expect(!m.supports(resource: "stream", type: "movie", id: "tt1"), "ressource absente")
        #expect(m.supports(resource: "catalog", type: "movie", id: nil))
    }

    @Test func decodesLegacyShortExtraForm() throws {
        let m = try Fixture.decode(AddonManifest.self, "legacy_manifest.json")
        #expect(m.version == "1", "version numérique tolérée")
        let c = try #require(m.catalogs.first)
        #expect(c.extra.map(\.name) == ["search", "skip"])
        #expect(c.requiredExtras.map(\.name) == ["search"])
        #expect(c.accepts([ExtraValue(name: "search", value: "x")]))
        #expect(!c.accepts([]))
        #expect(!c.accepts([ExtraValue(name: "search", value: "x"), ExtraValue(name: "genre", value: "y")]))
    }

    @Test func rejectsManifestWithoutID() {
        let data = Data(#"{"name":"x","types":[],"resources":[]}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AddonManifest.self, from: data) }
    }
}

@Suite("URL de ressources")
struct URLBuilderTests {
    let base = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!

    @Test func buildsSimpleResourceURL() throws {
        let url = try AddonURLBuilder.url(for: .meta(type: "series", id: "tt0944947"), transportURL: base)
        #expect(url.absoluteString == "https://v3-cinemeta.strem.io/meta/series/tt0944947.json")
    }

    @Test func encodesExtrasLikeEncodeURIComponent() throws {
        let req = ResourceRequest.catalog(type: "movie", id: "top", extra: [
            .init(name: "search", value: "Le Fabuleux Destin d'Amélie"), .init(name: "skip", value: "100"),
        ])
        let url = try AddonURLBuilder.url(for: req, transportURL: base)
        #expect(url.absoluteString ==
            "https://v3-cinemeta.strem.io/catalog/movie/top/search=Le%20Fabuleux%20Destin%20d'Am%C3%A9lie&skip=100.json")
    }

    @Test func encodesSeriesVideoIDColons() throws {
        let url = try AddonURLBuilder.url(for: .stream(type: "series", id: "tt0944947:1:2"), transportURL: base)
        #expect(url.absoluteString == "https://v3-cinemeta.strem.io/stream/series/tt0944947%3A1%3A2.json")
    }

    @Test func keepsConfiguredPathAndQuery() throws {
        let configured = URL(string: "https://addon.example.com/eyJrZXkiOiJ2In0/manifest.json")!
        let url = try AddonURLBuilder.url(for: .stream(type: "movie", id: "tt1"), transportURL: configured)
        #expect(url.absoluteString == "https://addon.example.com/eyJrZXkiOiJ2In0/stream/movie/tt1.json")
    }

    @Test func normalizesUserInput() throws {
        #expect(try AddonURLBuilder.normalizeManifestURL("stremio://addon.example.com/abc/manifest.json").absoluteString
            == "https://addon.example.com/abc/manifest.json")
        #expect(try AddonURLBuilder.normalizeManifestURL(" https://addon.example.com/abc/ ").absoluteString
            == "https://addon.example.com/abc/manifest.json")
        #expect(throws: AddonURLError.unsupportedScheme) { try AddonURLBuilder.normalizeManifestURL("ftp://x.com/manifest.json") }
        #expect(throws: (any Error).self) { try AddonURLBuilder.normalizeManifestURL("pas une url") }
    }

    @Test func refusesNonManifestTransport() {
        #expect(throws: AddonURLError.notAManifestURL) {
            try AddonURLBuilder.url(for: .meta(type: "movie", id: "tt1"), transportURL: URL(string: "https://x.com/api")!)
        }
    }
}

@Suite("Catalogues et fiches")
struct MetaTests {
    @Test func catalogSkipsMalformedItems() throws {
        let r = try Fixture.decode(CatalogResponse.self, "catalog_movies.json")
        #expect(r.metas.map(\.id) == ["tt0111161", "tt0068646", "tt0468569"])
        #expect(r.cacheMaxAge == 3600)
        #expect(r.metas[1].releaseInfo == "1972", "nombre accepté comme chaîne")
        #expect(r.metas[1].imdbRating == "9.2")
        #expect(r.metas[1].poster == nil, "affiche vide → nil")
        #expect(r.metas[2].poster == nil, "schéma non HTTP refusé")
        #expect(r.metas[2].posterShape == .landscape)
    }

    @Test func decodesSeriesDetail() throws {
        let meta = try #require(try Fixture.decode(MetaResponse.self, "meta_series.json").meta)
        #expect(meta.isSeries)
        #expect(meta.genres == ["Drama", "Fantasy"], "genres repris des liens")
        #expect(meta.cast == ["Emilia Clarke"])
        #expect(meta.directors == ["David Benioff"])
        #expect(meta.imdbRating == "9.2", "note issue du lien imdb")
        #expect(meta.trailerYouTubeIDs == ["rlZFgDHzEDE"])
        #expect(meta.defaultVideoID == nil)
        // Doublon supprimé, tri saison/épisode, spéciaux en dernier.
        #expect(meta.videos.map(\.id) == ["tt0944947:1:1", "tt0944947:1:2", "tt0944947:2:1", "tt0944947:9:1", "tt0944947:0:1"])
        #expect(meta.seasons == [1, 2, 9, 0])
        let e1 = meta.videos[0]
        #expect(e1.episode == 1, "champ historique `number`")
        #expect(e1.episodeCode == "S01E01")
        #expect(e1.released == date("2011-04-17T02:00:00.000Z"))
        #expect(meta.videos[3].isReleased(asOf: date("2026-11-01T00:00:00Z")) == false)
    }

    @Test func nullMetaIsNotAnError() throws {
        let r = try JSONDecoder().decode(MetaResponse.self, from: Data(#"{"meta":null}"#.utf8))
        #expect(r.meta == nil)
    }

    @Test func previewDetailMergeKeepsKnownFields() throws {
        let preview = MetaItem(id: "tt1", type: "movie", name: "Titre", poster: URL(string: "https://example.com/p.jpg"),
                               releaseInfo: "2020", genres: ["Drama"])
        let detail = MetaItem(id: "tt1", type: "movie", name: "", description: "Synopsis")
        let merged = preview.merged(withDetail: detail)
        #expect(merged.name == "Titre")
        #expect(merged.poster == preview.poster)
        #expect(merged.description == "Synopsis")
        #expect(merged.genres == ["Drama"])
    }

    @Test func roundTripsThroughLocalCache() throws {
        let meta = try #require(try Fixture.decode(MetaResponse.self, "meta_series.json").meta)
        let again = try JSONDecoder().decode(MetaItem.self, from: JSONEncoder().encode(meta))
        #expect(again == meta)
    }
}

@Suite("Flux et sous-titres")
struct StreamParsingTests {
    @Test func decodesAllSourceKinds() throws {
        let r = try Fixture.decode(StreamsResponse.self, "streams_mixed.json")
        #expect(r.streams.count == 8, "le flux sans source est ignoré")
        guard case .url(let u) = r.streams[0].source else { Issue.record("url attendue"); return }
        #expect(u.lastPathComponent == "movie.mkv")
        #expect(r.streams[1].description?.hasPrefix("Movie.2026.MULTi") == true, "alias `title`")
        guard case .torrent(let hash, let idx, let announce, _) = r.streams[2].source else { Issue.record("torrent attendu"); return }
        #expect(hash == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(idx == 2)
        #expect(announce.count == 2, "alias `sources`")
        guard case .torrent(let mHash, _, let trackers, _) = r.streams[3].source else { Issue.record("magnet → torrent"); return }
        #expect(mHash == "0123456789abcdef0123456789abcdef01234567")
        #expect(trackers == ["udp://t.example.com:1337"])
        #expect(r.streams[4].source == .youtube("dQw4w9WgXcQ"))
        #expect(r.streams[5].source == .external(URL(string: "https://example.com/watch")!))
        #expect(r.streams[7].source == .archive(kind: "rar"))
    }

    @Test func filtersUnsafeProxyHeaders() throws {
        let r = try Fixture.decode(StreamsResponse.self, "streams_mixed.json")
        let headers = try #require(r.streams[0].behaviorHints.proxyHeaders?.request)
        #expect(headers == ["User-Agent": "Lanterne", "Referer": "https://example.com/"])
        #expect(r.streams[0].behaviorHints.videoSize == 62_491_426_816)
        #expect(r.streams[0].behaviorHints.bingeGroup == "example-4k")
    }

    @Test func subtitlesRequireHTTPURLs() throws {
        let r = try Fixture.decode(SubtitlesResponse.self, "subtitles.json")
        #expect(r.subtitles.map(\.id) == ["1234", "5678"])
        #expect(r.subtitles[1].label == "English SDH")
    }

    @Test func fingerprintIsStable() throws {
        let r = try Fixture.decode(StreamsResponse.self, "streams_mixed.json")
        #expect(r.streams[2].fingerprint == "bt:abcdef0123456789abcdef0123456789abcdef01:2")
        let again = try JSONDecoder().decode(StreamItem.self, from: JSONEncoder().encode(r.streams[2]))
        #expect(again.fingerprint == r.streams[2].fingerprint)
    }
}
