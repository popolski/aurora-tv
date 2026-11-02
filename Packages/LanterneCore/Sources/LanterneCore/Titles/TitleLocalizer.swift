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
    /// Clé (« imdb:tt… », « tmdbm:… », « tmdbt:… ») → titre lisible ("" : aucun trouvé).
    private var cache: [String: String] = [:]
    private var pausedUntil: Date?
    private let log = LogChannel("titres")

    public init(http: any HTTPClient) { self.http = http }

    public func localize(_ metas: [MetaItem]) async -> [MetaItem] {
        let candidates = metas.filter { Self.needsLocalization($0.name) }
        guard !candidates.isEmpty else { return metas }
        let wanted = Set(candidates.compactMap(Self.lookupKey(for:)))
        let missing = wanted.filter { cache[$0] == nil }
        if !missing.isEmpty, (pausedUntil ?? .distantPast) < Date() {
            for chunk in Array(missing).sorted().chunked(into: 40) {
                guard let url = Self.requestURL(keys: chunk) else { continue }
                let request = HTTPRequest(url: url, headers: ["Accept": "application/sparql-results+json"],
                                          timeout: 6, maxBytes: 512 * 1024)
                guard let response = try? await http.send(request), response.status == 200 else {
                    pausedUntil = Date().addingTimeInterval(300)  // Wikidata injoignable : on réessaiera plus tard
                    log.warning("Wikidata injoignable pour \(chunk.count) titre(s) non latin(s)")
                    break
                }
                let found = Self.parse(response.data)
                for key in chunk { cache[key] = found[key] ?? "" }
            }
        }
        let resolved = candidates.filter { Self.lookupKey(for: $0).flatMap { cache[$0] }.map { !$0.isEmpty } == true }.count
        log.info("titres non latins : \(candidates.count), rendus lisibles : \(resolved), sans identifiant exploitable : \(candidates.filter { Self.lookupKey(for: $0) == nil }.count)")
        return metas.map { meta in
            guard Self.needsLocalization(meta.name), let key = Self.lookupKey(for: meta),
                  let title = cache[key], !title.isEmpty, title != meta.name else { return meta }
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

    /// Clé de recherche Wikidata : IMDb (`P345`), TMDB film (`P4947`) ou TMDB série (`P4983`).
    public static func lookupKey(for meta: MetaItem) -> String? {
        if let imdb = imdbID(meta.id) { return "imdb:\(imdb)" }
        let parts = meta.id.split(separator: ":").map(String.init)
        if parts.count >= 2, parts[0] == "tmdb", !parts[1].isEmpty, parts[1].count <= 10, parts[1].allSatisfy(\.isNumber) {
            return (meta.type == ContentType.series ? "tmdbt:" : "tmdbm:") + parts[1]
        }
        return nil
    }

    public static func requestURL(keys: [String]) -> URL? {
        var groups: [(property: String, prefix: String, values: [String])] = [
            ("P345", "imdb", []), ("P4947", "tmdbm", []), ("P4983", "tmdbt", []),
        ]
        for key in keys {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = groups.firstIndex(where: { $0.prefix == parts[0] }) else { continue }
            let value = parts[1]
            // Valeurs strictes, insérées dans la requête : tt + chiffres, ou chiffres seuls.
            let valid = parts[0] == "imdb" ? imdbID(value) == value : (!value.isEmpty && value.count <= 10 && value.allSatisfy(\.isNumber))
            if valid { groups[index].values.append(value) }
        }
        let blocks = groups.filter { !$0.values.isEmpty }.map { group in
            let values = group.values.map { "\"\($0)\"" }.joined(separator: " ")
            return "{ VALUES ?v { \(values) } ?item wdt:\(group.property) ?v . BIND(CONCAT(\"\(group.prefix):\", ?v) AS ?key) }"
        }
        guard !blocks.isEmpty else { return nil }
        let query = """
        SELECT ?key ?fr ?en WHERE {
          \(blocks.joined(separator: " UNION "))
          OPTIONAL { ?item rdfs:label ?fr . FILTER(LANG(?fr) = "fr") }
          OPTIONAL { ?item rdfs:label ?en . FILTER(LANG(?en) = "en") }
        }
        """
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    /// Clé → titre français, sinon anglais ; uniquement s'il est lui-même lisible (latin).
    public static func parse(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return [:] }
        func value(_ binding: [String: Any], _ key: String) -> String? {
            ((binding[key] as? [String: Any])?["value"] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        var out: [String: String] = [:]
        for binding in bindings {
            guard let key = value(binding, "key") else { continue }
            let french = value(binding, "fr").flatMap { $0.isEmpty || needsLocalization($0) ? nil : $0 }
            let english = value(binding, "en").flatMap { $0.isEmpty || needsLocalization($0) ? nil : $0 }
            if let french { out[key] = french } else if out[key] == nil, let english { out[key] = english }
        }
        return out
    }
}

extension MetaItem {
    /// Origine probablement en écriture non latine (pays ou langue d'après l'addon) : sert à
    /// écarter un logo de titre illisible quand la reconnaissance de texte n'y lit rien.
    public var nonLatinOrigin: Bool {
        let text = [country, language].compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !text.isEmpty else { return false }
        let words = Set(text.split { !$0.isLetter }.map(String.init))
        let markers: Set<String> = [
            "korea", "korean", "corée", "coréen", "ko", "japan", "japanese", "japon", "japonais", "ja",
            "china", "chinese", "chine", "chinois", "zh", "cn", "mandarin", "cantonese", "cantonais", "taiwan", "taïwan",
            "hong", "thailand", "thai", "thaïlande", "thaï", "th", "russia", "russian", "russie", "russe", "ru",
            "india", "hindi", "inde", "tamil", "telugu", "iran", "persian", "persan", "farsi", "arabic", "arabe",
            "egypt", "égypte", "israel", "israël", "hebrew", "hébreu", "greek", "grec", "ukraine", "ukrainian", "ukrainien",
        ]
        return !words.isDisjoint(with: markers)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
