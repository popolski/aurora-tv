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
