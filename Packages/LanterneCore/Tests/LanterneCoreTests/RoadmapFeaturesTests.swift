import Foundation
import Testing
@testable import LanterneCore

/// Générateur déterministe pour les tirages.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func item(_ id: String, _ type: String, inLibrary: Bool = true, watched: Bool = false,
                  offset: Int64 = 0, duration: Int64 = 0, video: String? = nil, added: TimeInterval = 0) -> LibraryItem {
    var state = WatchState()
    state.timesWatched = watched ? 1 : 0
    state.timeOffset = offset
    state.duration = duration
    state.videoID = video
    return LibraryItem(id: id, type: type, name: "Titre \(id)", poster: URL(string: "https://example.com/\(id).jpg"),
                       removed: !inLibrary, temp: false, ctime: Date(timeIntervalSince1970: added),
                       mtime: Date(timeIntervalSince1970: added), state: state)
}

@Suite("Top Shelf au choix")
struct TopShelfChoiceTests {
    @Test func entriesFollowTheChosenSource() {
        let watching = [item("tt0000001", "movie", offset: 600_000, duration: 6_000_000),
                        item("tt0000002", "series", offset: 60_000, duration: 2_400_000, video: "tt0000002:2:3"),
                        item("tt0000009", "other", offset: 1, duration: 2)]
        let library = [item("tt0000003", "movie", added: 10), item("tt0000004", "series", added: 30),
                       item("tt0000005", "movie", inLibrary: false, added: 50), item("tt0000006", "other", added: 40)]
        #expect(TopShelfEntry.entries(for: .latest, continueWatching: watching, library: library).isEmpty)

        let cw = TopShelfEntry.entries(for: .continueWatching, continueWatching: watching, library: library)
        #expect(cw.map(\.id) == ["tt0000001", "tt0000002"])  // type « other » écarté
        #expect(cw[0].remaining == 5400)
        #expect(cw[1].episode == "S02E03")

        let list = TopShelfEntry.entries(for: .myList, continueWatching: watching, library: library)
        #expect(list.map(\.id) == ["tt0000004", "tt0000003"])
        #expect(list.allSatisfy { $0.remaining == nil })
    }

    @Test func configStaysReadableAcrossVersions() throws {
        // Configuration écrite par une version précédente (sans source ni entrées).
        let old = Data(#"{"trailerServer":"http://192.168.1.20:8787","updatedAt":800000000}"#.utf8)
        let decoded = try JSONDecoder().decode(TopShelfConfig.self, from: old)
        #expect(decoded.source == .latest && decoded.entries.isEmpty)
        #expect(decoded.server?.absoluteString == "http://192.168.1.20:8787")

        let config = TopShelfConfig(trailerServer: nil, source: .myList,
                                    entries: [TopShelfEntry(id: "tt0000003", type: "movie", name: "A")])
        let roundTrip = try JSONDecoder().decode(TopShelfConfig.self, from: JSONEncoder().encode(config))
        #expect(roundTrip.sameContent(as: config))
        #expect(!roundTrip.sameContent(as: TopShelfConfig(trailerServer: nil)))

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"topShelfSource":"inconnu"}"#.utf8))
        #expect(settings.topShelfSource == .latest)
    }

    @Test func metaURLChecksTheType() {
        #expect(TopShelfFeed.metaURL(id: "tt0903747", type: "series")?.absoluteString
                == "https://v3-cinemeta.strem.io/meta/series/tt0903747.json")
        #expect(TopShelfFeed.metaURL(id: "tt0903747", type: "../x") == nil)
        #expect(EpisodeCode.from(videoID: "tt1:1:12") == "S01E12")
        #expect(EpisodeCode.from(videoID: "tt1") == nil)
    }
}

@Suite("Je ne sais pas quoi regarder")
struct SurprisePickerTests {
    private let library = [item("tt0000001", "movie"), item("tt0000002", "movie", watched: true),
                           item("tt0000003", "series", watched: true), item("tt0000004", "movie", inLibrary: false),
                           item("tt0000005", "series"), item("tt0000006", "other")]

    @Test func candidatesSkipWatchedMoviesAndOtherTypes() {
        var g = SeededGenerator(state: 1)
        let all = SurprisePicker.candidates(from: library, kind: .any, alreadyShown: [], using: &g)
        #expect(Set(all.map(\.id)) == ["tt0000001", "tt0000003", "tt0000005"])
        let movies = SurprisePicker.candidates(from: library, kind: .movies, alreadyShown: [], using: &g)
        #expect(movies.map(\.id) == ["tt0000001"])
        let series = SurprisePicker.candidates(from: library, kind: .series, alreadyShown: [], using: &g)
        #expect(Set(series.map(\.id)) == ["tt0000003", "tt0000005"])
    }

    @Test func noRepeatUntilEverythingWasShown() {
        var g = SeededGenerator(state: 7)
        let next = SurprisePicker.candidates(from: library, kind: .series, alreadyShown: ["tt0000003"], using: &g)
        #expect(next.map(\.id) == ["tt0000005"])
        // Tout a été proposé : on recommence plutôt que de ne rien proposer.
        let again = SurprisePicker.candidates(from: library, kind: .series, alreadyShown: ["tt0000003", "tt0000005"], using: &g)
        #expect(again.count == 2)
    }

    @Test func durationFilter() {
        #expect(SurpriseDuration.any.accepts(runtime: nil))
        #expect(SurpriseDuration.short.accepts(runtime: 85 * 60))
        #expect(!SurpriseDuration.short.accepts(runtime: 95 * 60))
        #expect(SurpriseDuration.medium.accepts(runtime: 118 * 60))
        #expect(!SurpriseDuration.medium.accepts(runtime: nil))
    }
}

