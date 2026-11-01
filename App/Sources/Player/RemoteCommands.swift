import Foundation
import MediaPlayer

/// Commandes de lecture « système » : touches Avance rapide / Retour rapide,
/// Précédent / Suivant d'une télécommande de téléviseur (HDMI-CEC) ou infrarouge
/// apprise, télécommande de l'iPhone (Centre de contrôle), etc. Elles arrivent
/// par `MPRemoteCommandCenter`, pas par les appuis UIKit.
///
/// Les gestionnaires n'ont pas d'isolation d'acteur : ils extraient la donnée
/// utile de l'événement puis repassent sur le thread principal.
@MainActor
final class RemoteCommands {
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var lastPublished = Date.distantPast

    init(session: PlayerSession, skipInterval: TimeInterval) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]

        add(center.playCommand) { [weak session] _ in Self.onMain(session) { $0.play() } }
        add(center.pauseCommand) { [weak session] _ in Self.onMain(session) { $0.pause() } }
        add(center.togglePlayPauseCommand) { [weak session] _ in Self.onMain(session) { $0.togglePlayPause() } }
        add(center.skipForwardCommand) { [weak session] _ in Self.onMain(session) { $0.seek(by: skipInterval) } }
        add(center.skipBackwardCommand) { [weak session] _ in Self.onMain(session) { $0.seek(by: -skipInterval) } }
        // Suivant / Précédent : beaucoup de télécommandes de TV envoient ceci pour ⏩ / ⏪.
        add(center.nextTrackCommand) { [weak session] _ in Self.onMain(session) { $0.seek(by: skipInterval) } }
        add(center.previousTrackCommand) { [weak session] _ in Self.onMain(session) { $0.seek(by: -skipInterval) } }
        // Avance / retour rapide maintenus : défilement accéléré, validé au relâchement.
        add(center.seekForwardCommand) { [weak session] event in
            let begin = (event as? MPSeekCommandEvent)?.type != .endSeeking
            Self.onMain(session) { begin ? $0.startShuttle(forward: true) : $0.stopShuttle(commit: true) }
        }
        add(center.seekBackwardCommand) { [weak session] event in
            let begin = (event as? MPSeekCommandEvent)?.type != .endSeeking
            Self.onMain(session) { begin ? $0.startShuttle(forward: false) : $0.stopShuttle(commit: true) }
        }
        add(center.changePlaybackPositionCommand) { [weak session] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return }
            Self.onMain(session) { $0.seek(to: position) }
        }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @Sendable (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let token = command.addTarget(handler: Self.handler(action))
        registrations.append((command, token))
    }

    nonisolated private static func onMain(_ session: PlayerSession?, _ body: @escaping @MainActor @Sendable (PlayerSession) -> Void) {
        guard let session else { return }
        Task { @MainActor in body(session) }
    }

    nonisolated private static func handler(
        _ action: @escaping @Sendable (MPRemoteCommandEvent) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            action(event)
            return .success
        }
    }

    /// Informations « À l'écran » (nécessaires pour que tvOS route les commandes vers l'app).
    func publish(title: String, position: TimeInterval, duration: TimeInterval, playing: Bool, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) >= 5 else { return }
        lastPublished = now
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func invalidate() {
        for (command, token) in registrations { command.removeTarget(token) }
        registrations = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
