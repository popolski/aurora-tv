import Foundation

/// Conteneur partagé entre l'app et l'extension Top Shelf (groupe d'apps).
///
/// Une installation par atvloadly peut renommer les identifiants (bundle, groupes)
/// lors de la signature avec un Apple ID gratuit : le nom réel du groupe est donc lu
/// dans le profil de provisionnement embarqué, et non supposé.
public enum SharedContainer {
    public static let defaultGroupID = "group.io.github.popolski.lanterne"
    public static let extensionName = "AuroraTopShelf.appex"

    /// Groupe à utiliser par l'app et par l'extension : le premier (ordre alphabétique)
    /// présent dans les deux profils, pour que les deux côtés choisissent le même.
    /// Constaté sur l'appareil (build 25) : atvloadly a renommé le groupe de l'app en
    /// « group.io.github.popolski.lanterne.<équipe>.<équipe> ».
    public static func groupID(bundle: Bundle = .main) -> String {
        let (app, ext) = provisionedGroups(from: bundle)
        return commonGroup(app: app, extension: ext) ?? app.first ?? ext.first ?? defaultGroupID
    }

    /// Groupes des profils de l'app et de l'extension, que l'on soit dans l'une ou l'autre.
    public static func provisionedGroups(from bundle: Bundle = .main) -> (app: [String], extension: [String]) {
        let url = bundle.bundleURL
        let appURL: URL, extURL: URL
        if url.pathExtension == "appex" {
            appURL = url.deletingLastPathComponent().deletingLastPathComponent()
            extURL = url
        } else {
            appURL = url
            extURL = url.appendingPathComponent("PlugIns").appendingPathComponent(extensionName)
        }
        return (groups(inBundleAt: appURL), groups(inBundleAt: extURL))
    }

    public static func commonGroup(app: [String], extension ext: [String]) -> String? {
        Set(app).intersection(ext).sorted().first
    }

    public static func groups(inBundleAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("embedded.mobileprovision")) else { return [] }
        return groups(fromProvision: data)
    }

    /// Lit `com.apple.security.application-groups` dans un profil (plist entouré d'une signature CMS).
    public static func groups(fromProvision data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return [] }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups.filter { !$0.isEmpty && !$0.contains("*") }
    }

    public static func groupID(fromProvision data: Data) -> String? {
        groups(fromProvision: data).first
    }

    public static func defaults(bundle: Bundle = .main) -> UserDefaults? {
        UserDefaults(suiteName: groupID(bundle: bundle))
    }
}

/// Ce que l'app transmet à l'extension Top Shelf.
public struct TopShelfConfig: Codable, Sendable, Equatable {
    /// Adresse du service de bandes-annonces (NAS), si configurée.
    public var trailerServer: String?
    public var updatedAt: Date

    public static let key = "topshelf.config.v1"

    public init(trailerServer: String?, updatedAt: Date = Date()) {
        self.trailerServer = trailerServer
        self.updatedAt = updatedAt
    }

    public var server: URL? {
        var p = TrailerPreferences()
        p.serverURL = trailerServer ?? ""
        return p.server
    }

