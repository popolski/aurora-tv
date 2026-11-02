import Foundation

// Commandes « du soir » du lecteur : minuteur de mise en veille, question
// « Êtes-vous toujours là ? » et synchronisation des sous-titres par réplique.
// La logique est ici (testée) ; le lecteur ne fait que l'appliquer.

/// Minuteur de mise en veille choisi dans le lecteur.
public enum SleepTimerChoice: Hashable, Sendable, Identifiable {
    /// À la fin de l'épisode ou du film en cours (début du générique s'il est connu).
    case endOfItem
    case minutes(Int)

    public static let durations = [15, 30, 45, 60, 90]

    public var id: String {
        switch self {
        case .endOfItem: "end"
        case .minutes(let m): "\(m)"
        }
    }

    public func label(isSeries: Bool) -> String {
        switch self {
        case .endOfItem: isSeries ? "Fin de l'épisode" : "Fin du film"
        case .minutes(let m): m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)")
        }
    }

    /// Échéance d'un minuteur à durée fixe.
    public func deadline(from start: Date) -> Date? {
        guard case .minutes(let m) = self else { return nil }
        return start.addingTimeInterval(TimeInterval(m) * 60)
    }

    /// Texte court affiché dans la barre du lecteur.
    public static func status(_ choice: SleepTimerChoice?, deadline: Date?, now: Date, isSeries: Bool) -> String? {
        switch choice {
        case nil: return nil
        case .endOfItem: return isSeries ? "Arrêt à la fin de l'épisode" : "Arrêt à la fin du film"
        case .minutes:
            guard let deadline else { return nil }
            let minutes = Int((deadline.timeIntervalSince(now) / 60).rounded(.up))
            return minutes <= 1 ? "Arrêt dans 1 min" : "Arrêt dans \(minutes) min"
        }
    }

    /// Le minuteur « fin de l'épisode » se déclenche au début du générique s'il
    /// est connu (TheIntroDB), sinon dans les dernières secondes du fichier.
    public static func endOfItemReached(position: TimeInterval, duration: TimeInterval,
                                        creditsStart: TimeInterval?, finalLead: TimeInterval = 20) -> Bool {
        guard duration > 120 else { return false }
        if let creditsStart, creditsStart > duration * 0.6, position >= creditsStart { return true }
        return duration - position <= finalLead
    }
}

/// Compte les épisodes enchaînés automatiquement sans action à la télécommande.
public struct StillWatchingCounter: Sendable, Equatable {
    /// Nombre d'épisodes enchaînés au-delà duquel on demande (0 = jamais).
    public var limit: Int
    public private(set) var chained = 0

    public init(limit: Int) { self.limit = max(0, limit) }

    /// Toute action de l'utilisateur remet le compteur à zéro.
    public mutating func userInteracted() { chained = 0 }

    /// Appelé quand l'épisode suivant va démarrer seul : `false` = il faut
    /// d'abord demander « Êtes-vous toujours là ? ».
    public mutating func allowAutoAdvance() -> Bool {
        if limit > 0, chained >= limit { return false }
        chained += 1
        return true
    }
}

/// Réplique de sous-titre proposée pour la synchronisation.
public struct SubtitleSyncLine: Identifiable, Hashable, Sendable {
    public let id: Int
    /// Début dans le fichier de sous-titres (horloge source, sans décalage).
    public let start: TimeInterval
    public let text: String

    public init(id: Int, start: TimeInterval, text: String) {
        self.id = id
        self.start = start
        self.text = text
    }
}

/// Synchronisation « choisir la réplique entendue » : la réplique choisie doit
/// s'afficher à l'instant où la lecture a été mise en pause.
public enum SubtitleSync {
    /// Plage de décalage acceptée par le lecteur (secondes).
    public static let delayRange: ClosedRange<TimeInterval> = -30...30

    /// Décalage qui affiche `line` à l'instant `now` (positif = sous-titres retardés).
    public static func delay(for line: SubtitleSyncLine, heardAt now: TimeInterval) -> TimeInterval {
        let raw = now - line.start
        return min(max(raw, delayRange.lowerBound), delayRange.upperBound)
    }

    /// Répliques candidates : celles qu'un décalage autorisé peut amener à
    /// `now`, triées, sans doublons (même début et même texte), texte nettoyé.
    public static func candidates(_ lines: [SubtitleSyncLine], now: TimeInterval) -> [SubtitleSyncLine] {
        var seen = Set<String>()
        var result: [SubtitleSyncLine] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let delta = now - line.start
            guard delayRange.contains(delta) else { continue }
            let text = line.text
                .replacingOccurrences(of: "\\N", with: " ")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { continue }
            let key = "\(Int((line.start * 100).rounded()))|\(text)"
            guard seen.insert(key).inserted else { continue }
            result.append(SubtitleSyncLine(id: line.id, start: line.start, text: text))
        }
        return result
    }

    /// Réplique affichée (ou la dernière affichée) à `now` avec le décalage
    /// actuel : point de départ du choix.
    public static func current(in lines: [SubtitleSyncLine], now: TimeInterval, delay: TimeInterval) -> SubtitleSyncLine? {
        lines.last { $0.start + delay <= now } ?? lines.first
    }
}
