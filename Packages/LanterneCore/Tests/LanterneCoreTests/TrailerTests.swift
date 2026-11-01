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
