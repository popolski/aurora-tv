import Foundation

/// Titre proposé par la découverte (TMDB via le service du NAS).
public struct DiscoveryItem: Sendable, Hashable, Identifiable {
    public var imdbID: String
    public var type: String
    public var title: String
    public var year: Int?
    public var poster: URL?
    public var background: URL?
    public var id: String { imdbID }

    public var meta: MetaItem {
        MetaItem(id: imdbID, type: type, name: title, poster: poster, background: background,
                 releaseInfo: year.map(String.init))
    }
}

/// Découverte servie par le NAS (clé TMDB de l'utilisateur, jamais dans l'app) :
/// recommandations (« Parce que vous avez regardé… ») et collections (sagas TMDB).
/// Les réponses sont des données non fiables : identifiants IMDb et adresses d'images
/// TMDB (HTTPS) vérifiés un par un.
public actor DiscoveryClient {
    private let http: any HTTPClient
    private var recommendationsCache: [String: [DiscoveryItem]] = [:]
    private var collectionCache: [String: Saga?] = [:]

    public init(http: any HTTPClient) { self.http = http }

    public static func recommendationsURL(server: URL, id: String, type: String) -> URL? {
        guard FilmographyClient.isIMDbID(id) else { return nil }
        let base = server.appendingPathComponent("tmdb").appendingPathComponent("recommendations")
            .appendingPathComponent("\(id).json")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "type", value: type == ContentType.series ? "series" : "movie")]
        return components?.url
    }

    public static func collectionURL(server: URL, id: String) -> URL? {
        guard FilmographyClient.isIMDbID(id) else { return nil }
        return server.appendingPathComponent("tmdb").appendingPathComponent("collection").appendingPathComponent("\(id).json")
    }

    public func recommendations(server: URL, id: String, type: String) async -> [DiscoveryItem] {
        let key = "\(type):\(id)"
        if let cached = recommendationsCache[key] { return cached }
        guard let url = Self.recommendationsURL(server: server, id: id, type: type),
              let data = await fetch(url) else { return [] }
        let items = Self.parseRecommendations(data)
        recommendationsCache[key] = items
        return items
    }

    public func collection(server: URL, id: String) async -> Saga? {
        if let cached = collectionCache[id] { return cached }
        guard let url = Self.collectionURL(server: server, id: id) else { return nil }
        // 404 = pas de collection (réponse gardée) ; autre échec : on réessaiera.
        let request = HTTPRequest(url: url, timeout: 20, maxBytes: 512 * 1024)
        guard let response = try? await http.send(request) else { return nil }
        if response.status == 404 { collectionCache[id] = .some(nil); return nil }
        guard response.status == 200 else { return nil }
        let saga = Self.parseCollection(response.data)
        collectionCache[id] = .some(saga)
        return saga
    }

    private func fetch(_ url: URL) async -> Data? {
        let request = HTTPRequest(url: url, timeout: 20, maxBytes: 512 * 1024)
        guard let response = try? await http.send(request), response.status == 200 else { return nil }
        return response.data
    }

    static func image(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme == "https",
              url.host == "image.tmdb.org" else { return nil }
        return url
    }

    public static func parseRecommendations(_ data: Data) -> [DiscoveryItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return items.compactMap { raw in
            guard let imdb = raw["imdb"] as? String, FilmographyClient.isIMDbID(imdb), seen.insert(imdb).inserted,
                  let title = raw["title"] as? String, !title.isEmpty else { return nil }
            let type = (raw["type"] as? String) == ContentType.series ? ContentType.series : ContentType.movie
            return DiscoveryItem(imdbID: imdb, type: type, title: String(title.prefix(200)),
                                 year: raw["year"] as? Int, poster: image(raw["poster"]), background: image(raw["background"]))
        }
    }

    public static func parseCollection(_ data: Data) -> Saga? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["parts"] as? [[String: Any]] else { return nil }
        let name = (object["name"] as? String).map { String($0.prefix(200)) } ?? "Saga"
        var seen = Set<String>()
        let sagaParts: [SagaPart] = parts.compactMap { raw in
            guard let imdb = raw["imdb"] as? String, FilmographyClient.isIMDbID(imdb), seen.insert(imdb).inserted,
                  let title = raw["title"] as? String, !title.isEmpty else { return nil }
            return SagaPart(imdbID: imdb, title: String(title.prefix(200)), year: raw["year"] as? Int,
                            ordinal: nil, isSeries: false)
        }
        guard sagaParts.count >= 2 else { return nil }
        // Ordre du NAS (date de sortie), conservé.
        return Saga(name: name, wikidataID: "", parts: sagaParts)
    }
}

/// Personne trouvée par la recherche (Wikidata, sans clé).
public struct PersonHit: Sendable, Hashable, Identifiable {
    public var wikidataID: String
    public var name: String
    public var description: String?
    public var id: String { wikidataID }
}

/// Recherche de personnes du cinéma par leur nom (API de recherche de Wikidata,
/// `wbsearchentities`) ; seules les descriptions qui évoquent le cinéma ou la télévision
/// sont gardées (acteur, réalisatrice, scénariste…).
public enum PeopleSearch {
    public static let endpoint = URL(string: "https://www.wikidata.org/w/api.php")!

    public static func requestURL(query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, text.count <= 80 else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"), URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "language", value: "fr"), URLQueryItem(name: "uselang", value: "fr"),
            URLQueryItem(name: "type", value: "item"), URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static let screenWords = ["acteur", "actrice", "réalisat", "cinéaste", "comédien", "comédienne", "scénariste",
                              "metteur en scène", "metteuse en scène", "humoriste", "doubleur", "doubleuse",
                              "actor", "actress", "director", "filmmaker", "screenwriter", "comedian"]

    public static func parse(_ data: Data) -> [PersonHit] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["search"] as? [[String: Any]] else { return [] }
        return results.compactMap { raw in
            guard let id = raw["id"] as? String, FilmographyClient.isEntityID(id),
                  let label = raw["label"] as? String, !label.isEmpty,
                  let description = raw["description"] as? String else { return nil }
            let lower = description.lowercased()
            guard screenWords.contains(where: lower.contains) else { return nil }
            return PersonHit(wikidataID: id, name: String(label.prefix(120)), description: String(description.prefix(160)))
        }
    }
}
