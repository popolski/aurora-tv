import UIKit
import CoreGraphics
import LanterneCore

/// État instantané d'un moteur, lu périodiquement par la session (≈ 4 Hz).
/// La session ne déduit jamais l'état d'après ses propres commandes : la
/// source de vérité est ce que le moteur rapporte.
nonisolated struct EngineSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, loading, playing, paused, buffering, seeking, ended
        case failed(String)
    }

    var phase: Phase = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var buffered: TimeInterval = 0
    /// Le moteur a reçu et analysé des données (durée/pistes connues).
    var dataReceived = false
    /// La couche d'affichage signale une première image prête à être présentée.
    var firstFrameReady = false
    var audioTracks: [TrackDescriptor] = []
    var subtitleTracks: [TrackDescriptor] = []
    var selectedAudioID: Int?
    var selectedSubtitleID: Int?
    /// Caractéristiques détectées par le moteur (affichées comme « détectées »).
    var detected = DetectedMedia()
    /// Lignes techniques pour le panneau d'informations.
    var diagnostics: [DiagnosticLine] = []

    var isPlaying: Bool { phase == .playing }
}

nonisolated struct DetectedMedia: Equatable, Sendable {
    var width: Int?
    var height: Int?
    var videoCodec: String?
    var dynamicRange: String?
    var frameRate: Double?
    var container: String?
    var audioCodec: String?

    var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

nonisolated struct DiagnosticLine: Equatable, Sendable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

/// Sous-titre prêt à afficher (déjà filtré sur l'instant courant).
nonisolated struct DisplayCue: Identifiable, @unchecked Sendable {
    enum Body {
        case text(String, italic: Bool, bold: Bool)
        /// Image (PGS, DVB…) et sa position dans le canevas source.
        case image(CGImage, rect: CGRect, canvas: CGSize)
    }

    let id: Int
    let body: Body
    /// Ancrée en haut de l'image (alignements ASS 7/8/9).
    let top: Bool
}

struct EngineLoadRequest {
    var url: URL
    var headers: [String: String]
    var startPosition: TimeInterval?
    var preferredAudioLanguages: [String]
    var matchContent: Bool
    var panelSupportsDolbyVision: Bool
    var externalSubtitles: [SubtitleItem]
}

/// Moteur de lecture. Toutes les méthodes sont appelées sur le fil principal.
@MainActor
protocol PlaybackEngine: AnyObject {
    var displayName: String { get }
    /// Vue de rendu à insérer plein écran.
    var renderView: UIView { get }
    /// `true` si le moteur dessine lui-même les sous-titres (pas de surcouche).
    var rendersSubtitlesItself: Bool { get }

    func load(_ request: EngineLoadRequest) async throws
    func snapshot() -> EngineSnapshot
    /// Sous-titres à afficher à l'instant courant, décalage utilisateur appliqué.
    func currentCues(delay: TimeInterval) -> [DisplayCue]

    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func selectAudio(_ id: Int)
    func selectSubtitle(_ id: Int?)
    /// Ajoute un sous-titre externe ; renvoie l'identifiant de piste ou `nil` si non pris en charge.
    func addExternalSubtitle(_ subtitle: SubtitleItem) -> Int?
    /// Arrêt complet et libération des ressources de la session.
    func stop()
}
