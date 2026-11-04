import Foundation

/// Addon installé : URL de transport + manifeste (forme du `Descriptor` Stremio).
public struct AddonDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// URL complète du manifeste (`…/manifest.json`). Peut contenir une
    /// configuration secrète : ne jamais la journaliser en clair.
    public var transportURL: URL
    public var manifest: AddonManifest
    public var flags: AddonFlags

    public var id: String { transportURL.absoluteString }

    public init(transportURL: URL, manifest: AddonManifest, flags: AddonFlags = .init()) {
        self.transportURL = transportURL; self.manifest = manifest; self.flags = flags
    }

    enum CodingKeys: String, CodingKey { case transportUrl, manifest, flags }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.lenientURL(forKey: .transportUrl) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "transportUrl invalide"))
        }
        self.transportURL = url
        self.manifest = try c.decode(AddonManifest.self, forKey: .manifest)
        self.flags = (try? c.decodeIfPresent(AddonFlags.self, forKey: .flags)) ?? .init()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transportURL.absoluteString, forKey: .transportUrl)
        try c.encode(manifest, forKey: .manifest)
        try c.encode(flags, forKey: .flags)
    }

    /// Hôte affichable (sans chemin, donc sans configuration secrète).
    public var displayHost: String { transportURL.host ?? "?" }
}

public struct AddonFlags: Sendable, Hashable, Codable {
    public var official: Bool
    public var protected: Bool
    public init(official: Bool = false, protected: Bool = false) { self.official = official; self.protected = protected }

    enum CodingKeys: String, CodingKey { case official, protected }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        official = c.lenientBool(forKey: .official)
        protected = c.lenientBool(forKey: .protected)
    }
}

/// Ressource demandée à un addon.
public struct ResourceRequest: Sendable, Hashable {
    public var resource: String
    public var type: String
    public var id: String
    public var extra: [ExtraValue]

    public init(resource: String, type: String, id: String, extra: [ExtraValue] = []) {
        self.resource = resource; self.type = type; self.id = id; self.extra = extra
    }

    public static func catalog(type: String, id: String, extra: [ExtraValue] = []) -> Self {
        .init(resource: "catalog", type: type, id: id, extra: extra)
    }
    public static func meta(type: String, id: String) -> Self { .init(resource: "meta", type: type, id: id) }
    public static func stream(type: String, id: String) -> Self { .init(resource: "stream", type: type, id: id) }
    public static func subtitles(type: String, id: String, extra: [ExtraValue] = []) -> Self {
        .init(resource: "subtitles", type: type, id: id, extra: extra)
    }
}

public enum AddonURLError: Error, Sendable, Equatable {
    case notAManifestURL
    case unsupportedScheme
    case invalid
}

/// Construction des URL de ressources, à l'identique de
/// `AddonHTTPTransport::resource` dans stremio-core :
/// `<base>/<resource>/<type>/<id>[/<extra>].json`, chaque composant encodé
/// avec le jeu de caractères d'`encodeURIComponent`.
public enum AddonURLBuilder {
    public static let manifestSuffix = "/manifest.json"

    /// Normalise une saisie utilisateur : `stremio://` → `https://` (`http://`
    /// pour une adresse du réseau local, où les addons auto-hébergés n'ont
    /// généralement pas de certificat), ajout de `/manifest.json` si absent.
    public static func normalizeManifestURL(_ input: String) throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("stremio://") {
            let rest = s.dropFirst("stremio://".count)
            let host = URLComponents(string: "https://" + rest)?.host ?? ""
            s = (URLPolicy.isLocalHost(host) ? "http://" : "https://") + rest
        }
        guard var comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased() else {
            throw AddonURLError.invalid
        }
        guard scheme == "https" || scheme == "http" else { throw AddonURLError.unsupportedScheme }
        guard let host = comps.host, !host.isEmpty else { throw AddonURLError.invalid }
        if !comps.percentEncodedPath.hasSuffix(manifestSuffix) {
            var path = comps.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            comps.percentEncodedPath = path + manifestSuffix
        }
        comps.fragment = nil
        guard let url = comps.url else { throw AddonURLError.invalid }
        return url
    }

    public static func url(for request: ResourceRequest, transportURL: URL) throws -> URL {
        let raw = transportURL.absoluteString
        guard let range = raw.range(of: manifestSuffix, options: .backwards) else {
            throw AddonURLError.notAManifestURL
        }
        var path = "/\(encode(request.resource))/\(encode(request.type))/\(encode(request.id))"
        if !request.extra.isEmpty {
            path += "/" + request.extra.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
        }
        path += ".json"
        let built = raw.replacingCharacters(in: range, with: path)
        guard let url = URL(string: built) else { throw AddonURLError.invalid }
        return url
    }

    /// Jeu non réservé d'`encodeURIComponent` : A-Z a-z 0-9 - _ . ! ~ * ' ( )
    static let uriComponentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return set
    }()

    public static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? s
    }
}

/// Corps d'une réponse de ressource, avec les directives de cache éventuelles.
struct CatalogResponse: Decodable {
    var metas: [MetaItem]
    var cacheMaxAge: Int?
    enum CodingKeys: String, CodingKey { case metas, cacheMaxAge }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.metas) else {
            throw DecodingError.keyNotFound(CodingKeys.metas, .init(codingPath: [], debugDescription: "metas absent"))
        }
        metas = c.lossyArray(MetaItem.self, forKey: .metas)
        cacheMaxAge = c.lenientInt(forKey: .cacheMaxAge)
    }
}

struct MetaResponse: Decodable {
    var meta: MetaItem?
    var cacheMaxAge: Int?
    enum CodingKeys: String, CodingKey { case meta, cacheMaxAge }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `{"meta": null}` est une réponse valide signifiant « inconnu ».
        meta = try? c.decodeIfPresent(MetaItem.self, forKey: .meta)
        cacheMaxAge = c.lenientInt(forKey: .cacheMaxAge)
    }
}

struct StreamsResponse: Decodable {
    var streams: [StreamItem]
    var cacheMaxAge: Int?
    enum CodingKeys: String, CodingKey { case streams, cacheMaxAge }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.streams) else {
            throw DecodingError.keyNotFound(CodingKeys.streams, .init(codingPath: [], debugDescription: "streams absent"))
        }
        streams = c.lossyArray(StreamItem.self, forKey: .streams)
        cacheMaxAge = c.lenientInt(forKey: .cacheMaxAge)
    }
}

struct SubtitlesResponse: Decodable {
    var subtitles: [SubtitleItem]
    var cacheMaxAge: Int?
    enum CodingKeys: String, CodingKey { case subtitles, cacheMaxAge }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = c.lossyArray(SubtitleItem.self, forKey: .subtitles)
        cacheMaxAge = c.lenientInt(forKey: .cacheMaxAge)
    }
}
