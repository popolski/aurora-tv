import Foundation

/// Description neutre d'une piste, indépendante du moteur de lecture.
public struct TrackDescriptor: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case audio, subtitle }

    public var id: Int
    public var kind: Kind
    public var language: String?
    public var title: String?
    public var codec: String?
    public var channels: Int?
    public var isDefault: Bool
    public var isForced: Bool
    public var isExternal: Bool
    /// Sous-titres pour sourds et malentendants (SDH), si signalé.
    public var isHearingImpaired: Bool

    public init(id: Int, kind: Kind, language: String? = nil, title: String? = nil, codec: String? = nil,
                channels: Int? = nil, isDefault: Bool = false, isForced: Bool = false, isExternal: Bool = false,
                isHearingImpaired: Bool = false) {
        self.id = id; self.kind = kind; self.language = language; self.title = title; self.codec = codec
        self.channels = channels; self.isDefault = isDefault; self.isForced = isForced; self.isExternal = isExternal
        self.isHearingImpaired = isHearingImpaired
    }

    public var normalizedLanguage: String? { LanguageCode.normalize(language) }

    /// Libellé affichable : « Français · E-AC-3 5.1 · Forcés ».
    public var displayName: String {
        var parts: [String] = []
        if let lang = normalizedLanguage { parts.append(LanguageCode.displayName(lang)) }
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
           parts.first.map({ !t.localizedCaseInsensitiveContains($0) }) ?? true {
            parts.append(t)
        }
        if kind == .audio {
            var tech: [String] = []
            if let codec { tech.append(codec.uppercased()) }
            if let ch = channels { tech.append(Self.channelLabel(ch)) }
            if !tech.isEmpty { parts.append(tech.joined(separator: " ")) }
        }
        if isForced { parts.append("Forcés") }
        if isHearingImpaired { parts.append("SDH") }
        if isExternal { parts.append("Externe") }
        return parts.isEmpty ? "Piste \(id)" : parts.joined(separator: " · ")
    }

    static func channelLabel(_ ch: Int) -> String {
        switch ch {
        case 1: "Mono"
        case 2: "Stéréo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(ch) canaux"
        }
    }
}

/// Choix initial des pistes selon les préférences de langue.
public struct TrackSelector: Sendable {
    public var preferences: LanguagePreferences

    public init(preferences: LanguagePreferences) { self.preferences = preferences }

    /// Piste audio : langue préférée, sinon secondaire, sinon piste par défaut.
    public func audio(_ tracks: [TrackDescriptor]) -> TrackDescriptor? {
        let audio = tracks.filter { $0.kind == .audio }
        guard !audio.isEmpty else { return nil }
        for lang in [preferences.preferredAudio, preferences.secondaryAudio] {
            let matches = audio.filter { $0.normalizedLanguage == LanguageCode.normalize(lang) }
            // Parmi plusieurs pistes de la langue : par défaut d'abord, puis plus de canaux.
            if let best = matches.sorted(by: { a, b in
                if a.isDefault != b.isDefault { return a.isDefault }
                return (a.channels ?? 0) > (b.channels ?? 0)
            }).first {
                return best
            }
        }
        return audio.first(where: \.isDefault) ?? audio.first
    }

    /// Sous-titre à activer d'office (ou `nil` = aucun).
    ///
    /// - `always` : langue préférée si disponible (non forcés de préférence).
    /// - `foreignAudioOnly` : seulement si l'audio retenu n'est pas dans la
    ///   langue des sous-titres ; sinon, sous-titres « forcés » de cette langue
    ///   s'ils existent (dialogues étrangers ponctuels).
    public func subtitle(_ tracks: [TrackDescriptor], selectedAudio: TrackDescriptor?) -> TrackDescriptor? {
        let subs = tracks.filter { $0.kind == .subtitle }
        let want = LanguageCode.normalize(preferences.preferredSubtitle)
        let inLanguage = subs.filter { $0.normalizedLanguage == want }
        let full = inLanguage.filter { !$0.isForced }.sorted { a, b in
            if a.isHearingImpaired != b.isHearingImpaired { return !a.isHearingImpaired }
            if a.isExternal != b.isExternal { return !a.isExternal }  // intégrés d'abord (synchronisés avec la vidéo)
            return a.id < b.id
        }
        let forced = inLanguage.filter(\.isForced)
        let audioLang = selectedAudio?.normalizedLanguage
        switch preferences.subtitleMode {
        case .off:
            return nil
        case .always:
            return full.first ?? forced.first
        case .foreignAudioOnly:
            if let audioLang, audioLang == want {
                return forced.first
            }
            // Langue audio inconnue : on ne force rien, sauf sous-titres « forcés ».
            if audioLang == nil { return forced.first }
            return full.first ?? forced.first
        }
    }
}
