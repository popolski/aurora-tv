import Foundation

/// Origine technique d'un flux, telle que déclarée par l'addon.
///
/// Correspond à l'énumération `StreamSource` de stremio-core. Seuls `url`
/// (HTTP/HTTPS) et, via un serveur de streaming Stremio externe, `torrent`
/// peuvent donner lieu à une lecture. Les autres sont affichés comme non lisibles.
public enum StreamSource: Sendable, Hashable, Codable {
    case url(URL)
    case youtube(String)
    case torrent(infoHash: String, fileIndex: Int?, announce: [String], fileMustInclude: [String])
    case external(URL)
    case playerFrame(URL)
    /// Archives (rar/zip/7z/tar/tgz) et NZB : nécessitent un serveur de streaming.
    case archive(kind: String)
    case unsupported

    public var kindLabel: String {
        switch self {
        case .url(let u): u.scheme?.uppercased() ?? "URL"
        case .youtube: "YouTube"
        case .torrent: "Torrent"
        case .external: "Lien externe"
        case .playerFrame: "Lecteur web"
        case .archive(let kind): kind.uppercased()
        case .unsupported: "Inconnu"
        }
    }
}

/// Un flux renvoyé par la ressource `stream` d'un addon.
public struct StreamItem: Sendable, Hashable, Codable {
    public var source: StreamSource
    public var name: String?
    public var description: String?
    public var subtitles: [SubtitleItem]
    public var behaviorHints: StreamBehaviorHints

    public init(source: StreamSource, name: String? = nil, description: String? = nil,
                subtitles: [SubtitleItem] = [], behaviorHints: StreamBehaviorHints = .init()) {
        self.source = source; self.name = name; self.description = description
        self.subtitles = subtitles; self.behaviorHints = behaviorHints
    }

    enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, announce, sources, fileMustInclude, externalUrl, playerFrameUrl
        case rarUrls, zipUrls, tgzUrls, tarUrls, nzbUrl, nzbUrls
        case zip7Urls = "7zipUrls"
        case name, description, title, subtitles, behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = c.lenientString(forKey: .name)
        self.description = c.lenientString(forKey: .description) ?? c.lenientString(forKey: .title)
        self.subtitles = c.lossyArray(SubtitleItem.self, forKey: .subtitles)
        self.behaviorHints = (try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)) ?? .init()

        // Ordre d'essai identique à l'énumération `untagged` de stremio-core.
        if let raw = c.lenientString(forKey: .url), let url = URL(string: raw), let scheme = url.scheme?.lowercased() {
            if scheme == "magnet", let torrent = Self.parseMagnet(url) {
                self.source = torrent
            } else if scheme == "http" || scheme == "https" {
                self.source = .url(url)
            } else {
                self.source = .unsupported
            }
        } else if let yt = c.lenientString(forKey: .ytId) {
            self.source = .youtube(yt)
        } else if let kind = [CodingKeys.rarUrls, .zipUrls, .zip7Urls, .tgzUrls, .tarUrls].first(where: { c.contains($0) }) {
            self.source = .archive(kind: String(kind.stringValue.dropLast(4)))
        } else if c.contains(.nzbUrl) || c.contains(.nzbUrls) {
            self.source = .archive(kind: "nzb")
        } else if let hash = c.lenientString(forKey: .infoHash), Self.isValidInfoHash(hash) {
            let announce = c.contains(.announce) ? c.lenientStrings(forKey: .announce) : c.lenientStrings(forKey: .sources)
            self.source = .torrent(
                infoHash: hash.lowercased(),
                fileIndex: c.lenientInt(forKey: .fileIdx),
                announce: announce,
                fileMustInclude: c.lenientStrings(forKey: .fileMustInclude)
            )
        } else if let frame = c.lenientURL(forKey: .playerFrameUrl) {
            self.source = .playerFrame(frame)
        } else if let ext = c.lenientURL(forKey: .externalUrl, allowedSchemes: ["http", "https", "stremio"]) {
            self.source = .external(ext)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "flux sans source reconnue"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .url(let u): try c.encode(u.absoluteString, forKey: .url)
        case .youtube(let id): try c.encode(id, forKey: .ytId)
        case .torrent(let hash, let idx, let announce, let must):
            try c.encode(hash, forKey: .infoHash)
            try c.encodeIfPresent(idx, forKey: .fileIdx)
            if !announce.isEmpty { try c.encode(announce, forKey: .announce) }
            if !must.isEmpty { try c.encode(must, forKey: .fileMustInclude) }
        case .external(let u): try c.encode(u.absoluteString, forKey: .externalUrl)
        case .playerFrame(let u): try c.encode(u.absoluteString, forKey: .playerFrameUrl)
        case .archive, .unsupported: break
        }
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        if !subtitles.isEmpty { try c.encode(subtitles, forKey: .subtitles) }
        try c.encode(behaviorHints, forKey: .behaviorHints)
    }

    static func isValidInfoHash(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    /// `magnet:?xt=urn:btih:<hash>&tr=...` → torrent (hash hexadécimal uniquement).
    static func parseMagnet(_ url: URL) -> StreamSource? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        guard let xt = items.first(where: { $0.name == "xt" })?.value?.lowercased(),
              xt.hasPrefix("urn:btih:") else { return nil }
        let hash = String(xt.dropFirst("urn:btih:".count))
        guard isValidInfoHash(hash) else { return nil }
        let trackers = items.filter { $0.name == "tr" }.compactMap(\.value)
        return .torrent(infoHash: hash, fileIndex: nil, announce: trackers, fileMustInclude: [])
    }

    /// Texte complet annoncé (nom + description + nom de fichier), base de
    /// l'analyse des caractéristiques.
    public var announcedText: String {
        [name, description, behaviorHints.filename].compactMap { $0 }.joined(separator: "\n")
    }

    /// Identité stable d'un flux, pour mémoriser « la source utilisée précédemment ».
    public var fingerprint: String {
        switch source {
        case .url(let u): "url:" + u.absoluteString
        case .torrent(let hash, let idx, _, _): "bt:\(hash):\(idx.map(String.init) ?? "-1")"
        case .youtube(let id): "yt:" + id
        case .external(let u): "ext:" + u.absoluteString
        case .playerFrame(let u): "frame:" + u.absoluteString
        case .archive(let k): "archive:\(k):\(name ?? ""):\(description ?? "")"
        case .unsupported: "unsupported:\(name ?? ""):\(description ?? "")"
        }
    }
}

