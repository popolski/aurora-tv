import Foundation

/// Mode de tri principal des sources.
public enum SourceSortMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case quality, prefer4K, prefer1080p, smallest, addonOrder

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quality: "Qualité décroissante"
        case .prefer4K: "Préférer la 4K"
        case .prefer1080p: "Préférer le 1080p"
        case .smallest: "Plus petite taille"
        case .addonOrder: "Ordre des addons"
        }
    }
}

/// Préférence de langue pour le tri des sources.
public enum SourceLanguagePreference: String, Sendable, Codable, CaseIterable, Identifiable {
    case none, vf, vostfr, multi

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: "Aucune"
        case .vf: "VF (audio français)"
        case .vostfr: "VOSTFR"
        case .multi: "MULTI"
        }
    }
}

public struct SourcePreferences: Sendable, Codable, Hashable {
    public var sortMode: SourceSortMode = .quality
    public var language: SourceLanguagePreference = .vf
    /// Remonter les sources jugées compatibles avec les moteurs.
    public var preferCompatible: Bool = true
    /// Remonter la source utilisée lors de la dernière lecture de ce contenu.
    public var preferPreviouslyUsed: Bool = true
    /// Masquer les sources annoncées « CAM / TS ».
    public var hideCam: Bool = true
    /// Lancer automatiquement la meilleure source (désactivable).
    public var autoPlay: Bool = false
    /// Masquer les sources non lisibles (torrent sans serveur, YouTube…).
    public var hideUnplayable: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sortMode, language, preferCompatible, preferPreviouslyUsed, hideCam, autoPlay, hideUnplayable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SourcePreferences()
        sortMode = c.value(.sortMode, default: d.sortMode)
        language = c.value(.language, default: d.language)
        preferCompatible = c.value(.preferCompatible, default: d.preferCompatible)
        preferPreviouslyUsed = c.value(.preferPreviouslyUsed, default: d.preferPreviouslyUsed)
        hideCam = c.value(.hideCam, default: d.hideCam)
        autoPlay = c.value(.autoPlay, default: d.autoPlay)
        hideUnplayable = c.value(.hideUnplayable, default: d.hideUnplayable)
    }
}

public enum SubtitleMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Jamais de sous-titres automatiques.
    case off
    /// Sous-titres dans la langue préférée si l'audio n'est pas dans cette langue.
    case foreignAudioOnly
    /// Toujours activer les sous-titres de la langue préférée.
    case always

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Désactivés"
        case .foreignAudioOnly: "Si l'audio est en VO"
        case .always: "Toujours"
        }
    }
}

public enum SubtitleSize: String, Sendable, Codable, CaseIterable, Identifiable {
    case small, medium, large, extraLarge
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .small: "Petite"
        case .medium: "Moyenne"
        case .large: "Grande"
        case .extraLarge: "Très grande"
        }
    }
    /// Taille de police en points à 1080p (tvOS met à l'échelle en 4K).
    public var pointSize: Double {
        switch self {
        case .small: 38
        case .medium: 46
        case .large: 56
        case .extraLarge: 68
        }
    }
}

public struct LanguagePreferences: Sendable, Codable, Hashable {
    /// Langue audio préférée (ISO 639-1).
    public var preferredAudio: String = "fr"
    /// Langue audio de repli.
    public var secondaryAudio: String = "en"
    /// Langue des sous-titres préférée.
    public var preferredSubtitle: String = "fr"
    public var subtitleMode: SubtitleMode = .foreignAudioOnly
    public var subtitleSize: SubtitleSize = .medium
    /// Position verticale : 0 = tout en bas, 1 = haut de l'image.
    public var subtitleVerticalOffset: Double = 0.06
    public var subtitleBackground: Bool = true
    /// Décalage des sous-titres externes, en secondes (positif = plus tard).
    public var subtitleDelay: Double = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case preferredAudio, secondaryAudio, preferredSubtitle, subtitleMode, subtitleSize
        case subtitleVerticalOffset, subtitleBackground, subtitleDelay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LanguagePreferences()
        preferredAudio = c.value(.preferredAudio, default: d.preferredAudio)
        secondaryAudio = c.value(.secondaryAudio, default: d.secondaryAudio)
        preferredSubtitle = c.value(.preferredSubtitle, default: d.preferredSubtitle)
        subtitleMode = c.value(.subtitleMode, default: d.subtitleMode)
        subtitleSize = c.value(.subtitleSize, default: d.subtitleSize)
        subtitleVerticalOffset = c.value(.subtitleVerticalOffset, default: d.subtitleVerticalOffset)
        subtitleBackground = c.value(.subtitleBackground, default: d.subtitleBackground)
        subtitleDelay = c.value(.subtitleDelay, default: d.subtitleDelay)
    }
}

