import Foundation

/// Manifeste d'un addon Stremio (`/manifest.json`).
///
/// Référence : stremio-addon-sdk `docs/api/responses/manifest.md` et le type
/// `Manifest` de stremio-core. Le décodage est tolérant : un catalogue ou une
/// ressource invalide est ignoré, mais `id`, `name` et `resources` sont requis.
public struct AddonManifest: Sendable, Hashable, Codable {
    public var id: String
    public var version: String
    public var name: String
    public var description: String?
    public var logo: URL?
    public var background: URL?
    public var types: [String]
    public var resources: [ManifestResource]
    public var idPrefixes: [String]?
    public var catalogs: [ManifestCatalog]
    public var behaviorHints: ManifestBehaviorHints

    public init(
        id: String, version: String, name: String, description: String? = nil,
        logo: URL? = nil, background: URL? = nil, types: [String], resources: [ManifestResource],
        idPrefixes: [String]? = nil, catalogs: [ManifestCatalog] = [],
        behaviorHints: ManifestBehaviorHints = .init()
    ) {
        self.id = id; self.version = version; self.name = name; self.description = description
        self.logo = logo; self.background = background; self.types = types; self.resources = resources
        self.idPrefixes = idPrefixes; self.catalogs = catalogs; self.behaviorHints = behaviorHints
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, types, resources, idPrefixes, catalogs, behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "id manquant"))
        }
        self.id = id
        self.version = c.lenientString(forKey: .version) ?? "0.0.0"
        self.name = c.lenientString(forKey: .name) ?? id
        self.description = c.lenientString(forKey: .description)
        self.logo = c.lenientURL(forKey: .logo)
        self.background = c.lenientURL(forKey: .background)
        self.types = c.lenientStrings(forKey: .types)
        self.resources = c.lossyArray(ManifestResource.self, forKey: .resources)
        let prefixes = c.lenientStrings(forKey: .idPrefixes)
        self.idPrefixes = (try? c.decodeNil(forKey: .idPrefixes)) == false && c.contains(.idPrefixes) ? prefixes : nil
        // Déduplication (type, id) comme stremio-core.
        var seen = Set<String>()
        self.catalogs = c.lossyArray(ManifestCatalog.self, forKey: .catalogs).filter {
            seen.insert("\($0.type)/\($0.id)").inserted
        }
        self.behaviorHints = (try? c.decodeIfPresent(ManifestBehaviorHints.self, forKey: .behaviorHints)) ?? .init()
    }

    /// L'addon déclare-t-il la ressource `name` pour ce type et cet identifiant ?
    /// Logique identique à stremio-core (`Manifest::is_resource_supported`) :
    /// les `types`/`idPrefixes` de la ressource priment sur ceux du manifeste.
    public func supports(resource name: String, type: String, id: String?) -> Bool {
        guard let resource = resources.first(where: { $0.name == name }) else { return false }
        let types = resource.types ?? self.types
        guard types.contains(type) else { return false }
        guard let id else { return true }
        let prefixes = resource.idPrefixes ?? self.idPrefixes
        guard let prefixes else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }

    public func hasResource(_ name: String) -> Bool {
        resources.contains { $0.name == name }
    }
}

/// Une ressource déclarée : forme courte (`"stream"`) ou complète
/// (`{"name": "stream", "types": [...], "idPrefixes": [...]}`).
public struct ManifestResource: Sendable, Hashable, Codable {
    public var name: String
    public var types: [String]?
    public var idPrefixes: [String]?

    public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name; self.types = types; self.idPrefixes = idPrefixes
    }

    enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.name = name
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.types = c.contains(.types) ? c.lenientStrings(forKey: .types) : nil
        self.idPrefixes = c.contains(.idPrefixes) ? c.lenientStrings(forKey: .idPrefixes) : nil
    }
}

