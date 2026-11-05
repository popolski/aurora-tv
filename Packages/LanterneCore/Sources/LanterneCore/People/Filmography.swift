import Foundation

/// Rôle d'une personne dans une œuvre.
public enum CreditRole: String, Sendable, Codable, Hashable, CaseIterable {
    case cast, director

    public var label: String {
        switch self {
        case .cast: "Interprétation"
        case .director: "Réalisation"
        }
    }
}

/// Personne citée sur une fiche (« Avec », « Réalisation »), avec l'œuvre d'où l'on
/// vient : les addons ne donnent qu'un nom, l'œuvre permet de trouver la bonne
/// personne (deux homonymes ne jouent pas dans le même film).
public struct PersonRef: Sendable, Codable, Hashable {
    public var name: String
    public var role: CreditRole
    /// Identifiant IMDb de l'œuvre d'origine (`tt…`).
    public var fromIMDb: String

    public init(name: String, role: CreditRole, fromIMDb: String) {
        self.name = name; self.role = role; self.fromIMDb = fromIMDb
    }
}

/// Œuvre d'une filmographie.
public struct PersonCredit: Sendable, Hashable, Identifiable {
    public var imdbID: String
    public var title: String
    public var year: Int?
    public var isSeries: Bool
    public var roles: Set<CreditRole>
    public var id: String { imdbID }

    public init(imdbID: String, title: String, year: Int?, isSeries: Bool, roles: Set<CreditRole>) {
        self.imdbID = imdbID; self.title = title; self.year = year; self.isSeries = isSeries; self.roles = roles
    }

    /// Affiche par identifiant IMDb (service d'images de Stremio, sans clé).
    public var posterURL: URL? { URL(string: "https://images.metahub.space/poster/medium/\(imdbID)/img") }
    public var type: String { isSeries ? ContentType.series : ContentType.movie }
}

public struct Filmography: Sendable, Equatable {
    public var name: String
    public var wikidataID: String
    public var credits: [PersonCredit]

    public var movies: [PersonCredit] { credits.filter { !$0.isSeries } }
    public var series: [PersonCredit] { credits.filter(\.isSeries) }
    public var roles: Set<CreditRole> { credits.reduce(into: []) { $0.formUnion($1.roles) } }
}

