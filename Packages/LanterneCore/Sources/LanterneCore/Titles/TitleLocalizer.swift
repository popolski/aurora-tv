import Foundation

/// Titres lisibles pour les contenus dont l'addon ne donne que le titre original en
/// écriture non latine (japonais, chinois, coréen, thaï, cyrillique, arabe…).
///
/// Le titre français (à défaut anglais) est demandé à Wikidata par identifiant IMDb,
/// en une seule requête pour toute une page de catalogue. Le titre d'origine est
/// conservé dans `originalName`. Seuls les titres non latins déclenchent une requête.
public actor TitleLocalizer {
    public static let endpoint = URL(string: "https://query.wikidata.org/sparql")!

    private let http: any HTTPClient
    /// IMDb → titre lisible ("" : aucun trouvé).
    private var cache: [String: String] = [:]
    private var pausedUntil: Date?

    public init(http: any HTTPClient) { self.http = http }

    public func localize(_ metas: [MetaItem]) async -> [MetaItem] {
        let wanted = Set(metas.filter { Self.needsLocalization($0.name) }.compactMap { Self.imdbID($0.id) })
        let missing = wanted.filter { cache[$0] == nil }
        if !missing.isEmpty, (pausedUntil ?? .distantPast) < Date() {
            for chunk in Array(missing).sorted().chunked(into: 50) {
                guard let url = Self.requestURL(imdbIDs: chunk) else { continue }
                let request = HTTPRequest(url: url, headers: ["Accept": "application/sparql-results+json"],
                                          timeout: 6, maxBytes: 512 * 1024)
                guard let response = try? await http.send(request), response.status == 200 else {
                    pausedUntil = Date().addingTimeInterval(300)  // Wikidata injoignable : on réessaiera plus tard
                    break
                }
                let found = Self.parse(response.data)
                for id in chunk { cache[id] = found[id] ?? "" }
            }
        }
        return metas.map { meta in
            guard Self.needsLocalization(meta.name), let id = Self.imdbID(meta.id),
                  let title = cache[id], !title.isEmpty, title != meta.name else { return meta }
            var copy = meta
            copy.originalName = meta.name
            copy.name = title
            return copy
        }
    }

    public func localize(_ meta: MetaItem) async -> MetaItem {
        await localize([meta]).first ?? meta
    }

    // MARK: Outils

    /// Écriture majoritairement non latine (lettres uniquement).
    public static func needsLocalization(_ name: String) -> Bool {
        var latin = 0, other = 0
        for scalar in name.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: latin += 1
            default: other += 1
            }
        }
        return other > 0 && other >= latin
    }

    /// `tt1234567` (éventuellement suivi de `:saison:épisode`).
    public static func imdbID(_ id: String) -> String? {
        let head = String(id.split(separator: ":").first ?? "")
        guard head.hasPrefix("tt"), head.count > 2, head.count <= 12, head.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return head
    }

    public static func requestURL(imdbIDs: [String]) -> URL? {
        let ids = imdbIDs.filter { imdbID($0) == $0 }
        guard !ids.isEmpty else { return nil }
        let values = ids.map { "\"\($0)\"" }.joined(separator: " ")
        let query = """
        SELECT ?imdb ?fr ?en WHERE {
          VALUES ?imdb { \(values) }
          ?item wdt:P345 ?imdb .
          OPTIONAL { ?item rdfs:label ?fr . FILTER(LANG(?fr) = "fr") }
          OPTIONAL { ?item rdfs:label ?en . FILTER(LANG(?en) = "en") }
        }
        """
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    /// IMDb → titre français, sinon anglais ; uniquement s'il est lui-même lisible (latin).
    public static func parse(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return [:] }
        func value(_ binding: [String: Any], _ key: String) -> String? {
            ((binding[key] as? [String: Any])?["value"] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        var out: [String: String] = [:]
        for binding in bindings {
            guard let id = value(binding, "imdb") else { continue }
            let candidates = [value(binding, "fr"), value(binding, "en")].compactMap { $0 }
                .filter { !$0.isEmpty && !needsLocalization($0) }
            if let best = candidates.first, out[id] == nil || value(binding, "fr") == best { out[id] = best }
        }
        return out
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
