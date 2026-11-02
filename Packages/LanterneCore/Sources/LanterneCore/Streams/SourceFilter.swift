import Foundation

/// Filtres rapides de la liste des sources (qualité, langue, addon, HDR), avec le nombre
/// de sources par option. Aucun filtre actif = tout afficher.
public struct SourceFilter: Sendable, Equatable {
    public var resolutions: Set<String> = []
    public var languages: Set<String> = []
    public var addons: Set<String> = []
    public var hdrOnly = false

    public init() {}

    public var isActive: Bool { !resolutions.isEmpty || !languages.isEmpty || !addons.isEmpty || hdrOnly }

    /// Option de filtre : clé, libellé affiché, nombre de sources.
    public struct Option: Sendable, Equatable, Identifiable {
        public var key: String
        public var label: String
        public var count: Int
        public var id: String { key }
    }

    // MARK: Clés

    public static let unknownKey = "?"

    public static func resolutionKey(_ source: RankedSource) -> String {
        source.traits.resolution?.label ?? unknownKey
    }

    /// Langues d'une source : « fr » (VF), « multi », « vostfr », langues audio, sinon « ? ».
    public static func languageKeys(_ source: RankedSource) -> Set<String> {
        let t = source.traits
        var keys = Set(t.audioLanguages)
        if t.hasFrench { keys.insert("fr") }
        if t.isMultiAudio { keys.insert("multi") }
        if t.isVOSTFR { keys.insert("vostfr") }
        return keys.isEmpty ? [unknownKey] : keys
    }

    public static func isHDR(_ source: RankedSource) -> Bool { !source.traits.hdr.isEmpty }

    // MARK: Application

    public func apply(_ sources: [RankedSource]) -> [RankedSource] {
        guard isActive else { return sources }
        return sources.filter { matches($0) }
    }

    public func matches(_ source: RankedSource, ignoring dimension: Dimension? = nil) -> Bool {
        if dimension != .resolution, !resolutions.isEmpty, !resolutions.contains(Self.resolutionKey(source)) { return false }
        if dimension != .language, !languages.isEmpty, languages.isDisjoint(with: Self.languageKeys(source)) { return false }
        if dimension != .addon, !addons.isEmpty, !addons.contains(source.addonID) { return false }
        if dimension != .hdr, hdrOnly, !Self.isHDR(source) { return false }
        return true
    }

    public enum Dimension: Sendable { case resolution, language, addon, hdr }

    // MARK: Options et compteurs

    /// Compteurs d'une dimension en tenant compte des autres filtres actifs (comme une recherche à facettes).
    public func resolutionOptions(_ sources: [RankedSource]) -> [Option] {
        let pool = sources.filter { matches($0, ignoring: .resolution) }
        let counts = Dictionary(grouping: pool, by: Self.resolutionKey).mapValues(\.count)
        let order = VideoResolution.allCases.reversed().map(\.label) + [Self.unknownKey]
        return order.compactMap { key in
            counts[key].map { Option(key: key, label: key == Self.unknownKey ? "Non précisée" : key, count: $0) }
        }
    }

    public func languageOptions(_ sources: [RankedSource]) -> [Option] {
        let pool = sources.filter { matches($0, ignoring: .language) }
        var counts: [String: Int] = [:]
        for source in pool { for key in Self.languageKeys(source) { counts[key, default: 0] += 1 } }
        let leading = ["fr", "multi", "vostfr"]
        let rest = counts.keys.filter { !leading.contains($0) && $0 != Self.unknownKey }
            .sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
        return (leading + rest + [Self.unknownKey]).compactMap { key in
            counts[key].map { Option(key: key, label: Self.languageLabel(key), count: $0) }
        }
    }

    public func addonOptions(_ sources: [RankedSource]) -> [Option] {
        let pool = sources.filter { matches($0, ignoring: .addon) }
        var seen: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for source in pool {
            if counts[source.addonID] == nil { seen.append(source.addonID) }
            counts[source.addonID, default: 0] += 1
            names[source.addonID] = source.addonName
        }
        return seen.map { Option(key: $0, label: names[$0] ?? $0, count: counts[$0] ?? 0) }
    }

    public func hdrCount(_ sources: [RankedSource]) -> Int {
        sources.filter { matches($0, ignoring: .hdr) && Self.isHDR($0) }.count
    }

    public static func languageLabel(_ key: String) -> String {
        switch key {
        case "fr": "Français (VF)"
        case "multi": "Multi-audio"
        case "vostfr": "VOSTFR"
        case unknownKey: "Non précisée"
        default: LanguageCode.displayName(key)
        }
    }
}
