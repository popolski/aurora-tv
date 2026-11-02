import Foundation
import Testing
@testable import LanterneCore

@Suite("Passer l'intro (TheIntroDB)")
struct SkipSegmentTests {
    @Test func buildsRequests() {
        #expect(SkipTimesClient.requestURL(videoID: "tt0903747:1:2", type: "series")?.absoluteString
                == "https://api.theintrodb.org/v4/media?imdb_id=tt0903747&season=1&episode=2")
        #expect(SkipTimesClient.requestURL(videoID: "tt0111161", type: "movie", durationMs: 8_520_000)?.absoluteString
                == "https://api.theintrodb.org/v4/media?imdb_id=tt0111161&duration_ms=8520000")
        #expect(SkipTimesClient.requestURL(videoID: "tmdb:1396:1:2", type: "series")?.absoluteString
                == "https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=2")
        #expect(SkipTimesClient.requestURL(videoID: "kitsu:1:1", type: "series") == nil)
        #expect(SkipTimesClient.requestURL(videoID: "tt0903747", type: "series") == nil)
    }

    @Test func parsesV4Body() {
        // Exemple de réponse v4 (clé tvdb_id, start_ms nul = début, end_ms nul = fin).
        let body = Data(#"{"tvdb_id":73871,"type":"tv","season":1,"episode":2,"intro":[{"start_ms":null,"end_ms":14600}],"recap":[{"start_ms":0,"end_ms":0}],"credits":[{"start_ms":1267233,"end_ms":null}]}"#.utf8)
        let segments = SkipTimesClient.parse(body)
        #expect(segments == [
            SkipSegment(kind: .intro, start: 0, end: 14.6),
            SkipSegment(kind: .credits, start: 1267.233, end: nil),
        ])
        #expect(SkipTimesClient.parse(Data("pas du json".utf8)).isEmpty)
    }

    @Test func containsStopsOneSecondBeforeTheEnd() {
        let intro = SkipSegment(kind: .intro, start: 60, end: 90)
        #expect(intro.contains(60, duration: 3000))
        #expect(intro.contains(88.9, duration: 3000))
        #expect(!intro.contains(89.5, duration: 3000))
        #expect(!intro.contains(30, duration: 3000))
        let credits = SkipSegment(kind: .credits, start: 2900, end: nil)
        #expect(credits.contains(2950, duration: 3000))
    }

    @Test func cachesAndHandlesMissingData() async {
        let client = MockHTTPClient { request in
            if request.url.absoluteString.contains("tt1") {
                return MockHTTPClient.json(Data(#"{"intro":[{"start_ms":5000,"end_ms":65000}]}"#.utf8), url: request.url)
            }
            return HTTPResponse(status: 404, data: Data(), url: request.url)
        }
        let skip = SkipTimesClient(http: client)
        #expect(await skip.segments(videoID: "tt1", type: "movie") == [SkipSegment(kind: .intro, start: 5, end: 65)])
        _ = await skip.segments(videoID: "tt1", type: "movie")
        #expect(client.requestCount == 1)
        #expect(await skip.segments(videoID: "tt2", type: "movie").isEmpty)
    }

    @Test func animeViaKitsuAndAniSkip() async {
        let client = MockHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("kitsu.app/api/edge/anime/7442/mappings") {
                return MockHTTPClient.json(Data(#"{"data":[{"id":"1","type":"mappings","attributes":{"externalSite":"myanimelist/anime","externalId":"16498"}}]}"#.utf8), url: request.url)
            }
            if url.contains("api.aniskip.com/v2/skip-times/16498/3") {
                return MockHTTPClient.json(Data(#"{"found":true,"results":[{"interval":{"startTime":1300.5,"endTime":1390.0},"skipType":"ed","skipId":"b","episodeLength":1420},{"interval":{"startTime":20.0,"endTime":110.0},"skipType":"op","skipId":"a","episodeLength":1420}]}"#.utf8), url: request.url)
            }
            return HTTPResponse(status: 404, data: Data(), url: request.url)
        }
        let skip = SkipTimesClient(http: client)
        let segments = await skip.segments(videoID: "kitsu:7442:3", type: "series", durationMs: 1_420_000)
        #expect(segments == [SkipSegment(kind: .intro, start: 20, end: 110), SkipSegment(kind: .credits, start: 1300.5, end: 1390)])
        _ = await skip.segments(videoID: "kitsu:7442:3", type: "series", durationMs: 1_420_000)
        #expect(client.requestCount == 2)  // correspondance et minutages en cache
        let url = SkipTimesClient.aniSkipURL(malID: 16498, episode: 3, episodeLength: 1420)
        #expect(url?.path == "/v2/skip-times/16498/3")
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        #expect(items.filter { $0.name == "types[]" }.compactMap(\.value) == ["op", "ed", "recap", "mixed-op", "mixed-ed"])
        #expect(items.first { $0.name == "episodeLength" }?.value == "1420")
    }

    @Test func backsOffOnRateLimit() async {
        let client = MockHTTPClient { request in
            HTTPResponse(status: 429, data: Data(#"{"code":"rate_limit_exceeded","retry_after_seconds":120}"#.utf8), url: request.url)
        }
        let skip = SkipTimesClient(http: client)
        #expect(await skip.segments(videoID: "tt1", type: "movie").isEmpty)
        #expect(await skip.segments(videoID: "tt2", type: "movie").isEmpty)
        #expect(client.requestCount == 1)
    }
}