public struct StreamProxyHeaders: Sendable, Hashable, Codable {
    public var request: [String: String]
    public var response: [String: String]

    public init(request: [String: String] = [:], response: [String: String] = [:]) {
        self.request = request; self.response = response
    }

    enum CodingKeys: String, CodingKey { case request, response }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        request = Self.headers(c, .request)
        response = Self.headers(c, .response)
    }

    private static func headers(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: String] {
        guard let raw = try? c.decodeIfPresent([String: JSONValue].self, forKey: key) else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in raw {
            guard let value = v.stringValue, HTTPHeaderValidator.isAcceptable(name: k, value: value) else { continue }
            out[k] = value
        }
        return out
    }
}

/// Indications de comportement d'un flux (`behaviorHints`).
public struct StreamBehaviorHints: Sendable, Hashable, Codable {
    public var notWebReady: Bool
    public var bingeGroup: String?
    public var countryWhitelist: [String]?
    public var proxyHeaders: StreamProxyHeaders?
    public var filename: String?
    public var videoHash: String?
    /// Taille annoncée en octets.
    public var videoSize: Int64?

    public init(notWebReady: Bool = false, bingeGroup: String? = nil, countryWhitelist: [String]? = nil,
                proxyHeaders: StreamProxyHeaders? = nil, filename: String? = nil, videoHash: String? = nil,
                videoSize: Int64? = nil) {
        self.notWebReady = notWebReady; self.bingeGroup = bingeGroup; self.countryWhitelist = countryWhitelist
        self.proxyHeaders = proxyHeaders; self.filename = filename; self.videoHash = videoHash; self.videoSize = videoSize
    }

    enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, countryWhitelist, proxyHeaders, filename, videoHash, videoSize
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notWebReady = c.lenientBool(forKey: .notWebReady)
        bingeGroup = c.lenientString(forKey: .bingeGroup)
        countryWhitelist = c.contains(.countryWhitelist) ? c.lenientStrings(forKey: .countryWhitelist) : nil
        proxyHeaders = try? c.decodeIfPresent(StreamProxyHeaders.self, forKey: .proxyHeaders)
        filename = c.lenientString(forKey: .filename)
        videoHash = c.lenientString(forKey: .videoHash)
        if let size = c.lenientInt64(forKey: .videoSize), size > 0 { videoSize = size } else { videoSize = nil }
    }
}

/// Sous-titre externe (ressource `subtitles` ou champ `subtitles` d'un flux).
public struct SubtitleItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// Code langue tel qu'annoncé (souvent ISO 639-2 : « fre », « fra », « eng »).
    public var lang: String
    public var url: URL
    public var label: String?
    /// Nom de l'addon d'origine (renseigné par Lanterne, pas par le protocole).
    public var addonName: String?

    public init(id: String, lang: String, url: URL, label: String? = nil, addonName: String? = nil) {
        self.id = id; self.lang = lang; self.url = url; self.label = label; self.addonName = addonName
    }

    enum CodingKeys: String, CodingKey { case id, lang, url, label, addonName }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = c.lenientURL(forKey: .url) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "sous-titre sans URL HTTP(S)"))
        }
        self.url = url
        self.id = c.lenientString(forKey: .id) ?? url.absoluteString
        self.lang = c.lenientString(forKey: .lang) ?? "und"
        self.label = c.lenientString(forKey: .label)
        self.addonName = c.lenientString(forKey: .addonName)
    }
}

/// Filtrage des en-têtes HTTP fournis par des addons (données non fiables).
public enum HTTPHeaderValidator {
    /// En-têtes que l'application refuse de laisser définir par un addon.
    static let forbidden: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding", "upgrade", "te", "trailer",
        "proxy-authorization", "proxy-connection", "keep-alive", "expect",
    ]

    public static func isAcceptable(name: String, value: String) -> Bool {
        let lower = name.lowercased()
        guard !name.isEmpty, name.count <= 64, value.count <= 4_096 else { return false }
        guard !forbidden.contains(lower) else { return false }
        let tokenChars = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard name.unicodeScalars.allSatisfy({ tokenChars.contains($0) }) else { return false }
        // Pas de retour chariot (injection d'en-têtes).
        return !value.contains("\r") && !value.contains("\n") && !value.contains("\0")
    }
}