    public static func load(from defaults: UserDefaults?) -> TopShelfConfig? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TopShelfConfig.self, from: data)
    }

    public func save(to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Compte rendu du dernier rafraîchissement du carrousel, écrit par l'extension.
/// Si l'app le lit, c'est que le groupe d'apps est réellement partagé.
public struct TopShelfStatus: Codable, Sendable, Equatable {
    public var date: Date
    public var groupID: String
    public var serverKnown: Bool
    public var items: Int
    public var trailers: Int

    public static let key = "topshelf.status.v1"

    public init(date: Date = Date(), groupID: String, serverKnown: Bool, items: Int, trailers: Int) {
        self.date = date; self.groupID = groupID; self.serverKnown = serverKnown; self.items = items; self.trailers = trailers
    }

    public static func load(from defaults: UserDefaults?) -> TopShelfStatus? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TopShelfStatus.self, from: data)
    }

    public func save(to defaults: UserDefaults?) {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Contenu du carrousel : dernières sorties de films (catalogue Cinemeta public).
public enum TopShelfFeed {
    public static let cinemetaManifest = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!

    /// Catalogue « par année » de Cinemeta (classé par popularité).
    public static func catalogURL(year: Int) -> URL? {
        try? AddonURLBuilder.url(for: .catalog(type: ContentType.movie, id: "year",
                                               extra: [ExtraValue(name: ExtraName.genre, value: String(year))]),
                                 transportURL: cinemetaManifest)
    }

    public static func metaURL(id: String) -> URL? {
        guard DeepLink.isValidID(id) else { return nil }
        return try? AddonURLBuilder.url(for: .meta(type: ContentType.movie, id: id), transportURL: cinemetaManifest)
    }

    public static func decodeCatalog(_ data: Data) throws -> [MetaItem] {
        try JSONDecoder().decode(CatalogResponse.self, from: data).metas
    }

    public static func decodeMeta(_ data: Data) throws -> MetaItem? {
        try JSONDecoder().decode(MetaResponse.self, from: data).meta
    }

    /// Films déjà sortis, avec image de fond, du plus récent au plus ancien.
    public static func latest(_ metas: [MetaItem], now: Date = Date(), limit: Int = 10) -> [MetaItem] {
        var seen = Set<String>()
        return metas
            .filter { $0.type == ContentType.movie && $0.background != nil && DeepLink.isValidID($0.id) }
            .filter { ($0.released ?? .distantPast) <= now }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

/// Liens `aurora://` ouverts par le Top Shelf : `aurora://meta/<type>/<id>` (fiche)
/// et `aurora://play/<type>/<id>?name=…` (lecture). Tout autre lien est ignoré.
public struct DeepLink: Sendable, Equatable {
    public enum Action: String, Sendable { case meta, play }

    public var action: Action
    public var type: String
    public var id: String
    public var name: String?

    public static let scheme = "aurora"

    public init(action: Action, type: String, id: String, name: String? = nil) {
        self.action = action; self.type = type; self.id = id; self.name = name
    }

    /// Identifiants acceptés : `tt…`, `kitsu:…`, etc. (commence par une lettre ou un chiffre ;
    /// lettres, chiffres, `:_.-` ; 64 caractères au plus).
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return id.count <= 64 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || ":_.-".unicodeScalars.contains($0)
        }
    }

    public var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = action.rawValue
        c.path = "/\(type)/\(id)"
        if let name, !name.isEmpty { c.queryItems = [URLQueryItem(name: "name", value: String(name.prefix(200)))] }
        return c.url
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host?.lowercased(), let action = Action(rawValue: host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, [ContentType.movie, ContentType.series].contains(parts[0]),
              Self.isValidID(parts[1]) else { return nil }
        self.action = action
        self.type = parts[0]
        self.id = parts[1]
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
        self.name = name.map { String($0.prefix(200)) }
    }
}

extension MetaItem {
    /// Durée en secondes depuis « 148 min », « 2h 28min », « 1 h 05 »…
    public var runtimeSeconds: TimeInterval? {
        guard let runtime = runtime?.lowercased(), !runtime.isEmpty else { return nil }
        func capture(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: runtime, range: NSRange(runtime.startIndex..., in: runtime)),
                  let range = Range(match.range(at: 1), in: runtime) else { return nil }
            return Int(runtime[range])
        }
        let total: Int
        if let hours = capture(#"(\d+)\s*h"#) {
            total = hours * 3600 + (capture(#"h\s*(\d+)"#) ?? 0) * 60
        } else if let minutes = capture(#"(\d+)"#) {
            total = minutes * 60
        } else {
            return nil
        }
        return total > 0 ? TimeInterval(total) : nil
    }
}
