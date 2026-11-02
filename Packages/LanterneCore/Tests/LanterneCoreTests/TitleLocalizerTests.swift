import Foundation
import Testing
@testable import LanterneCore

@Suite("Titres lisibles (Wikidata)")
struct TitleLocalizerTests {
    @Test func detectsNonLatinTitles() {
        #expect(TitleLocalizer.needsLocalization("千と千尋の神隠し"))
        #expect(TitleLocalizer.needsLocalization("기생충"))
        #expect(TitleLocalizer.needsLocalization("Брат"))
        #expect(!TitleLocalizer.needsLocalization("Le Voyage de Chihiro"))
        #expect(!TitleLocalizer.needsLocalization("Amélie"))
        #expect(!TitleLocalizer.needsLocalization("2046"))
        #expect(!TitleLocalizer.needsLocalization("Fast & Furious 7"))
    }

    @Test func parsesFrenchFirstThenEnglish() {
        let json = #"""
        {"results":{"bindings":[
          {"key":{"value":"imdb:tt0245429"},"fr":{"value":"Le Voyage de Chihiro"},"en":{"value":"Spirited Away"}},
          {"key":{"value":"tmdbm:496243"},"en":{"value":"Parasite"}},
          {"key":{"value":"imdb:tt0000001"},"fr":{"value":"千と千尋"}}
        ]}}
        """#
        let found = TitleLocalizer.parse(Data(json.utf8))
        #expect(found["imdb:tt0245429"] == "Le Voyage de Chihiro")
        #expect(found["tmdbm:496243"] == "Parasite")
        #expect(found["imdb:tt0000001"] == nil)
    }

    @Test func localizesOnlyNonLatinAndCaches() async {
        let client = MockHTTPClient { request in
            let json = #"{"results":{"bindings":[{"key":{"value":"imdb:tt0245429"},"fr":{"value":"Le Voyage de Chihiro"}},{"key":{"value":"tmdbm:581528"},"en":{"value":"Noise"}}]}}"#
            return MockHTTPClient.json(Data(json.utf8), url: request.url)
        }
        let localizer = TitleLocalizer(http: client)
        let metas = [
            MetaItem(id: "tt0245429", type: "movie", name: "千と千尋の神隠し"),
            MetaItem(id: "tt0111161", type: "movie", name: "Les Évadés"),
            MetaItem(id: "tmdb:581528", type: "movie", name: "노이즈"),
        ]
        let out = await localizer.localize(metas)
        #expect(out[0].name == "Le Voyage de Chihiro")
        #expect(out[2].name == "Noise" && out[2].originalName == "노이즈")
        #expect(out[0].originalName == "千と千尋の神隠し")
        #expect(out[1].name == "Les Évadés" && out[1].originalName == nil)
        _ = await localizer.localize(metas)
        #expect(client.requestCount == 1)
        // Aucun titre non latin : aucune requête.
        _ = await TitleLocalizer(http: client).localize([metas[1]])
        #expect(client.requestCount == 1)
    }

    @Test func requestRejectsUnsafeIDs() {
        #expect(TitleLocalizer.requestURL(keys: [#"imdb:tt1" } DELETE {"#, #"tmdbm:1" }"#]) == nil)
        let url = TitleLocalizer.requestURL(keys: ["imdb:tt0245429", "tmdbt:1399"])
        let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first?.value } ?? ""
        #expect(query.contains("wdt:P345") && query.contains("wdt:P4983") && !query.contains("wdt:P4947"))
        #expect(TitleLocalizer.lookupKey(for: MetaItem(id: "tmdb:1399", type: "series", name: "x")) == "tmdbt:1399")
        #expect(TitleLocalizer.imdbID("tt0944947:1:2") == "tt0944947")
        #expect(TitleLocalizer.imdbID("kitsu:1") == nil)
    }

    @Test func nonLatinOriginFromCountryOrLanguage() {
        #expect(MetaItem(id: "x", type: "movie", name: "Noise", country: "South Korea").nonLatinOrigin)
        #expect(MetaItem(id: "x", type: "movie", name: "x", language: "ja").nonLatinOrigin)
        #expect(!MetaItem(id: "x", type: "movie", name: "x", country: "France").nonLatinOrigin)
        #expect(!MetaItem(id: "x", type: "movie", name: "x").nonLatinOrigin)
    }
}