/// Filmographies tirées de Wikidata (données libres, sans clé).
///
/// Les requêtes imposent l'ordre d'évaluation écrit (`hint:Query hint:optimizer "None"`) :
/// laissé libre, l'optimiseur de Wikidata partait des libellés de toutes les personnes et
/// dépassait le délai de 60 s (erreur 504, constatée depuis le NAS le 05/11/2026).
///
/// 1. Personnes de l'œuvre d'origine (`P161` distribution, `P57` réalisation) : le nom
///    de l'addon est comparé à leurs libellés (sans tenir compte des accents ni de la
///    ponctuation). Aucun nom n'est inséré dans la requête.
/// 2. Œuvres de cette personne ayant un identifiant IMDb (`P345`), films (`Q11424` et
///    sous-types courants) et séries ; les épisodes sont écartés.
public actor FilmographyClient {
    public static let endpoint = URL(string: "https://query.wikidata.org/sparql")!

    static let filmTypes: Set<String> = [
        "Q11424",    // film
        "Q24862",    // court métrage
        "Q506240",   // téléfilm
        "Q202866",   // film d'animation
        "Q93204",    // film documentaire
        "Q229390",   // film 3D
        "Q24869",    // long métrage
    ]
    static let seriesTypes: Set<String> = [
        "Q5398426",  // série télévisée
        "Q1259759",  // mini-série
        "Q526877",   // web-série
        "Q581714",   // série d'animation
        "Q117467246", // série télévisée d'animation
        "Q15416",    // émission de télévision
    ]
    static let episodeTypes: Set<String> = ["Q21191270", "Q21664088", "Q1983062"]

    private let http: any HTTPClient
    private var cache: [PersonRef: Filmography] = [:]
    private let log = LogChannel("filmographie")

    public init(http: any HTTPClient) { self.http = http }

    public func filmography(for person: PersonRef) async -> Filmography? {
        if let cached = cache[person] { return cached }
        guard let peopleURL = Self.peopleURL(imdbID: person.fromIMDb) else { return nil }
        guard let peopleData = await fetch(peopleURL, step: "distribution de \(person.fromIMDb)") else { return nil }
        let people = Self.parsePeople(peopleData)
        guard let match = Self.match(person, in: people) else {
            log.info("\(person.role.rawValue) introuvable parmi \(people.count) personnes de \(person.fromIMDb)")
            return nil
        }
        guard let worksURL = Self.worksURL(personID: match.id),
              let data = await fetch(worksURL, step: "œuvres de \(match.id)") else { return nil }
        let result = Filmography(name: match.label, wikidataID: match.id, credits: Self.parseWorks(data))
        log.info("\(match.id) : \(result.movies.count) films, \(result.series.count) séries")
        guard !result.credits.isEmpty else { return nil }
        cache[person] = result
        return result
    }

    /// Wikidata peut mettre plusieurs secondes sur une filmographie fournie : délai large.
    private func fetch(_ url: URL, step: String) async -> Data? {
        let request = HTTPRequest(url: url, headers: ["Accept": "application/sparql-results+json"],
                                  timeout: 45, maxBytes: 6 * 1024 * 1024)
        do {
            let response = try await http.send(request)
            guard response.status == 200 else {
                log.warning("Wikidata (\(step)) : HTTP \(response.status)")
                return nil
            }
            return response.data
        } catch {
            log.warning("Wikidata (\(step)) : \(error)")
            return nil
        }
    }

    // MARK: Requêtes

    public static func isIMDbID(_ id: String) -> Bool {
        id.hasPrefix("tt") && id.count > 2 && id.count <= 12 && id.dropFirst(2).allSatisfy(\.isASCII) && id.dropFirst(2).allSatisfy(\.isNumber)
    }

    static func isEntityID(_ id: String) -> Bool {
        id.hasPrefix("Q") && id.count > 1 && id.count <= 12 && id.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func url(_ query: String) -> URL? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    public static func peopleURL(imdbID: String) -> URL? {
        guard isIMDbID(imdbID) else { return nil }
        return url("""
        SELECT ?person ?role ?label WHERE {
          hint:Query hint:optimizer "None" .
          ?work wdt:P345 "\(imdbID)" .
          { ?work wdt:P161 ?person . BIND("cast" AS ?role) } UNION { ?work wdt:P57 ?person . BIND("director" AS ?role) }
          ?person rdfs:label ?label . FILTER(LANG(?label) IN ("fr", "en", "mul"))
        }
        """)
    }

    /// Une ligne par œuvre (regroupement côté Wikidata) : sans cela, chaque date de
    /// sortie par pays multiplie les lignes et la réponse d'un réalisateur prolifique
    /// devient énorme.
    public static func worksURL(personID: String) -> URL? {
        guard isEntityID(personID) else { return nil }
        return url("""
        SELECT ?work (SAMPLE(?id) AS ?imdb) (GROUP_CONCAT(DISTINCT ?role; separator=" ") AS ?roles)
               (GROUP_CONCAT(DISTINCT STR(?type); separator=" ") AS ?types) (MIN(?d) AS ?date)
               (SAMPLE(?fr) AS ?frLabel) (SAMPLE(?en) AS ?enLabel) WHERE {
          hint:Query hint:optimizer "None" .
          { ?work wdt:P161 wd:\(personID) . BIND("cast" AS ?role) } UNION { ?work wdt:P57 wd:\(personID) . BIND("director" AS ?role) }
          ?work wdt:P345 ?id . FILTER(STRSTARTS(?id, "tt"))
          ?work wdt:P31 ?type .
          OPTIONAL { ?work wdt:P577 ?pub }
          OPTIONAL { ?work wdt:P580 ?start }
          BIND(COALESCE(?pub, ?start) AS ?d)
          OPTIONAL { ?work rdfs:label ?fr . FILTER(LANG(?fr) = "fr") }
          OPTIONAL { ?work rdfs:label ?en . FILTER(LANG(?en) = "en") }
        } GROUP BY ?work LIMIT 1500
        """)
    }

    // MARK: Analyse

    struct Person: Equatable {
        var id: String
        var label: String
        var roles: Set<CreditRole>
        var labels: [String]
    }

    private static func bindings(_ data: Data) -> [[String: String]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let rows = results["bindings"] as? [[String: Any]] else { return [] }
        return rows.map { row in
            row.compactMapValues { ($0 as? [String: Any])?["value"] as? String }
        }
    }

    private static func entityID(_ uri: String) -> String? {
        let id = String(uri.split(separator: "/").last ?? "")
        return isEntityID(id) ? id : nil
    }

    static func parsePeople(_ data: Data) -> [Person] {
        var byID: [String: Person] = [:]
        var order: [String] = []
        for row in bindings(data) {
            guard let uri = row["person"], let id = entityID(uri), let label = row["label"],
                  let role = row["role"].flatMap(CreditRole.init(rawValue:)) else { continue }
            if byID[id] == nil { order.append(id); byID[id] = Person(id: id, label: label, roles: [], labels: []) }
            byID[id]!.roles.insert(role)
            if !byID[id]!.labels.contains(label) { byID[id]!.labels.append(label) }
        }
        return order.compactMap { byID[$0] }
    }

    /// Nom comparable : minuscules, sans accents ni ponctuation, mots triés.
    static func nameKey(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
        let words = folded.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.sorted().joined(separator: " ")
    }

    static func match(_ ref: PersonRef, in people: [Person]) -> (id: String, label: String)? {
        let key = nameKey(ref.name)
        guard !key.isEmpty else { return nil }
        let candidates = people.filter { $0.labels.contains { nameKey($0) == key } }
        let best = candidates.first { $0.roles.contains(ref.role) } ?? candidates.first
        guard let best else { return nil }
        // Libellé affiché : celui qui correspond au nom de l'addon, sinon le premier.
        let label = best.labels.first { nameKey($0) == key } ?? best.label
        return (best.id, label)
    }

    static func parseWorks(_ data: Data) -> [PersonCredit] {
        struct Accumulator {
            var imdb: String
            var fr: String?
            var en: String?
            var year: Int?
            var types: Set<String> = []
            var roles: Set<CreditRole> = []
        }
        var works: [String: Accumulator] = [:]
        for row in bindings(data) {
            guard let uri = row["work"], let id = entityID(uri), let imdb = row["imdb"], isIMDbID(imdb) else { continue }
            var acc = works[id] ?? Accumulator(imdb: imdb)
            let types = (row["types"] ?? row["type"] ?? "").split(separator: " ").map(String.init)
            acc.types.formUnion(types.compactMap(entityID))
            let roles = (row["roles"] ?? row["role"] ?? "").split(separator: " ").map(String.init)
            acc.roles.formUnion(roles.compactMap(CreditRole.init(rawValue:)))
            if acc.fr == nil { acc.fr = row["frLabel"] ?? row["fr"] }
            if acc.en == nil { acc.en = row["enLabel"] ?? row["en"] }
            for raw in [row["date"], row["start"]].compactMap({ $0 }) {
                // « 1994-09-23T00:00:00Z » : année de la première date connue.
                if let year = Int(raw.prefix(4)), (1870...2100).contains(year) {
                    acc.year = min(acc.year ?? year, year)
                }
            }
            works[id] = acc
        }
        var seen = Set<String>()
        let credits: [PersonCredit] = works.values.compactMap { acc in
            guard acc.types.isDisjoint(with: episodeTypes) else { return nil }
            let isSeries = !acc.types.isDisjoint(with: seriesTypes)
            guard isSeries || !acc.types.isDisjoint(with: filmTypes) else { return nil }
            guard let title = acc.fr ?? acc.en, seen.insert(acc.imdb).inserted else { return nil }
            return PersonCredit(imdbID: acc.imdb, title: title, year: acc.year, isSeries: isSeries, roles: acc.roles)
        }
        // Plus récent d'abord ; sans date à la fin ; puis par titre.
        return credits.sorted {
            switch ($0.year, $1.year) {
            case let (a?, b?) where a != b: return a > b
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.title.localizedCompare($1.title) == .orderedAscending
            }
        }
    }
}
