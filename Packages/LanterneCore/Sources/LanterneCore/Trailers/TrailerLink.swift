import Foundation

/// Réglages des bandes-annonces (lues depuis le service « aurora-trailers » du NAS).
public struct TrailerPreferences: Sendable, Codable, Hashable {
    /// Adresse du service, ex. `http://192.168.1.20:8787`. Vide = bandes-annonces désactivées.
    public var serverURL: String = ""
    /// Bande-annonce en fond, sans le son, sur les fiches.
    public var onDetail: Bool = true
    /// Bande-annonce dans le bandeau de l'accueil.
    public var onHome: Bool = true
    /// Délai avant le lancement (l'image s'affiche d'abord).
    public var delay: Double = 3

    public init() {}

    enum CodingKeys: String, CodingKey { case serverURL, onDetail, onHome, delay }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrailerPreferences()
        serverURL = c.value(.serverURL, default: d.serverURL)
        onDetail = c.value(.onDetail, default: d.onDetail)
        onHome = c.value(.onHome, default: d.onHome)
        delay = c.value(.delay, default: d.delay)
    }

    /// Adresse du service si elle est valide (http ou https, avec hôte).
    public var server: URL? {
        let s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Construction des adresses du service de bandes-annonces.
///
/// Les identifiants YouTube viennent des addons (données non fiables) : seuls
/// les identifiants au format YouTube (11 caractères `A-Z a-z 0-9 _ -`) sont acceptés,
/// ce qui interdit toute injection de chemin.
public enum TrailerLink {
    public static func isValidYouTubeID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// `<serveur>/trailer/<id>.mp4`, ou `nil` si l'identifiant est invalide.
    public static func videoURL(server: URL, youTubeID: String) -> URL? {
        guard isValidYouTubeID(youTubeID) else { return nil }
        return server.appendingPathComponent("trailer").appendingPathComponent("\(youTubeID).mp4")
    }

    /// `<serveur>/trailer/<id>.preview.mp4` : extrait de 30 s, sans le son (carrousel Top Shelf).
    public static func previewURL(server: URL, youTubeID: String) -> URL? {
        guard isValidYouTubeID(youTubeID) else { return nil }
        return server.appendingPathComponent("trailer").appendingPathComponent("\(youTubeID).preview.mp4")
    }

    /// `<serveur>/trailer/for/<fiche>.mp4?type=…&yt=…` : bande-annonce d'une fiche, que le
    /// service choisit en français si possible (VF, sinon VOSTFR, sinon VO, via TMDB) et,
    /// à défaut, parmi les identifiants YouTube de l'addon (`yt`). `nil` si la fiche n'a
    /// aucune bande-annonce connue de l'addon.
    public static func itemVideoURL(server: URL, meta: MetaItem) -> URL? {
        itemURL(server: server, meta: meta, suffix: ".mp4")
    }

    /// Extrait de 30 s, sans le son, de la bande-annonce d'une fiche (bandeau, Top Shelf).
    public static func itemPreviewURL(server: URL, meta: MetaItem) -> URL? {
        itemURL(server: server, meta: meta, suffix: ".preview.mp4")
    }

    /// Identifiants YouTube valides d'une fiche (au plus 3), transmis en repli.
    public static func validIDs(in meta: MetaItem) -> [String] {
        Array(meta.trailerYouTubeIDs.filter(isValidYouTubeID).prefix(3))
    }

    private static func itemURL(server: URL, meta: MetaItem, suffix: String) -> URL? {
        let fallback = validIDs(in: meta)
        guard !fallback.isEmpty, DeepLink.isValidID(meta.id) else { return nil }
        let base = server.appendingPathComponent("trailer").appendingPathComponent("for")
            .appendingPathComponent(meta.id + suffix)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "type", value: meta.type == ContentType.series ? "series" : "movie")]
            + fallback.map { URLQueryItem(name: "yt", value: $0) }
        return components.url
    }

    /// Corps de `POST /prefetch` pour des fiches (le service choisit la langue).
    public struct PrefetchItem: Codable, Sendable, Equatable {
        public var id: String
        public var type: String
        public var yt: [String]
    }

    public static func prefetchItem(for meta: MetaItem) -> PrefetchItem? {
        let fallback = validIDs(in: meta)
        guard !fallback.isEmpty, DeepLink.isValidID(meta.id) else { return nil }
        return PrefetchItem(id: meta.id, type: meta.type == ContentType.series ? "series" : "movie", yt: fallback)
    }

    /// `<serveur>/topshelf/<id>.jpg?bg=…&logo=…&title=…` : image du carrousel avec le titre
    /// incrusté, composée par le service du NAS (qui ne télécharge que des hôtes d'images connus).
    public static func topShelfImageURL(server: URL, meta: MetaItem) -> URL? {
        guard DeepLink.isValidID(meta.id), let background = meta.background else { return nil }
        // « + », « & » et « = » encodés : le serveur lit la requête comme un formulaire.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        func item(_ name: String, _ value: String) -> URLQueryItem {
            URLQueryItem(name: name, value: value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        var items = [item("bg", background.absoluteString)]
        if let logo = meta.logo { items.append(item("logo", logo.absoluteString)) }
        items.append(item("title", String(meta.name.prefix(200))))
        let base = server.appendingPathComponent("topshelf").appendingPathComponent("\(meta.id).jpg")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedQueryItems = items
        return components.url
    }

    /// `<serveur>/prefetch` : demande au service de préparer ces bandes-annonces.
    public static func prefetchURL(server: URL) -> URL {
        server.appendingPathComponent("prefetch")
    }

    public static func healthURL(server: URL) -> URL {
        server.appendingPathComponent("health")
    }

    /// Premier identifiant utilisable d'une fiche.
    public static func firstValidID(in meta: MetaItem) -> String? {
        meta.trailerYouTubeIDs.first(where: isValidYouTubeID)
    }
}
