import Foundation

/// Pistes choisies à la main pour une série (langue audio, sous-titres), reprises
/// aux épisodes suivants à la place des préférences générales.
public struct SeriesTrackChoice: Codable, Sendable, Equatable {
    /// Langue audio choisie (code normalisé, ex. « en »), si un choix a été fait.
    public var audioLanguage: String?
    /// Sous-titres : langue choisie, ou `nil` avec `subtitlesOff` pour « désactivés ».
    public var subtitleLanguage: String?
    public var subtitlesOff: Bool
    /// Choix de sous-titres fait (sinon, préférences générales pour les sous-titres).
    public var subtitleChosen: Bool
    public var updatedAt: Date

    public init(audioLanguage: String? = nil, subtitleLanguage: String? = nil, subtitlesOff: Bool = false,
                subtitleChosen: Bool = false, updatedAt: Date = Date()) {
        self.audioLanguage = audioLanguage; self.subtitleLanguage = subtitleLanguage
        self.subtitlesOff = subtitlesOff; self.subtitleChosen = subtitleChosen; self.updatedAt = updatedAt
    }

    /// Préférences à appliquer à un épisode de cette série.
    public func applied(to preferences: LanguagePreferences) -> LanguagePreferences {
        var p = preferences
        if let audio = audioLanguage {
            // L'ancienne langue préférée devient la langue de repli.
            if LanguageCode.normalize(p.preferredAudio) != audio { p.secondaryAudio = p.preferredAudio }
            p.preferredAudio = audio
        }
        if subtitleChosen {
            if subtitlesOff {
                p.subtitleMode = .off
            } else if let language = subtitleLanguage {
                p.preferredSubtitle = language
                p.subtitleMode = .always
            }
        }
        return p
    }
}

/// Mémoire des choix de pistes par série (identifiant de la fiche). Bornée : les choix
/// les plus anciens sont oubliés au-delà de `limit` séries.
public struct SeriesTrackMemory: Codable, Sendable, Equatable {
    public static let key = "series.tracks.v1"
    public static let limit = 300

    public private(set) var choices: [String: SeriesTrackChoice] = [:]

    public init() {}

    public func choice(for seriesID: String) -> SeriesTrackChoice? { choices[seriesID] }

    public mutating func rememberAudio(_ track: TrackDescriptor, seriesID: String, now: Date = Date()) {
        guard let language = track.normalizedLanguage else { return }
        var choice = choices[seriesID] ?? SeriesTrackChoice()
        choice.audioLanguage = language
        choice.updatedAt = now
        store(choice, for: seriesID)
    }

    /// `track == nil` : sous-titres désactivés. Une piste sans langue connue n'est pas retenue.
    public mutating func rememberSubtitle(_ track: TrackDescriptor?, seriesID: String, now: Date = Date()) {
        var choice = choices[seriesID] ?? SeriesTrackChoice()
        if let track {
            guard let language = track.normalizedLanguage else { return }
            choice.subtitleLanguage = language
            choice.subtitlesOff = false
        } else {
            choice.subtitleLanguage = nil
            choice.subtitlesOff = true
        }
        choice.subtitleChosen = true
        choice.updatedAt = now
        store(choice, for: seriesID)
    }

    public mutating func forget(_ seriesID: String) { choices[seriesID] = nil }

    private mutating func store(_ choice: SeriesTrackChoice, for seriesID: String) {
        choices[seriesID] = choice
        if choices.count > Self.limit {
            let oldest = choices.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(choices.count - Self.limit)
            for (id, _) in oldest { choices[id] = nil }
        }
    }
}
