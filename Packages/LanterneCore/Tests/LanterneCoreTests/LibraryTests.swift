import Foundation
import Testing
@testable import LanterneCore

private func seriesVideos() throws -> [MetaVideo] {
    try #require(try Fixture.decode(MetaResponse.self, "meta_series.json").meta).videos
}

private let got = LibraryMetaRef(id: "tt0944947", type: "series", name: "Game of Thrones")
private let movie = LibraryMetaRef(id: "tt0111161", type: "movie", name: "The Shawshank Redemption")

@Suite("Champ « épisodes vus » (bitfield Stremio)")
struct WatchedBitFieldTests {
    let ids: [String] = (1...2).flatMap { s in (1...10).map { "tt0944947:\(s):\($0)" } }

    @Test func decodesReferenceVector() throws {
        let vector = try Fixture.string("watched_bitfield_vector.txt")
        let field = try WatchedBitField(serialized: vector, videoIDs: ids)
        #expect(field.watchedIDs == ["tt0944947:1:1", "tt0944947:1:2", "tt0944947:1:5", "tt0944947:2:3"])
    }

    @Test func resizesWhenVideosAreAppendedOrShifted() throws {
        let vector = try Fixture.string("watched_bitfield_vector.txt")
        let grown = try WatchedBitField(serialized: vector, videoIDs: ids + ["tt0944947:3:1", "tt0944947:3:2"])
        #expect(grown.watchedIDs.count == 4)
        let shifted = try WatchedBitField(serialized: vector, videoIDs: Array(ids.dropFirst(2)))
        #expect(shifted.watchedIDs == ["tt0944947:1:5", "tt0944947:2:3"], "même résultat que l'implémentation JS")
    }

    @Test func unknownAnchorGivesBlankField() throws {
        let vector = try Fixture.string("watched_bitfield_vector.txt")
        let other = try WatchedBitField(serialized: vector, videoIDs: ["tt1:1:1", "tt1:1:2"])
        #expect(other.watchedIDs.isEmpty)
    }

    @Test func serializeRoundTrip() throws {
        var f = WatchedBitField(videoIDs: ids)
        f.setWatched("tt0944947:1:3", true)
        f.setWatched("tt0944947:2:10", true)
        let s = try f.serialize()
        #expect(s.hasPrefix("tt0944947:2:10:20:"), "ancre = dernier épisode vu")
        let back = try WatchedBitField(serialized: s, videoIDs: ids)
        #expect(back.watchedIDs == ["tt0944947:1:3", "tt0944947:2:10"])
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try WatchedBitField(serialized: "nope", videoIDs: ["a"]) }
        #expect(throws: (any Error).self) { try WatchedBitField(serialized: "a:1:!!!", videoIDs: ["a"]) }
    }

    @Test func orderMatchesStremioCore() throws {
        // Dans le bitfield, la saison 0 est triée numériquement (en premier),
        // contrairement à l'affichage.
        let order = WatchedBitField.orderedVideoIDs(try seriesVideos())
        #expect(order.first == "tt0944947:0:1")
        #expect(order.last == "tt0944947:9:1")
    }
}

@Suite("Bibliothèque et progression")
struct LibraryStoreTests {
    func makeStore(file: InMemoryStore = InMemoryStore(), mirror: InMemoryStore = InMemoryStore()) -> LibraryStore {
        LibraryStore(file: file, mirror: mirror, saveDelay: 0.05)
    }

    @Test func progressCreatesHistoryItemNotInLibrary() async {
        let store = makeStore()
        await store.recordProgress(movie, videoID: movie.id, position: 600, duration: 8520, played: 600)
        let item = await store.item(movie.id)
        #expect(item?.isInLibrary == false)
        #expect(item?.isInContinueWatching == true)
        #expect(item?.state.timeOffset == 600_000)
        #expect(item?.state.duration == 8_520_000)
        #expect(await store.continueWatching().map(\.id) == [movie.id])
        #expect(await store.resumePosition(itemID: movie.id, videoID: movie.id) == 600)
    }

    @Test func watchedThresholdFlagsOnce() async {
        let store = makeStore()
        for step in 1...8 {
            await store.recordProgress(movie, videoID: movie.id, position: Double(step) * 1000, duration: 8000, played: 1000)
        }
        let item = await store.item(movie.id)
        #expect(item?.state.timesWatched == 1)
        #expect(item?.state.flaggedWatched == 1)
        #expect(item?.removed == false || item?.temp == true)
    }

    @Test func seekingDoesNotCountAsWatched() async {
        let store = makeStore()
        // Saut direct à 95 % : la position change, pas le temps regardé.
        await store.recordProgress(movie, videoID: movie.id, position: 7600, duration: 8000, played: 2)
        #expect(await store.item(movie.id)?.state.timesWatched == 0)
        #expect(await store.resumePosition(itemID: movie.id, videoID: movie.id) == nil, "générique : pas de reprise")
    }

    @Test func finishingEpisodeAdvancesToNext() async throws {
        let store = makeStore()
        let videos = try seriesVideos()
        await store.recordProgress(got, videoID: "tt0944947:1:1", position: 3300, duration: 3400, played: 3300, videos: videos)
        await store.finishPlayback(got, videoID: "tt0944947:1:1", position: 3300, duration: 3400,
                                   nextVideoID: NextEpisode.after(videoID: "tt0944947:1:1", in: videos)?.id, ended: false)
        let item = try #require(await store.item(got.id))
        #expect(item.state.videoID == "tt0944947:1:2")
        #expect(item.state.timeOffset == 1, "convention Stremio : épisode suivant à commencer")
        #expect(item.isInContinueWatching)
        #expect(await store.resumePosition(itemID: got.id, videoID: "tt0944947:1:2") == nil)
        #expect(await store.watchedVideoIDs(itemID: got.id, videos: videos).contains("tt0944947:1:1"))
    }

