import Foundation
import Testing
@testable import LanterneCore

@Suite("Bandes-annonces")
struct TrailerTests {
    @Test func acceptsOnlyYouTubeIDs() {
        #expect(TrailerLink.isValidYouTubeID("dQw4w9WgXcQ"))
        #expect(TrailerLink.isValidYouTubeID("a-b_c123XYZ"))
        #expect(!TrailerLink.isValidYouTubeID("short"))
        #expect(!TrailerLink.isValidYouTubeID("../../etc/pa"))
        #expect(!TrailerLink.isValidYouTubeID("abc def ghij"))
        #expect(!TrailerLink.isValidYouTubeID("abcdefghijé"))
    }

    @Test func buildsVideoURL() throws {
        let server = try #require(URL(string: "http://192.168.1.20:8787"))
        #expect(TrailerLink.videoURL(server: server, youTubeID: "dQw4w9WgXcQ")?.absoluteString
                == "http://192.168.1.20:8787/trailer/dQw4w9WgXcQ.mp4")
        #expect(TrailerLink.videoURL(server: server, youTubeID: "../secret") == nil)
        #expect(TrailerLink.previewURL(server: server, youTubeID: "dQw4w9WgXcQ")?.absoluteString
                == "http://192.168.1.20:8787/trailer/dQw4w9WgXcQ.preview.mp4")
    }

    @Test func buildsPerTitleURLsForFrenchTrailers() throws {
        let server = try #require(URL(string: "http://192.168.1.20:8787"))
        let movie = MetaItem(id: "tt0111161", type: "movie", name: "Les Évadés",
                             trailerYouTubeIDs: ["../bad", "dQw4w9WgXcQ", "a-b_c123XYZ"])
        #expect(TrailerLink.itemVideoURL(server: server, meta: movie)?.absoluteString
                == "http://192.168.1.20:8787/trailer/for/tt0111161.mp4?type=movie&yt=dQw4w9WgXcQ&yt=a-b_c123XYZ")
        #expect(TrailerLink.itemPreviewURL(server: server, meta: movie)?.absoluteString
                == "http://192.168.1.20:8787/trailer/for/tt0111161.preview.mp4?type=movie&yt=dQw4w9WgXcQ&yt=a-b_c123XYZ")
        let series = MetaItem(id: "tt0903747", type: "series", name: "Breaking Bad", trailerYouTubeIDs: ["dQw4w9WgXcQ"])
        #expect(TrailerLink.prefetchItem(for: series) == .init(id: "tt0903747", type: "series", yt: ["dQw4w9WgXcQ"]))
        // Sans bande-annonce connue de l'addon, ou identifiant de fiche douteux : rien.
        #expect(TrailerLink.itemVideoURL(server: server, meta: MetaItem(id: "tt1", type: "movie", name: "x")) == nil)
        let odd = MetaItem(id: "../x", type: "movie", name: "x", trailerYouTubeIDs: ["dQw4w9WgXcQ"])
        #expect(TrailerLink.itemVideoURL(server: server, meta: odd) == nil)
        #expect(TrailerLink.prefetchItem(for: odd) == nil)
    }

    @Test func topShelfImageURLEncodesParameters() throws {
        let server = try #require(URL(string: "http://192.168.1.20:8787"))
        let meta = MetaItem(id: "tt1", type: "movie", name: "Fast & Furious + 1",
                            background: URL(string: "https://images.metahub.space/background/large/tt1/img?a=1&b=2"),
                            logo: URL(string: "https://images.metahub.space/logo/medium/tt1/img"))
        let url = try #require(TrailerLink.topShelfImageURL(server: server, meta: meta))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.path == "/topshelf/tt1.jpg")
        #expect(items.first { $0.name == "bg" }?.value == "https://images.metahub.space/background/large/tt1/img?a=1&b=2")
        #expect(items.first { $0.name == "title" }?.value == "Fast & Furious + 1")
        #expect(url.absoluteString.contains("Fast%20%26%20Furious%20%2B%201"))
        #expect(TrailerLink.topShelfImageURL(server: server, meta: MetaItem(id: "tt1", type: "movie", name: "x")) == nil)
    }

    @Test func serverValidation() {
        var p = TrailerPreferences()
        #expect(p.server == nil)
        p.serverURL = "  http://nas.local:8787 "
        #expect(p.server?.host == "nas.local")
        p.serverURL = "file:///etc"
        #expect(p.server == nil)
    }

    @Test func oldSettingsDecodeWithTrailerDefaults() throws {
        let data = Data(#"{"hideAdultContent":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.hideAdultContent == false)
        #expect(settings.trailers == TrailerPreferences())
    }

    @Test func firstValidIDSkipsGarbage() {
        let meta = MetaItem(id: "tt1", type: "movie", name: "X", trailerYouTubeIDs: ["bad id", "dQw4w9WgXcQ"])
        #expect(TrailerLink.firstValidID(in: meta) == "dQw4w9WgXcQ")
    }
}

@Suite("Sorties en salle")
struct CinemaStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recentMovieIsInTheaters() {
        let meta = MetaItem(id: "tt1", type: "movie", name: "X", released: now.addingTimeInterval(-20 * 86_400))
        #expect(meta.cinemaStatus(now: now) == .inTheaters)
    }

    @Test func olderMovieIsNot() {
        let meta = MetaItem(id: "tt1", type: "movie", name: "X", released: now.addingTimeInterval(-90 * 86_400))
        #expect(meta.cinemaStatus(now: now) == nil)
    }

    @Test func futureMovieIsUpcoming() {
        let date = now.addingTimeInterval(10 * 86_400)
        let meta = MetaItem(id: "tt1", type: "movie", name: "X", released: date)
        #expect(meta.cinemaStatus(now: now) == .upcoming(date))
    }

    @Test func seriesAndUndatedAreIgnored() {
        #expect(MetaItem(id: "tt1", type: "series", name: "X", released: now).cinemaStatus(now: now) == nil)
        #expect(MetaItem(id: "tt1", type: "movie", name: "X").cinemaStatus(now: now) == nil)
    }
}