@Suite("Sagas (Wikidata)")
struct SagaTests {
    private static func sparql(_ rows: [[String: String]]) -> Data {
        let bindings = rows.map { row in row.mapValues { ["type": "literal", "value": $0] } }
        return try! JSONSerialization.data(withJSONObject: ["results": ["bindings": bindings]])
    }

    private static let film = "http://www.wikidata.org/entity/Q11424"

    @Test func requestIsStrictAndOrdered() {
        let query = SagaClient.requestURL(imdbID: "tt0120737")?.absoluteString.removingPercentEncoding ?? ""
        #expect(query.contains("\"tt0120737\""))
        #expect(query.contains("hint:optimizer \"None\""))
        #expect(SagaClient.requestURL(imdbID: "tt1\" }") == nil)
    }

    @Test func picksTheSagaWithARankAndSortsIt() {
        let data = Self.sparql([
            // Trilogie (rangs renseignés).
            ["saga": "http://www.wikidata.org/entity/Q190214", "sagaFr": "Le Seigneur des anneaux", "imdb": "tt0167260",
             "ordinal": "3", "date": "2003-12-01T00:00:00Z", "fr": "Le Retour du roi", "types": Self.film],
            ["saga": "http://www.wikidata.org/entity/Q190214", "sagaFr": "Le Seigneur des anneaux", "imdb": "tt0120737",
             "ordinal": "1", "date": "2001-12-10T00:00:00Z", "fr": "La Communauté de l'anneau", "types": Self.film],
            ["saga": "http://www.wikidata.org/entity/Q190214", "sagaFr": "Le Seigneur des anneaux", "imdb": "tt0167261",
             "ordinal": "2", "date": "2002-12-05T00:00:00Z", "fr": "Les Deux Tours", "types": Self.film],
            // Franchise plus large, sans rang pour ce film.
            ["saga": "http://www.wikidata.org/entity/Q1", "sagaEn": "Middle-earth", "imdb": "tt0120737",
             "en": "The Fellowship", "types": Self.film],
            ["saga": "http://www.wikidata.org/entity/Q1", "sagaEn": "Middle-earth", "imdb": "tt0903624",
             "en": "The Hobbit", "types": Self.film],
            ["saga": "http://www.wikidata.org/entity/Q1", "sagaEn": "Middle-earth", "imdb": "tt9999990",
             "en": "A game", "types": "http://www.wikidata.org/entity/Q7889"],
        ])
        let saga = SagaClient.parse(data, current: "tt0120737")
        #expect(saga?.name == "Le Seigneur des anneaux")
        #expect(saga?.parts.map(\.imdbID) == ["tt0120737", "tt0167261", "tt0167260"])
        #expect(saga?.parts.first?.year == 2001)
    }

    @Test func noRankFallsBackToYearAndSingleWorkIsNoSaga() {
        let data = Self.sparql([
            ["saga": "http://www.wikidata.org/entity/Q2", "sagaFr": "Saga X", "imdb": "tt0000020", "date": "1990-01-01T00:00:00Z", "fr": "Deux"],
            ["saga": "http://www.wikidata.org/entity/Q2", "sagaFr": "Saga X", "imdb": "tt0000010", "date": "1985-01-01T00:00:00Z", "fr": "Un"],
        ])
        #expect(SagaClient.parse(data, current: "tt0000020")?.parts.map(\.title) == ["Un", "Deux"])
        let single = Self.sparql([["saga": "http://www.wikidata.org/entity/Q3", "imdb": "tt0000030", "fr": "Seul"]])
        #expect(SagaClient.parse(single, current: "tt0000030") == nil)
    }
}

@Suite("Sauvegarde des réglages")
struct SettingsBackupTests {
    @Test func roundTripKeepsTheCurrentServer() throws {
        var settings = AppSettings()
        settings.topShelfSource = .myList
        settings.trailers.serverURL = "http://ancien-nas:8787"
        settings.playback.stillWatchingAfter = 2
        let data = try SettingsBackup(settings: settings, device: "Apple TV",
                                      createdAt: Date(timeIntervalSince1970: 1_800_000_000)).encoded()
        let backup = try SettingsBackup.decode(data)
        #expect(backup.device == "Apple TV")
        var current = AppSettings()
        current.trailers.serverURL = "http://192.168.1.120:8787"
        let restored = backup.restoring(onto: current)
        #expect(restored.topShelfSource == .myList)
        #expect(restored.playback.stillWatchingAfter == 2)
        #expect(restored.trailers.serverURL == "http://192.168.1.120:8787")
    }

    @Test func rejectsWhatIsNotABackup() {
        #expect(throws: SettingsBackup.RestoreError.notABackup) { try SettingsBackup.decode(Data("{}".utf8)) }
        #expect(throws: SettingsBackup.RestoreError.notABackup) {
            try SettingsBackup.decode(Data(#"{"version":1,"app":"Autre","createdAt":"2026-11-06T10:00:00Z","device":"x","settings":{}}"#.utf8))
        }
        #expect(throws: SettingsBackup.RestoreError.newerVersion(9)) {
            try SettingsBackup.decode(Data(#"{"version":9,"app":"Aurora","createdAt":"2026-11-06T10:00:00Z","device":"x","settings":{}}"#.utf8))
        }
    }

    @Test func urls() throws {
        let server = try #require(URL(string: "http://192.168.1.120:8787"))
        #expect(TrailerLink.backupURL(server: server).absoluteString == "http://192.168.1.120:8787/backup")
        #expect(TrailerLink.latestBackupURL(server: server).absoluteString == "http://192.168.1.120:8787/backup/latest.json")
    }
}
