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
          {"imdb":{"value":"tt0245429"},"fr":{"value":"Le Voyage de Chihiro"},"en":{"value":"Spirited Away"}},
          {"imdb":{"value":"tt6751668"},"en":{"value":"Parasite"}},
          {"imdb":{"value":"tt0000001"},"fr":{"value":"千と千尋"}}
        ]}}
        """#
        let found = TitleLocalizer.parse(Data(json.utf8))
        #expect(found["tt0245429"] == "Le Voyage de Chihiro")
        #expect(found["tt6751668"] == "Parasite")
        #expect(found["tt0000001"] == nil)
    }

    @Test func localizesOnlyNonLatinAndCaches() async {
        let client = MockHTTPClient { request in
            let json = #"{"results":{"bindings":[{"imdb":{"value":"tt0245429"},"fr":{"value":"Le Voyage de Chihiro"}}]}}"#
            return MockHTTPClient.json(Data(json.utf8), url: request.url)
        }
        let localizer = TitleLocalizer(http: client)
        let metas = [
            MetaItem(id: "tt0245429", type: "movie", name: "千と千尋の神隠し"),
            MetaItem(id: "tt0111161", type: "movie", name: "Les Évadés"),
        ]
        let out = await localizer.localize(metas)
        #expect(out[0].name == "Le Voyage de Chihiro")
        #expect(out[0].originalName == "千と千尋の神隠し")
        #expect(out[1].name == "Les Évadés" && out[1].originalName == nil)
        _ = await localizer.localize(metas)
        #expect(client.requestCount == 1)
        // Aucun titre non latin : aucune requête.
        _ = await TitleLocalizer(http: client).localize([metas[1]])
        #expect(client.requestCount == 1)
    }

    @Test func requestRejectsUnsafeIDs() {
        #expect(TitleLocalizer.requestURL(imdbIDs: [#"tt1" } DELETE {"#]) == nil)
        #expect(TitleLocalizer.imdbID("tt0944947:1:2") == "tt0944947")
        #expect(TitleLocalizer.imdbID("kitsu:1") == nil)
    }
}
