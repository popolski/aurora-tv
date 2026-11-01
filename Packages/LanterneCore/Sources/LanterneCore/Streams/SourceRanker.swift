import Foundation

/// Une source analysée, prête à être affichée et triée.
public struct RankedSource: Sendable, Hashable, Identifiable {
    public let stream: StreamItem
    public let addonName: String
    public let addonID: String
    /// Position de l'addon dans la liste installée (départage stable).
    public let addonIndex: Int
    /// Position du flux dans la réponse de l'addon.
    public let indexInAddon: Int
    public let traits: StreamTraits
    public let playability: Playability

    public var id: String { "\(addonID)|\(indexInAddon)|\(stream.fingerprint)" }

    public init(stream: StreamItem, addonName: String, addonID: String, addonIndex: Int, indexInAddon: Int,
                traits: StreamTraits, playability: Playability) {
        self.stream = stream; self.addonName = addonName; self.addonID = addonID; self.addonIndex = addonIndex
        self.indexInAddon = indexInAddon; self.traits = traits; self.playability = playability
    }

    /// Titre principal affichable (première ligne du nom ou de la description).
    public var title: String {
        let candidates = [stream.description, stream.name, stream.behaviorHints.filename]
        for c in candidates {
            if let line = c?.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
                return line
            }
        }
        return addonName
    }

    /// Texte secondaire (reste de la description), sans doublon avec le titre.
    public var subtitle: String? {
        guard let d = stream.description else { return nil }
        let lines = d.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rest = lines.dropFirst().joined(separator: " · ")
        return rest.isEmpty ? nil : rest
    }
}

/// Tri déterministe et explicable des sources selon les préférences.
public struct SourceRanker: Sendable {
    public var preferences: SourcePreferences
    /// Empreinte de la source utilisée la dernière fois pour ce contenu.
    public var previouslyUsedFingerprint: String?
    public var preferredAudioLanguage: String

    public init(preferences: SourcePreferences, previouslyUsedFingerprint: String? = nil, preferredAudioLanguage: String = "fr") {
        self.preferences = preferences
        self.previouslyUsedFingerprint = previouslyUsedFingerprint
        self.preferredAudioLanguage = preferredAudioLanguage
    }

    public static func analyze(_ stream: StreamItem, addon: AddonDescriptor, addonIndex: Int, indexInAddon: Int,
                               streamingServer: URL?) -> RankedSource {
        let traits = StreamTraitsParser.parse(stream)
        let playability = PlayabilityClassifier.classify(stream, traits: traits, streamingServer: streamingServer)
        return RankedSource(stream: stream, addonName: addon.manifest.name, addonID: addon.manifest.id,
                            addonIndex: addonIndex, indexInAddon: indexInAddon, traits: traits, playability: playability)
    }

    /// Filtre (CAM, non lisibles) puis trie.
    public func rank(_ sources: [RankedSource]) -> [RankedSource] {
        let filtered = sources.filter { s in
            if preferences.hideCam && s.traits.sourceQuality == .cam { return false }
            if preferences.hideUnplayable && !s.playability.isPlayable { return false }
            return true
        }
        return filtered.sorted { a, b in compare(a, b) }
    }

    /// Meilleure source lisible pour la lecture automatique.
    public func best(_ sources: [RankedSource]) -> RankedSource? {
        rank(sources).first { s in
            guard let playable = s.playability.playable else { return false }
            return playable.fit != .unlikely
        }
    }

    /// `true` si `a` doit précéder `b`.
    func compare(_ a: RankedSource, _ b: RankedSource) -> Bool {
        let ka = key(a), kb = key(b)
        for (x, y) in zip(ka, kb) where x != y { return x > y }
        if a.addonIndex != b.addonIndex { return a.addonIndex < b.addonIndex }
        return a.indexInAddon < b.indexInAddon
    }

    /// Clé lexicographique (valeurs plus grandes = meilleur rang).
    func key(_ s: RankedSource) -> [Int] {
        let t = s.traits
        var k: [Int] = []
        // 1. Source utilisée précédemment.
        if preferences.preferPreviouslyUsed, let fp = previouslyUsedFingerprint {
            k.append(s.stream.fingerprint == fp ? 1 : 0)
        }
        // 2. Lisible avant non lisible, toujours.
        k.append(s.playability.isPlayable ? 1 : 0)
        // 3. Mode « ordre des addons » : on s'arrête là (départage par addon/indice).
        if preferences.sortMode == .addonOrder { return k }
        // 4. Compatibilité estimée.
        if preferences.preferCompatible {
            k.append(s.playability.playable?.fit.rawValue ?? 0)
        }
        // 5. Langue.
        k.append(languageScore(t))
        // Mode « plus petite taille » : la taille prime sur tout le reste.
        if preferences.sortMode == .smallest {
            if let size = t.sizeBytes {
                k.append(-Int(min(size / 1_048_576, Int64(Int32.max))))
            } else {
                k.append(Int(Int32.min))
            }
        }
        // 6. Résolution selon le mode.
        k.append(resolutionScore(t.resolution))
        // 7. HDR (à résolution égale), lien en cache, qualité de source.
        if preferences.sortMode != .smallest {
            k.append(t.hdr.isEmpty ? 0 : (t.hdr.contains(.dolbyVision) ? 2 : 1))
        }
        k.append(t.debridCached ? 1 : 0)
        k.append(t.sourceQuality.rawValue)
        // 8. Taille (la plus grande d'abord, à qualité égale).
        if preferences.sortMode != .smallest {
            k.append(t.sizeBytes.map { Int(min($0 / 1_048_576, Int64(Int32.max))) } ?? 0)
        }
        return k
    }

    func languageScore(_ t: StreamTraits) -> Int {
        switch preferences.language {
        case .none: return 0
        case .vf:
            if t.audioLanguages.contains(preferredAudioLanguage) && !t.isVOSTFR { return 3 }
            if t.isMultiAudio { return 2 }
            return t.isVOSTFR ? 1 : 0
        case .vostfr:
            if t.isVOSTFR { return 3 }
            if t.isMultiAudio { return 2 }
            return 0
        case .multi:
            if t.isMultiAudio { return 3 }
            if t.audioLanguages.contains(preferredAudioLanguage) { return 2 }
            return 0
        }
    }

    func resolutionScore(_ r: VideoResolution?) -> Int {
        guard let r else { return 0 }
        switch preferences.sortMode {
        case .quality, .addonOrder:
            return r.rawValue
        case .prefer4K:
            return r == .uhd2160 ? 10_000 : r.rawValue
        case .prefer1080p:
            // 1080p d'abord, puis 720p, puis 4K (débit élevé), puis SD.
            switch r {
            case .fhd1080: return 5
            case .hd720: return 4
            case .qhd1440: return 3
            case .uhd2160: return 2
            case .sd: return 1
            }
        case .smallest:
            return 0
        }
    }
}
