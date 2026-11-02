import Foundation
import Testing
@testable import LanterneCore

@Suite("Notes de la critique (Wikidata)")
struct ReviewScoresTests {
    private func binding(_ site: String, _ score: String, date: String? = nil, method: String? = nil) -> String {
        var parts = [
            #""site":{"type":"uri","value":"http://www.wikidata.org/entity/\#(site)"}"#,
            #""score":{"type":"literal","value":"\#(score)"}"#,
        ]
        if let date { parts.append(#""date":{"type":"literal","value":"\#(date)"}"#) }
        if let method { parts.append(#""methodLabel":{"type":"literal","value":"\#(method)"}"#) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    @Test func keepsLatestCriticScores() {
        let rows = [
            binding("Q105584", "88%", date: "2021-01-01T00:00:00Z", method: "Tomatometer score"),
            binding("Q105584", "92%", date: "2024-05-01T00:00:00Z", method: "Tomatometer score"),
            binding("Q105584", "95%", date: "2025-01-01T00:00:00Z", method: "Rotten Tomatoes audience score"),
            binding("Q105584", "7.9/10", date: "2025-01-01T00:00:00Z", method: "Rotten Tomatoes average rating"),
            binding("Q150248", "79/100", date: "2024-03-01T00:00:00Z", method: "Metascore"),
            binding("Q150248", "8.1/10", date: "2025-03-01T00:00:00Z", method: "Metacritic user score"),
        ]
        let json = #"{"head":{},"results":{"bindings":["# + rows.joined(separator: ",") + "]}}"
        #expect(ReviewScoresClient.parse(Data(json.utf8)) == ReviewScores(tomatometer: 92, metascore: 79))
    }

    @Test func emptyOrInvalid() {
        #expect(ReviewScoresClient.parse(Data(#"{"results":{"bindings":[]}}"#.utf8)).isEmpty)
        #expect(ReviewScoresClient.parse(Data("<html>".utf8)).isEmpty)
    }

    @Test func requestOnlyForStrictIMDbIDs() throws {
        let url = try #require(ReviewScoresClient.requestURL(imdbID: "tt0111161"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
        #expect(query?.contains(#"wdt:P345 "tt0111161""#) == true)
        #expect(ReviewScoresClient.requestURL(imdbID: #"tt1" } DELETE {"#) == nil)
        #expect(ReviewScoresClient.requestURL(imdbID: "kitsu:1") == nil)
    }
}