    @Test func markingCurrentEpisodeWatchedSkipsAhead() async throws {
        let store = makeStore()
        let videos = try seriesVideos()
        await store.setEpisodeWatched(got, videoID: "tt0944947:1:2", watched: true, videos: videos)
        await store.setEpisodeWatched(got, videoID: "tt0944947:1:1", watched: true, videos: videos)
        let item = try #require(await store.item(got.id))
        #expect(item.state.videoID == "tt0944947:2:1", "1:1 et 1:2 vus → 2:1")
        // L'épisode 9:1 n'est pas sorti : pas proposé après 2:1.
        #expect(NextEpisode.after(videoID: "tt0944947:2:1", in: videos, now: date("2026-11-01T00:00:00Z")) == nil)
    }

    @Test func libraryAddRemove() async {
        let store = makeStore()
        await store.addToLibrary(movie)
        #expect(await store.libraryItems().map(\.id) == [movie.id])
        await store.removeFromLibrary(movie.id)
        #expect(await store.libraryItems().isEmpty)
        #expect(await store.item(movie.id)?.removed == true)
    }

    @Test func persistsAndRestoresFromMirrorWhenCacheIsPurged() async throws {
        let file = InMemoryStore(), mirror = InMemoryStore()
        let store = makeStore(file: file, mirror: mirror)
        await store.addToLibrary(movie)
        await store.recordProgress(got, videoID: "tt0944947:1:1", position: 120, duration: 3400, played: 120)
        await store.rememberStream(videoID: "tt0944947:1:1", fingerprint: "url:https://example.com/a.mkv")
        await store.flush()
        // Simule la purge du cache fichier par tvOS.
        file.set(nil, forKey: LibraryStore.fileKey)
        let restored = makeStore(file: file, mirror: mirror)
        #expect(await restored.item(movie.id)?.isInLibrary == true)
        #expect(await restored.resumePosition(itemID: got.id, videoID: "tt0944947:1:1") == 120)
        #expect(await restored.lastStreamFingerprint(videoID: "tt0944947:1:1") == "url:https://example.com/a.mkv")
        #expect(Set(await restored.dirtyItems().map(\.id)) == [movie.id, got.id], "modifications non envoyées conservées")
    }

    @Test func debouncedSaveEventuallyWrites() async throws {
        let file = InMemoryStore()
        let store = makeStore(file: file)
        await store.addToLibrary(movie)
        #expect(file.data(forKey: LibraryStore.fileKey) == nil, "pas d'écriture immédiate")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(file.data(forKey: LibraryStore.fileKey) != nil)
    }

    @Test func mergeKeepsNewestVersion() async throws {
        let store = makeStore()
        await store.addToLibrary(movie, now: date("2026-10-01T00:00:00Z"))
        var remote = LibraryItem(id: movie.id, type: "movie", name: "Distant", removed: false, temp: false,
                                 mtime: date("2026-09-01T00:00:00Z"))
        #expect(await store.merge(remote: [remote]) == 0, "local plus récent conservé")
        remote.mtime = date("2026-10-15T00:00:00Z")
        #expect(await store.merge(remote: [remote]) == 1)
        #expect(await store.item(movie.id)?.name == "Distant")
        #expect(await store.dirtyItems().isEmpty)
    }
}

@Suite("Format libraryItem Stremio")
struct LibraryItemFormatTests {
    func items() throws -> [[String: JSONValue]] {
        let root = try Fixture.decode(JSONValue.self, "library_items.json")
        guard case .array(let arr)? = root["result"] else { throw Fixture.FixtureError.missing("result") }
        return arr.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    @Test func decodesServerItems() throws {
        let decoded = try items().compactMap { try? LibraryItem(stremioJSON: $0) }
        #expect(decoded.map(\.id) == ["tt0944947", "tt0111161"], "éléments invalides ignorés")
        let g = decoded[0]
        #expect(g.isInLibrary)
        #expect(g.state.videoID == "tt0944947:1:2")
        #expect(g.state.timeOffset == 1_900_000)
        #expect(g.mtime == date("2026-10-30T20:15:00.000Z"))
        let m = decoded[1]
        #expect(!m.isInLibrary && m.isInContinueWatching)
        #expect(m.poster == nil && m.ctime == nil)
    }

    @Test func reencodingPreservesUnknownFields() throws {
        var g = try LibraryItem(stremioJSON: try items()[0])
        g.state.timeOffset = 2_000_000
        let out = g.stremioJSON()
        #expect(out["customServerField"] == .string("doit être conservé"))
        #expect(out["state"]?["unknownFutureField"] == .object(["keep": .bool(true)]))
        #expect(out["state"]?["timeOffset"] == .number(2_000_000))
        #expect(out["state"]?["video_id"] == .string("tt0944947:1:2"))
        // Les entiers restent des entiers en JSON.
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(out)), as: UTF8.self)
        #expect(json.contains("\"timeOffset\":2000000"))
    }

    @Test func localCodableRoundTrip() throws {
        let g = try LibraryItem(stremioJSON: try items()[0])
        let back = try JSONDecoder().decode(LibraryItem.self, from: JSONEncoder().encode(g))
        #expect(back == g)
    }
}
