import Foundation

/// Saga d'un film (série de films, Wikidata `P179` « fait partie de la série »).
public struct Saga: Sendable, Equatable {
    public var name: String
    public var wikidataID: String
    public var parts: [SagaPart]
}

public struct SagaPart: Sendable, Hashable, Identifiable {
    public var imdbID: String
    public var title: String
    public var year: Int?
    /// Rang dans la saga (`P1545`, ex. « 1 », « 2 », « 3.5 »), s'il est renseigné.
    public var ordinal: String?
    public var isSeries: Bool
    public var id: String { imdbID }

    public init(imdbID: String, title: String, year: Int?, ordinal: String?, isSeries: Bool) {
        self.imdbID = imdbID; self.title = title; self.year = year; self.ordinal = ordinal; self.isSeries = isSeries
    }

    public var posterURL: URL? { URL(string: "https://images.metahub.space/poster/medium/\(imdbID)/img") }
    public var type: String { isSeries ? ContentType.series : ContentType.movie }
}

/// Sagas tirées de Wikidata (sans clé). Une requête : œuvre d'origine → séries dont elle
/// fait partie → autres membres (identifiant IMDb, rang, date, titre fr/en), une ligne par
/// membre. Ordre d'évaluation imposé (sinon délai dépassé, voir `FilmographyClient`).
public actor SagaClient {
    private let http: any HTTPClient
    private var cache: [String: Saga] = [:]
    private var misses: Set<String> = []
    private let log = LogChannel("saga")

    public init(http: any HTTPClient) { self.http = http }

    /// Saga du film, ou `nil` (aucune, ou une seule œuvre connue).
    public func saga(forIMDb imdbID: String) async -> Saga? {
        if let cached = cache[imdbID] { return cached }
        if misses.contains(imdbID) { return nil }
        guard let url = Self.requestURL(imdbID: imdbID) else { return nil }
        let request = HTTPRequest(url: url, headers: ["Accept": "application/sparql-results+json"],
                                  timeout: 30, maxBytes: 2 * 1024 * 1024)
        do {
            let response = try await http.send(request)
            guard response.status == 200 else {
                log.warning("Wikidata (saga de \(imdbID)) : HTTP \(response.status)")
                return nil
            }
            guard let saga = Self.parse(response.data, current: imdbID) else {
                misses.insert(imdbID)
                return nil
            }
            cache[imdbID] = saga
            return saga
        } catch {
            log.warning("Wikidata (saga de \(imdbID)) : \(error)")
            return nil
        }
    }

    public static func requestURL(imdbID: String) -> URL? {
        guard FilmographyClient.isIMDbID(imdbID) else { return nil }
        let query = """
        SELECT ?saga (SAMPLE(?sagaFr0) AS ?sagaFr) (SAMPLE(?sagaEn0) AS ?sagaEn) ?member (SAMPLE(?id) AS ?imdb)
               (SAMPLE(?ord) AS ?ordinal) (MIN(?pub) AS ?date) (SAMPLE(?fr0) AS ?fr) (SAMPLE(?en0) AS ?en)
               (GROUP_CONCAT(DISTINCT STR(?type); separator=" ") AS ?types) WHERE {
          hint:Query hint:optimizer "None" .
          ?film wdt:P345 "\(imdbID)" .
          ?film wdt:P179 ?saga .
          ?st ps:P179 ?saga .
          ?member p:P179 ?st .
          OPTIONAL { ?st pq:P1545 ?ord }
          ?member wdt:P345 ?id . FILTER(STRSTARTS(?id, "tt"))
          OPTIONAL { ?member wdt:P31 ?type }
          OPTIONAL { ?member wdt:P577 ?pub }
          OPTIONAL { ?member rdfs:label ?fr0 . FILTER(LANG(?fr0) = "fr") }
          OPTIONAL { ?member rdfs:label ?en0 . FILTER(LANG(?en0) = "en") }
          OPTIONAL { ?saga rdfs:label ?sagaFr0 . FILTER(LANG(?sagaFr0) = "fr") }
          OPTIONAL { ?saga rdfs:label ?sagaEn0 . FILTER(LANG(?sagaEn0) = "en") }
        } GROUP BY ?saga ?member LIMIT 600
        """
        return FilmographyClient.url(query)
    }

    static func parse(_ data: Data, current: String) -> Saga? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let rows = results["bindings"] as? [[String: Any]] else { return nil }
        struct Group { var name: String; var parts: [String: SagaPart] = [:] }
        var groups: [String: Group] = [:]
        for raw in rows {
            let row = raw.compactMapValues { ($0 as? [String: Any])?["value"] as? String }
            guard let sagaURI = row["saga"], let sagaID = sagaURI.split(separator: "/").last.map(String.init),
                  FilmographyClient.isEntityID(sagaID),
                  let imdb = row["imdb"], FilmographyClient.isIMDbID(imdb),
                  let title = row["fr"] ?? row["en"] else { continue }
            let name = row["sagaFr"] ?? row["sagaEn"] ?? "Saga"
            let types = Set((row["types"] ?? "").split(separator: " ").compactMap { $0.split(separator: "/").last.map(String.init) })
            let isSeries = !types.isDisjoint(with: FilmographyClient.seriesTypes)
            if !types.isEmpty, types.isDisjoint(with: FilmographyClient.filmTypes), !isSeries { continue }  // jeux, livres…
            let year = row["date"].flatMap { Int($0.prefix(4)) }.flatMap { (1870...2100).contains($0) ? $0 : nil }
            let ordinal = row["ordinal"].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            groups[sagaID, default: Group(name: name)].parts[imdb] = SagaPart(imdbID: imdb, title: title, year: year,
                                                                              ordinal: ordinal, isSeries: isSeries)
        }
        // Plusieurs sagas (ex. trilogie et franchise) : celle où l'œuvre a un rang, puis la
        // plus petite (la plus précise) qui compte au moins deux œuvres.
        let candidates = groups.filter { $0.value.parts.count >= 2 && $0.value.parts[current] != nil }
        guard let (id, group) = candidates.min(by: { a, b in
            let ra = a.value.parts[current]?.ordinal != nil, rb = b.value.parts[current]?.ordinal != nil
            if ra != rb { return ra }
            if a.value.parts.count != b.value.parts.count { return a.value.parts.count < b.value.parts.count }
            return a.key < b.key
        }) else { return nil }
        return Saga(name: group.name, wikidataID: id, parts: sorted(Array(group.parts.values)))
    }

    /// Par rang numérique s'il existe, sinon par année, puis par titre.
    static func sorted(_ parts: [SagaPart]) -> [SagaPart] {
        parts.sorted { a, b in
            switch (a.ordinal.flatMap(Double.init), b.ordinal.flatMap(Double.init)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            switch (a.year, b.year) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCompare(b.title) == .orderedAscending
            }
        }
    }
}
