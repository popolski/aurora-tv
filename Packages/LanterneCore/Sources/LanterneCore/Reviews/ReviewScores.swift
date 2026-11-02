import Foundation

/// Notes de la critique : Tomatometer (Rotten Tomatoes, %) et Metascore (Metacritic, /100).
public struct ReviewScores: Sendable, Equatable {
    public var tomatometer: Int?
    public var metascore: Int?

    public init(tomatometer: Int? = nil, metascore: Int? = nil) {
        self.tomatometer = tomatometer; self.metascore = metascore
    }

    public var isEmpty: Bool { tomatometer == nil && metascore == nil }
}

/// Notes tirées de Wikidata (données libres, sans clé), par identifiant IMDb.
///
/// Requête SPARQL sur `P444` (note de revue) qualifiée par `P447` (site : Rotten Tomatoes
/// `Q105584`, Metacritic `Q150248`), avec la date (`P585`) et la méthode (`P459`) pour garder
/// la note la plus récente de la critique (et non du public).
public actor ReviewScoresClient {
    public static let endpoint = URL(string: "https://query.wikidata.org/sparql")!
    static let rottenTomatoes = "Q105584"
    static let metacritic = "Q150248"

    private let http: any HTTPClient
    private var cache: [String: ReviewScores] = [:]

    public init(http: any HTTPClient) { self.http = http }

    public func scores(imdbID: String) async -> ReviewScores {
        guard let url = Self.requestURL(imdbID: imdbID) else { return ReviewScores() }
        if let cached = cache[imdbID] { return cached }
        let request = HTTPRequest(url: url, headers: ["Accept": "application/sparql-results+json"],
                                  timeout: 12, maxBytes: 512 * 1024)
        guard let response = try? await http.send(request), response.status == 200 else { return ReviewScores() }
        let scores = Self.parse(response.data)
        cache[imdbID] = scores
        return scores
    }

    public static func requestURL(imdbID: String) -> URL? {
        // Identifiant IMDb strict (tt + chiffres) : il est inséré dans la requête SPARQL.
        guard imdbID.hasPrefix("tt"), imdbID.count <= 12, imdbID.dropFirst(2).allSatisfy(\.isNumber), imdbID.count > 2 else { return nil }
        let query = """
        SELECT ?site ?score ?date ?methodLabel WHERE {
          ?item wdt:P345 "\(imdbID)" .
          ?item p:P444 ?st . ?st ps:P444 ?score ; pq:P447 ?site .
          VALUES ?site { wd:\(rottenTomatoes) wd:\(metacritic) }
          OPTIONAL { ?st pq:P585 ?date }
          OPTIONAL { ?st pq:P459 ?method }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        """
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    public static func parse(_ data: Data) -> ReviewScores {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return ReviewScores() }
        func value(_ binding: [String: Any], _ key: String) -> String? {
            (binding[key] as? [String: Any])?["value"] as? String
        }
        var tomato: (Int, String)?
        var meta: (Int, String)?
        for binding in bindings {
            guard let site = value(binding, "site"), let raw = value(binding, "score") else { continue }
            let method = (value(binding, "methodLabel") ?? "").lowercased()
            let date = value(binding, "date") ?? ""
            if site.hasSuffix(rottenTomatoes) {
                // Tomatometer : « 92% » ; on écarte la note du public et la note moyenne (« 7.9/10 »).
                guard !method.contains("audience"), raw.hasSuffix("%"),
                      let score = Int(raw.dropLast().trimmingCharacters(in: .whitespaces)), (0...100).contains(score) else { continue }
                if tomato == nil || date > tomato!.1 { tomato = (score, date) }
            } else if site.hasSuffix(metacritic) {
                // Metascore : « 79/100 » ; on écarte la note des utilisateurs.
                guard !method.contains("user") else { continue }
                let head = raw.split(separator: "/").first.map(String.init) ?? raw
                guard let score = Int(head.trimmingCharacters(in: .whitespaces)), (0...100).contains(score) else { continue }
                if meta == nil || date > meta!.1 { meta = (score, date) }
            }
        }
        return ReviewScores(tomatometer: tomato?.0, metascore: meta?.0)
    }
}
