import Foundation
import Testing
@testable import LanterneCore

@Suite("Filmographie (Wikidata)")
struct FilmographyTests {
    private static func sparql(_ rows: [[String: String]]) -> Data {
        let bindings = rows.map { row in row.mapValues { ["type": "literal", "value": $0] } }
        return try! JSONSerialization.data(withJSONObject: ["results": ["bindings": bindings]])
    }

    private static let people = sparql([
        ["person": "http://www.wikidata.org/entity/Q48337", "role": "cast", "label": "Morgan Freeman"],
        ["person": "http://www.wikidata.org/entity/Q48337", "role": "cast", "label": "Morgan Freeman"],
        ["person": "http://www.wikidata.org/entity/Q47284", "role": "director", "label": "Frank Darabont"],
        ["person": "http://www.wikidata.org/entity/Q2263", "role": "cast", "label": "Tom Hanks"],
        ["person": "http://www.wikidata.org/entity/Q99999", "role": "cast", "label": "Françoise Dorléac"],
    ])

    private static let works = sparql([
        // Les Évadés : deux dates de sortie, deux libellés.
        ["work": "http://www.wikidata.org/entity/Q172241", "imdb": "tt0111161", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q11424", "date": "1994-09-10T00:00:00Z", "fr": "Les Évadés", "en": "The Shawshank Redemption"],
        ["work": "http://www.wikidata.org/entity/Q172241", "imdb": "tt0111161", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q11424", "date": "1995-03-01T00:00:00Z", "fr": "Les Évadés", "en": "The Shawshank Redemption"],
        // Série (date de début).
        ["work": "http://www.wikidata.org/entity/Q1", "imdb": "tt3032476", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q5398426", "start": "2015-01-01T00:00:00Z", "en": "Some Series"],
        // Épisode : écarté, même s'il a aussi un type « film ».
        ["work": "http://www.wikidata.org/entity/Q2", "imdb": "tt9999999", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q21191270", "fr": "Un épisode"],
        ["work": "http://www.wikidata.org/entity/Q2", "imdb": "tt9999999", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q11424", "fr": "Un épisode"],
        // Jeu vidéo : écarté.
        ["work": "http://www.wikidata.org/entity/Q3", "imdb": "tt8888888", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q7889", "en": "A Game"],
        // Réalisé et joué, sans date.
        ["work": "http://www.wikidata.org/entity/Q4", "imdb": "tt0475255", "role": "director",
         "type": "http://www.wikidata.org/entity/Q11424", "en": "Bopha!"],
        ["work": "http://www.wikidata.org/entity/Q4", "imdb": "tt0475255", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q11424", "en": "Bopha!"],
        // Identifiant IMDb invalide : écarté.
        ["work": "http://www.wikidata.org/entity/Q5", "imdb": "nm0000151", "role": "cast",
         "type": "http://www.wikidata.org/entity/Q11424", "en": "Bad"],
    ])

    @Test func requestsAreStrict() {
        #expect(FilmographyClient.peopleURL(imdbID: "tt0111161") != nil)
        #expect(FilmographyClient.peopleURL(imdbID: "tt01\" } DELETE") == nil)
        #expect(FilmographyClient.peopleURL(imdbID: "kitsu:1") == nil)
        #expect(FilmographyClient.worksURL(personID: "Q48337") != nil)
        #expect(FilmographyClient.worksURL(personID: "Q48337 }") == nil)
        let query = FilmographyClient.worksURL(personID: "Q48337")?.absoluteString.removingPercentEncoding ?? ""
        #expect(query.contains("wd:Q48337"))
    }

    @Test func matchesTheNameFromTheAddon() {
        let people = FilmographyClient.parsePeople(Self.people)
        #expect(people.count == 4)
        #expect(FilmographyClient.match(PersonRef(name: "Morgan Freeman", role: .cast, fromIMDb: "tt0111161"), in: people)?.id == "Q48337")
        // Accents, casse, ponctuation et ordre des mots ignorés.
        #expect(FilmographyClient.match(PersonRef(name: "francoise dorleac", role: .cast, fromIMDb: "tt1"), in: people)?.id == "Q99999")
        #expect(FilmographyClient.match(PersonRef(name: "Darabont, Frank", role: .director, fromIMDb: "tt1"), in: people)?.id == "Q47284")
        #expect(FilmographyClient.match(PersonRef(name: "Inconnu", role: .cast, fromIMDb: "tt1"), in: people) == nil)
        #expect(FilmographyClient.match(PersonRef(name: "  ", role: .cast, fromIMDb: "tt1"), in: people) == nil)
    }

    @Test func parsesAndSortsWorks() {
        let credits = FilmographyClient.parseWorks(Self.works)
        #expect(credits.map(\.imdbID) == ["tt3032476", "tt0111161", "tt0475255"])
        let shawshank = credits[1]
        #expect(shawshank.title == "Les Évadés")
        #expect(shawshank.year == 1994)
        #expect(!shawshank.isSeries)
        #expect(shawshank.posterURL?.absoluteString == "https://images.metahub.space/poster/medium/tt0111161/img")
        #expect(credits[0].isSeries && credits[0].year == 2015 && credits[0].type == "series")
        #expect(credits[2].roles == [.cast, .director] && credits[2].year == nil)
    }

    @Test func parsesGroupedRows() {
        // Format de la requête regroupée (une ligne par œuvre).
        let data = Self.sparql([
            ["work": "http://www.wikidata.org/entity/Q500", "imdb": "tt0077651", "roles": "director cast",
             "types": "http://www.wikidata.org/entity/Q11424 http://www.wikidata.org/entity/Q202866",
             "date": "1978-10-25T00:00:00Z", "frLabel": "La Nuit des masques", "enLabel": "Halloween"],
            ["work": "http://www.wikidata.org/entity/Q501", "imdb": "tt0080749", "roles": "director",
             "types": "http://www.wikidata.org/entity/Q11424", "date": "1980-02-08T00:00:00Z", "enLabel": "The Fog"],
        ])
        let credits = FilmographyClient.parseWorks(data)
        #expect(credits.map(\.imdbID) == ["tt0080749", "tt0077651"])
        #expect(credits[1].title == "La Nuit des masques" && credits[1].year == 1978 && credits[1].roles == [.cast, .director])
        #expect(credits[0].title == "The Fog" && credits[0].roles == [.director])
        let query = FilmographyClient.worksURL(personID: "Q95008")?.absoluteString.removingPercentEncoding ?? ""
        #expect(query.contains("GROUP BY ?work"))
    }

    @Test func fullLookupWithCache() async {
        let http = MockHTTPClient { req in
            let query = req.url.absoluteString.removingPercentEncoding ?? ""
            return MockHTTPClient.json(query.contains("wd:Q48337") ? Self.works : Self.people, url: req.url)
        }
        let client = FilmographyClient(http: http)
        let ref = PersonRef(name: "Morgan Freeman", role: .cast, fromIMDb: "tt0111161")
        let result = await client.filmography(for: ref)
        #expect(result?.name == "Morgan Freeman")
        #expect(result?.wikidataID == "Q48337")
        #expect(result?.movies.count == 2 && result?.series.count == 1)
        #expect(result?.roles == [.cast, .director])
        _ = await client.filmography(for: ref)
        #expect(http.requestCount == 2)
        // Personne absente de l'œuvre : pas de deuxième requête.
        #expect(await client.filmography(for: PersonRef(name: "Inconnu", role: .cast, fromIMDb: "tt0111161")) == nil)
        #expect(http.requestCount == 3)
    }
}
