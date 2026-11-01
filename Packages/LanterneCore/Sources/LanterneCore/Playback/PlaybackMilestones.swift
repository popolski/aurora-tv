import Foundation

/// Les six jalons de démarrage d'une lecture, du plus faible au plus fort.
///
/// Une vidéo n'est considérée comme **lisible** qu'à partir de
/// `.firstFramePresented` suivi de `.playing` ; « décodage démarré » ne
/// prouve rien sur l'affichage.
public enum PlaybackMilestone: Int, Sendable, Comparable, CaseIterable, Codable {
    /// Le moteur a accepté la source et lancé l'ouverture.
    case sourceOpened = 1
    /// Des octets du média ont été reçus et analysés (durée/pistes connues).
    case dataReceived
    /// Le pipeline de décodage tourne (le moteur annonce un état de lecture).
    case decodingStarted
    /// La couche d'affichage signale une première image prête à être présentée
    /// (`isReadyForDisplay` / `hasFirstFrameReadyForDisplay`). C'est le signal
    /// le plus fort que la plateforme expose ; seule une vérification visuelle
    /// sur l'appareil prouve l'affichage effectif.
    case firstFramePresented
    /// L'horloge de lecture progresse alors que le moteur est en lecture.
    case playing
    /// La lecture progresse sans blocage depuis `stableDuration` secondes.
    case stable

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .sourceOpened: "Source ouverte"
        case .dataReceived: "Données reçues"
        case .decodingStarted: "Décodage démarré"
        case .firstFramePresented: "Première image prête à l'affichage"
        case .playing: "Lecture effective (horloge en progression)"
        case .stable: "Lecture stable"
        }
    }
}

/// Machine d'état des jalons, alimentée par des observations du moteur.
/// Pure (aucune dépendance au temps réel) : testable de façon déterministe.
public struct PlaybackMilestoneTracker: Sendable, Equatable {
    public static let stableDuration: TimeInterval = 10

    public private(set) var reached: [PlaybackMilestone: Date] = [:]
    public private(set) var highest: PlaybackMilestone?
    private var lastPosition: TimeInterval?
    private var progressStart: Date?
    private var hasFrame = false
    public private(set) var stallCount = 0

    public init() {}

    public mutating func reset() { self = PlaybackMilestoneTracker() }

    public mutating func mark(_ milestone: PlaybackMilestone, at date: Date) {
        if reached[milestone] == nil { reached[milestone] = date }
        // Les jalons inférieurs sont implicitement atteints.
        for m in PlaybackMilestone.allCases where m < milestone && reached[m] == nil {
            reached[m] = date
        }
        if highest.map({ milestone > $0 }) ?? true { highest = milestone }
        if milestone >= .firstFramePresented { hasFrame = true }
    }

    /// Observation périodique de l'horloge (≈ 2–4 Hz).
    /// - Parameters:
    ///   - position: position de lecture (s).
    ///   - isPlaying: le moteur est en lecture (ni pause, ni chargement, ni recherche).
    public mutating func observe(position: TimeInterval, isPlaying: Bool, at date: Date) {
        defer { lastPosition = position }
        guard isPlaying, let last = lastPosition else {
            if !isPlaying { progressStart = nil }
            return
        }
        let advanced = position > last + 0.01
        if advanced {
            if hasFrame { mark(.playing, at: date) }
            if progressStart == nil { progressStart = date }
            if let start = progressStart, hasFrame, date.timeIntervalSince(start) >= Self.stableDuration {
                mark(.stable, at: date)
            }
        } else {
            // En lecture mais horloge figée : blocage (mise en mémoire tampon).
            if progressStart != nil { stallCount += 1 }
            progressStart = nil
        }
    }

    /// Délai entre l'ouverture et un jalon (pour les journaux/diagnostics).
    public func latency(of milestone: PlaybackMilestone) -> TimeInterval? {
        guard let start = reached[.sourceOpened], let t = reached[milestone] else { return nil }
        return t.timeIntervalSince(start)
    }

    public var isConfirmedPlayable: Bool { (highest ?? .sourceOpened) >= .playing }
}