/// Catalogue déclaré dans le manifeste.
public struct ManifestCatalog: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var type: String
    public var name: String?
    public var extra: [ExtraProperty]

    public var stableID: String { "\(type)/\(id)" }

    public init(id: String, type: String, name: String? = nil, extra: [ExtraProperty] = []) {
        self.id = id; self.type = type; self.name = name; self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case id, type, name, extra, extraRequired, extraSupported }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id), let type = c.lenientString(forKey: .type) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "catalogue sans id/type"))
        }
        self.id = id
        self.type = type
        self.name = c.lenientString(forKey: .name)
        if c.contains(.extra) {
            var seen = Set<String>()
            self.extra = c.lossyArray(ExtraProperty.self, forKey: .extra).filter { seen.insert($0.name).inserted }
        } else {
            // Forme courte historique : extraRequired / extraSupported.
            let required = c.lenientStrings(forKey: .extraRequired)
            let supported = c.lenientStrings(forKey: .extraSupported)
            var names: [String] = []
            for n in supported + required where !names.contains(n) { names.append(n) }
            self.extra = names.map { ExtraProperty(name: $0, isRequired: required.contains($0)) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(extra, forKey: .extra)
    }

    public var requiredExtras: [ExtraProperty] { extra.filter(\.isRequired) }

    public func extraProperty(_ name: String) -> ExtraProperty? { extra.first { $0.name == name } }

    public var supportsSearch: Bool { extraProperty(ExtraName.search) != nil }
    public var supportsSkip: Bool { extraProperty(ExtraName.skip) != nil }
    public var genreOptions: [String] { extraProperty(ExtraName.genre)?.options ?? [] }

    /// Catalogue utilisable « tel quel » (sans extra obligatoire) : éligible à l'accueil.
    public var isBrowsableWithoutExtra: Bool { requiredExtras.isEmpty }

    /// Les extras fournis satisfont-ils les exigences du catalogue ?
    public func accepts(_ extras: [ExtraValue]) -> Bool {
        let provided = Set(extras.map(\.name))
        guard requiredExtras.allSatisfy({ provided.contains($0.name) }) else { return false }
        return extras.allSatisfy { value in extraProperty(value.name) != nil }
    }
}

public enum ExtraName {
    public static let search = "search"
    public static let genre = "genre"
    public static let skip = "skip"
}

/// Propriété « extra » d'un catalogue (`search`, `genre`, `skip`…).
public struct ExtraProperty: Sendable, Hashable, Codable {
    public var name: String
    public var isRequired: Bool
    public var options: [String]
    public var optionsLimit: Int

    public init(name: String, isRequired: Bool = false, options: [String] = [], optionsLimit: Int = 1) {
        self.name = name; self.isRequired = isRequired; self.options = options; self.optionsLimit = optionsLimit
    }

    enum CodingKeys: String, CodingKey { case name, isRequired, options, optionsLimit }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.lenientString(forKey: .name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "extra sans nom"))
        }
        self.name = name
        self.isRequired = c.lenientBool(forKey: .isRequired)
        self.options = c.lenientStrings(forKey: .options)
        self.optionsLimit = max(1, c.lenientInt(forKey: .optionsLimit) ?? 1)
    }
}

/// Valeur d'un extra passée dans une requête de ressource.
public struct ExtraValue: Sendable, Hashable, Codable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct ManifestBehaviorHints: Sendable, Hashable, Codable {
    public var adult: Bool
    public var p2p: Bool
    public var configurable: Bool
    public var configurationRequired: Bool

    public init(adult: Bool = false, p2p: Bool = false, configurable: Bool = false, configurationRequired: Bool = false) {
        self.adult = adult; self.p2p = p2p; self.configurable = configurable; self.configurationRequired = configurationRequired
    }

    enum CodingKeys: String, CodingKey { case adult, p2p, configurable, configurationRequired }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adult = c.lenientBool(forKey: .adult)
        p2p = c.lenientBool(forKey: .p2p)
        configurable = c.lenientBool(forKey: .configurable)
        configurationRequired = c.lenientBool(forKey: .configurationRequired)
    }
}