public enum PlayerEngineChoice: String, Sendable, Codable, CaseIterable, Identifiable {
    /// AetherEngine pour tout (natif quand possible, FFmpeg sinon).
    case automatic
    /// AVPlayer seul (diagnostic ; MKV/DTS non pris en charge).
    case system

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: "Automatique (recommandé)"
        case .system: "Lecteur système AVPlayer"
        }
    }
}

public struct PlaybackPreferences: Sendable, Codable, Hashable {
    public var engine: PlayerEngineChoice = .automatic
    /// Adapter fréquence et plage dynamique de l'écran au contenu
    /// (à combiner avec Réglages tvOS › Vidéo et audio › Adapter le contenu).
    public var matchContent: Bool = true
    /// Déclarer que le téléviseur affiche le Dolby Vision (assertion, voir docs).
    public var panelSupportsDolbyVision: Bool = false
    public var skipInterval: Double = 10
    /// Lire automatiquement l'épisode suivant.
    public var autoPlayNextEpisode: Bool = true
    /// URL du serveur de streaming Stremio (torrents), ex. `http://192.168.1.20:11470`.
    public var streamingServerURL: String = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case engine, matchContent, panelSupportsDolbyVision, skipInterval, autoPlayNextEpisode, streamingServerURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackPreferences()
        engine = c.value(.engine, default: d.engine)
        matchContent = c.value(.matchContent, default: d.matchContent)
        panelSupportsDolbyVision = c.value(.panelSupportsDolbyVision, default: d.panelSupportsDolbyVision)
        skipInterval = c.value(.skipInterval, default: d.skipInterval)
        autoPlayNextEpisode = c.value(.autoPlayNextEpisode, default: d.autoPlayNextEpisode)
        streamingServerURL = c.value(.streamingServerURL, default: d.streamingServerURL)
    }

    public var streamingServer: URL? {
        let s = streamingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// Ensemble des réglages persistants.
public struct AppSettings: Sendable, Codable, Hashable {
    public var sources = SourcePreferences()
    public var languages = LanguagePreferences()
    public var playback = PlaybackPreferences()
    /// Masquer les addons/catalogues « adultes ».
    public var hideAdultContent: Bool = true
    /// Catalogues masqués de l'accueil (identifiants `CatalogRef.id`).
    public var hiddenHomeCatalogs: [String] = []
    /// Ordre personnalisé des catalogues d'accueil (identifiants `CatalogRef.id`).
    public var homeCatalogOrder: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case sources, languages, playback, hideAdultContent, hiddenHomeCatalogs, homeCatalogOrder }

    /// Décodage tolérant : un réglage ajouté dans une version ultérieure ne
    /// doit jamais faire perdre les autres.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = c.value(.sources, default: SourcePreferences())
        languages = c.value(.languages, default: LanguagePreferences())
        playback = c.value(.playback, default: PlaybackPreferences())
        hideAdultContent = c.value(.hideAdultContent, default: true)
        hiddenHomeCatalogs = c.value(.hiddenHomeCatalogs, default: [String]())
        homeCatalogOrder = c.value(.homeCatalogOrder, default: [String]())
    }
}

extension KeyedDecodingContainer {
    /// Valeur décodée si présente et valide, sinon la valeur par défaut.
    /// Une valeur d'énumération inconnue (réglage supprimé) retombe sur le défaut.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
