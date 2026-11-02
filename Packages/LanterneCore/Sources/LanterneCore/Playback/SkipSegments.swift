import Foundation

/// Passage d'une vidéo que l'on peut sauter (générique, résumé…).
public struct SkipSegment: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case intro, recap, credits, preview }

    public var kind: Kind
    public var start: TimeInterval
    /// `nil` : jusqu'à la fin de la vidéo.
    public var end: TimeInterval?

    public init(kind: Kind, start: TimeInterval, end: TimeInterval?) {
        self.kind = kind; self.start = start; self.end = end
    }

    /// Libellé du bouton du lecteur.
    public var actionLabel: String {
        switch kind {
        case .intro: "Passer l'intro"
        case .recap: "Passer le résumé"
        case .credits: "Passer le générique"
        case .preview: "Passer l'aperçu"
        }
    }

    /// Le passage est-il en cours à cette position ? (Pas dans sa dernière seconde : trop tard pour sauter.)
    public func contains(_ position: TimeInterval, duration: TimeInterval) -> Bool {
        let finish = end ?? duration
        return position >= start && position < finish - 1
    }
}

/// Minutages communautaires de TheIntroDB (https://theintrodb.org), API v4, sans clé.
///
/// Requête : `GET /v4/media?imdb_id=tt…[&season=S&episode=E]` (ou `tmdb_id`).
/// Réponse : `{"intro":[{"start_ms":null,"end_ms":14600}],"recap":[…],"credits":[…],"preview":[…]}`.
/// `start_ms` nul = début de la vidéo ; `end_ms` nul ou 0 = fin de la vidéo ; 0 et 0 = aucun passage.
/// 404/400 : aucune donnée. 429 : quota atteint (`retry_after_seconds`), on n'insiste pas.
///
/// Les minutages dépendent de la version du fichier : ils peuvent être décalés. Le lecteur
/// propose donc un bouton plutôt que de sauter d'office (réglable).
public actor SkipTimesClient {
    public static let endpoint = URL(string: "https://api.theintrodb.org/v4/media")!

    private let http: any HTTPClient
    private var cache: [String: [SkipSegment]] = [:]
    private var pausedUntil: Date?

    public init(http: any HTTPClient) { self.http = http }

    /// Passages connus pour une vidéo Stremio (`tt…` / `tt…:S:E` / `tmdb:…` : TheIntroDB ;
    /// `kitsu:<id>:<épisode>` : AniSkip), triés par début.
    public func segments(videoID: String, type: String, durationMs: Int? = nil) async -> [SkipSegment] {
        if videoID.hasPrefix("kitsu:") {
            return await animeSegments(videoID: videoID, durationMs: durationMs)
        }
        guard let url = Self.requestURL(videoID: videoID, type: type, durationMs: durationMs) else { return [] }
        let key = url.absoluteString
        if let cached = cache[key] { return cached }
        if let pausedUntil, pausedUntil > Date() { return [] }
        guard let response = try? await http.send(HTTPRequest(url: url, timeout: 10, maxBytes: 256 * 1024)) else { return [] }
        switch response.status {
        case 200:
            let segments = Self.parse(response.data)
            cache[key] = segments
            return segments
        case 400, 404:
            cache[key] = []
            return []
        case 429:
            let wait = (try? JSONDecoder().decode(RateLimit.self, from: response.data))?.retry_after_seconds ?? 600
            pausedUntil = Date().addingTimeInterval(min(max(wait, 60), 86_400))
            return []
        default:
            return []
        }
    }

    private struct RateLimit: Decodable { var retry_after_seconds: Double? }

    // MARK: Animés : AniSkip (identifiant MyAnimeList trouvé via Kitsu)

    private var malIDs: [String: Int] = [:]

    private func animeSegments(videoID: String, durationMs: Int?) async -> [SkipSegment] {
        let parts = videoID.split(separator: ":").map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) else { return [] }
        let kitsuID = parts[1]
        let episode = parts.count >= 3 ? Int(parts[parts.count - 1]) ?? 1 : 1
        let key = "kitsu:\(kitsuID):\(episode)"
        if let cached = cache[key] { return cached }
        let mal: Int
        if let known = malIDs[kitsuID] {
            mal = known
        } else {
            guard let url = Self.kitsuMappingURL(kitsuID: kitsuID),
                  let response = try? await http.send(HTTPRequest(url: url, timeout: 10, maxBytes: 256 * 1024)),
                  response.status == 200, let found = Self.parseMALID(response.data) else { return [] }
            malIDs[kitsuID] = found
            mal = found
        }
        guard let url = Self.aniSkipURL(malID: mal, episode: episode, episodeLength: (durationMs ?? 0) / 1000),
              let response = try? await http.send(HTTPRequest(url: url, timeout: 10, maxBytes: 256 * 1024)) else { return [] }
        let segments = response.status == 200 ? Self.parseAniSkip(response.data) : []
        if response.status == 200 || response.status == 404 { cache[key] = segments }
        return segments
    }

    public static func kitsuMappingURL(kitsuID: String) -> URL? {
        guard kitsuID.allSatisfy(\.isNumber), !kitsuID.isEmpty else { return nil }
        var components = URLComponents(string: "https://kitsu.app/api/edge/anime/\(kitsuID)/mappings")
        components?.queryItems = [URLQueryItem(name: "filter[externalSite]", value: "myanimelist/anime")]
        return components?.url
    }

    public static func parseMALID(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let attributes = entry["attributes"] as? [String: Any],
                  (attributes["externalSite"] as? String) ?? "myanimelist/anime" == "myanimelist/anime",
                  let raw = attributes["externalId"] else { continue }
            if let id = raw as? Int { return id }
            if let text = raw as? String, let id = Int(text) { return id }
        }
        return nil
    }

    /// `GET https://api.aniskip.com/v2/skip-times/<mal>/<épisode>?types[]=op&…&episodeLength=<s>`.
    public static func aniSkipURL(malID: Int, episode: Int, episodeLength: Int) -> URL? {
        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(max(1, episode))")
        components?.queryItems = ["op", "ed", "recap", "mixed-op", "mixed-ed"].map { URLQueryItem(name: "types[]", value: $0) }
            + [URLQueryItem(name: "episodeLength", value: String(max(0, episodeLength)))]
        return components?.url
    }

    /// `{"found":true,"results":[{"interval":{"startTime":10.5,"endTime":100.2},"skipType":"op"}]}`.
    public static func parseAniSkip(_ data: Data) -> [SkipSegment] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        let kinds: [String: SkipSegment.Kind] = ["op": .intro, "mixed-op": .intro, "ed": .credits, "mixed-ed": .credits, "recap": .recap]
        return results.compactMap { result -> SkipSegment? in
            guard let type = result["skipType"] as? String, let kind = kinds[type],
                  let interval = result["interval"] as? [String: Any],
                  let start = (interval["startTime"] as? NSNumber)?.doubleValue,
                  let end = (interval["endTime"] as? NSNumber)?.doubleValue, end > start + 1 else { return nil }
            return SkipSegment(kind: kind, start: max(0, start), end: end)
        }
        .sorted { $0.start < $1.start }
    }

    public static func requestURL(videoID: String, type: String, durationMs: Int? = nil) -> URL? {
        let parts = videoID.split(separator: ":").map(String.init)
        var items: [URLQueryItem] = []
        if let first = parts.first, first.hasPrefix("tt"), first.dropFirst(2).allSatisfy(\.isNumber), first.count > 2 {
            items.append(URLQueryItem(name: "imdb_id", value: first))
        } else if parts.count >= 2, parts[0] == "tmdb", parts[1].allSatisfy(\.isNumber), !parts[1].isEmpty {
            items.append(URLQueryItem(name: "tmdb_id", value: parts[1]))
        } else {
            return nil  // kitsu:, etc. : pas couvert par TheIntroDB
        }
        if type == ContentType.series {
            guard parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) else { return nil }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        if let durationMs, durationMs > 0 { items.append(URLQueryItem(name: "duration_ms", value: String(durationMs))) }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items
        return components?.url
    }

    public static func parse(_ data: Data) -> [SkipSegment] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [SkipSegment] = []
        for kind in SkipSegment.Kind.allCases {
            guard let list = object[kind.rawValue] as? [[String: Any]] else { continue }
            for entry in list {
                let startMs = (entry["start_ms"] as? NSNumber)?.doubleValue
                let endMs = (entry["end_ms"] as? NSNumber)?.doubleValue
                if (startMs ?? 0) == 0 && endMs == 0 { continue }  // « aucun passage »
                let start = (startMs ?? 0) / 1000
                if let endMs, endMs > 0 {
                    let end = endMs / 1000
                    guard end > start + 1 else { continue }
                    out.append(SkipSegment(kind: kind, start: start, end: end))
                } else {
                    guard start > 0 else { continue }  // « jusqu'à la fin » depuis le début : ignoré
                    out.append(SkipSegment(kind: kind, start: start, end: nil))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
