import Foundation

/// « Je ne sais pas quoi regarder » : tirage au sort dans Ma liste.
public enum SurpriseKind: String, Sendable, CaseIterable, Identifiable {
    case any, movies, series

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .any: "Films et séries"
        case .movies: "Films"
        case .series: "Séries"
        }
    }
}

/// Durée maximale souhaitée (film entier, ou épisode pour une série).
public enum SurpriseDuration: String, Sendable, CaseIterable, Identifiable {
    case any, short, medium

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .any: "Peu importe la durée"
        case .short: "Moins de 1 h 30"
        case .medium: "Moins de 2 h"
        }
    }

    public var maxSeconds: TimeInterval? {
        switch self {
        case .any: nil
        case .short: 90 * 60
        case .medium: 120 * 60
        }
    }

    /// Une durée inconnue n'est acceptée que sans limite (on ne promet pas « moins de 2 h »
    /// sans le savoir).
    public func accepts(runtime: TimeInterval?) -> Bool {
        guard let maxSeconds else { return true }
        guard let runtime, runtime > 0 else { return false }
        return runtime <= maxSeconds
    }
}

public enum SurprisePicker {
    /// Titres de Ma liste à proposer, dans un ordre aléatoire : films non vus, séries,
    /// sans ceux déjà proposés (tant qu'il en reste d'autres).
    public static func candidates<G: RandomNumberGenerator>(
        from library: [LibraryItem], kind: SurpriseKind, alreadyShown: Set<String>, using generator: inout G
    ) -> [LibraryItem] {
        let eligible = library.filter { item in
            guard item.isInLibrary, DeepLink.isValidID(item.id) else { return false }
            switch kind {
            case .any: guard item.type == ContentType.movie || item.type == ContentType.series else { return false }
            case .movies: guard item.type == ContentType.movie else { return false }
            case .series: guard item.type == ContentType.series else { return false }
            }
            // Un film déjà vu n'est pas une découverte ; une série peut se poursuivre.
            return !(item.type == ContentType.movie && item.isWatched)
        }
        let fresh = eligible.filter { !alreadyShown.contains($0.id) }
        return (fresh.isEmpty ? eligible : fresh).shuffled(using: &generator)
    }

    public static func candidates(from library: [LibraryItem], kind: SurpriseKind, alreadyShown: Set<String>) -> [LibraryItem] {
        var generator = SystemRandomNumberGenerator()
        return candidates(from: library, kind: kind, alreadyShown: alreadyShown, using: &generator)
    }
}
