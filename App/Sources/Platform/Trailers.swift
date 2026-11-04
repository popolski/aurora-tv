import SwiftUI
import AVFoundation
import AVKit
import LanterneCore

/// Accès au service de bandes-annonces du NAS (voir `trailer-server/`).
@MainActor
enum TrailerService {
    private static var prefetched: Set<String> = []
    private static let log = LogChannel("trailers")

    /// Adresse de la bande-annonce d'une fiche, si le service est configuré.
    static func url(for meta: MetaItem?, settings: AppSettings) -> URL? {
        guard let meta, let server = settings.trailers.server else { return nil }
        return TrailerLink.itemVideoURL(server: server, meta: meta)
    }

    /// Extrait de 30 s (bandeau de l'accueil qui défile tout seul).
    static func previewURL(for meta: MetaItem?, settings: AppSettings) -> URL? {
        guard let meta, let server = settings.trailers.server else { return nil }
        return TrailerLink.itemPreviewURL(server: server, meta: meta)
    }

    /// Demande au service de préparer ces bandes-annonces (une fois par identifiant et par session).
    static func prefetch(_ metas: [MetaItem], settings: AppSettings) {
        guard let server = settings.trailers.server, settings.trailers.onHome || settings.trailers.onDetail else { return }
        let items = metas.compactMap(TrailerLink.prefetchItem(for:)).filter { !prefetched.contains($0.id) }
        guard !items.isEmpty else { return }
        let batch = Array(items.prefix(30))
        prefetched.formUnion(batch.map(\.id))
        var request = URLRequest(url: TrailerLink.prefetchURL(server: server), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["items": batch])
        let log = self.log
        let session = URLSession.shared
        let req = request
        Task.detached(priority: .utility) {
            do {
                _ = try await session.data(for: req)
            } catch {
                log.debug("préparation des bandes-annonces impossible : \(error.localizedDescription)")
            }
        }
    }

    /// Résultat lisible du test de connexion (Réglages).
    nonisolated static func check(server: URL) async -> String {
        struct Health: Decodable { var ok: Bool?; var audio: Bool?; var preview: Bool?; var topshelf: Bool?; var localized: Bool?; var ytdlp: String?; var ffmpeg: Bool?; var cached: Int?; var cacheMB: Double? }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: TrailerLink.healthURL(server: server), timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let health = try? JSONDecoder().decode(Health.self, from: data), health.ok == true else {
                return "Réponse inattendue : est-ce bien le service aurora-trailers ?"
            }
            guard let version = health.ytdlp else { return "Service joignable, mais yt-dlp est absent du NAS." }
            guard health.audio == true, health.preview == true, health.topshelf == true, health.localized != nil else {
                return "Connecté, mais le service du NAS est une ancienne version (bandes-annonces en français, son, extraits ou images du carrousel absents) : mettez à jour le dossier trailer-server et reconstruisez."
            }
            let language = health.localized == true ? "en français si possible (TMDB)" : "en VO (clé TMDB absente sur le NAS)"
            return "Connecté · yt-dlp \(version) · bandes-annonces \(language) · \(health.cached ?? 0) en cache (\(Int(health.cacheMB ?? 0)) Mo)"
        } catch {
            return "Service injoignable : \(error.localizedDescription)"
        }
    }
}

/// Bande-annonce en plein écran, avec le son, dans le lecteur système (Menu pour fermer).
@MainActor
enum TrailerPresenter {
    private static var session: TrailerSession?

    static func present(_ url: URL, title: String, app: AppModel) {
        // Filet de sécurité : une session dont le lecteur n'est plus affiché est terminée.
        if let current = session, !current.isOnScreen { current.finish() }
        guard session == nil, app.playback == nil, let top = topViewController() else { return }
        let item = AVPlayerItem(url: url)
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = "\(title) · Bande-annonce" as NSString
        titleItem.extendedLanguageTag = "und"
        item.externalMetadata = [titleItem]
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(playerItem: item)
        let newSession = TrailerSession(controller: controller) { [weak app] in
            app?.isTrailerPresented = false
            session = nil
        }
        controller.delegate = newSession
        session = newSession
        app.isTrailerPresented = true
        top.present(controller, animated: true) { controller.player?.play() }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Suit une bande-annonce plein écran : fermeture automatique à la fin, nettoyage à la fermeture.
@MainActor
final class TrailerSession: NSObject, AVPlayerViewControllerDelegate {
    private weak var controller: AVPlayerViewController?
    private var onFinish: (() -> Void)?

    init(controller: AVPlayerViewController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidEnd(_:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification,
                                               object: controller.player?.currentItem)
    }

    @objc nonisolated private func itemDidEnd(_ notification: Notification) {
        Task { @MainActor in self.close(dismiss: true) }
    }

    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in self.close(dismiss: false) }
    }

    var isOnScreen: Bool { controller?.presentingViewController != nil }

    func finish() { close(dismiss: false) }

    private func close(dismiss: Bool) {
        guard let onFinish else { return }
        self.onFinish = nil
        NotificationCenter.default.removeObserver(self)
        controller?.player?.pause()
        if dismiss, let controller, controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        }
        onFinish()
    }
}

/// Vue de rendu AVPlayerLayer.
final class TrailerPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Bande-annonce muette, en fond. Elle n'apparaît (en fondu) qu'une fois la
/// première image prête, et disparaît d'elle-même à la fin ou en cas d'échec :
/// l'image fixe reste toujours dessous.
struct TrailerBackdrop: View {
    let url: URL?
    /// Signale si la vidéo est visible (pour alléger le texte par-dessus).
    var onPlayingChange: (Bool) -> Void = { _ in }

    @State private var visible = false

    var body: some View {
        TrailerLayer(url: url, onPlayingChange: { playing in
            withAnimation(.easeInOut(duration: playing ? 1.0 : 0.6)) { visible = playing }
            onPlayingChange(playing)
        })
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TrailerLayer: UIViewRepresentable {
    let url: URL?
    let onPlayingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TrailerPlayerUIView, context: Context) {
        context.coordinator.onPlayingChange = onPlayingChange
        context.coordinator.load(url, in: view)
    }

    static func dismantleUIView(_ view: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.load(nil, in: view)
    }

    @MainActor
    final class Coordinator {
        var onPlayingChange: (Bool) -> Void = { _ in }
        private var url: URL?
        private var player: AVPlayer?
        private var monitor: Task<Void, Never>?
        private var playing = false

        func load(_ newURL: URL?, in view: TrailerPlayerUIView) {
            guard newURL != url else { return }
            url = newURL
            stop(view)
            guard let newURL else { return }
            let item = AVPlayerItem(url: newURL)
            item.preferredForwardBufferDuration = 10
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.allowsExternalPlayback = false
            self.player = player
            view.playerLayer.player = player
            // Surveillance simple (thread principal) : prête → lecture ; fin ou échec → disparition.
            monitor = Task { [weak self, weak view] in
                var started = false
                for _ in 0..<(4 * 120) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, let view, !Task.isCancelled, self.player === player else { return }
                    if item.status == .failed { break }
                    if !started, item.status == .readyToPlay {
                        player.play()
                        started = true
                    }
                    if started, !self.playing, view.playerLayer.isReadyForDisplay, player.currentTime().seconds > 0.2 {
                        self.setPlaying(true)
                    }
                    let duration = item.duration.seconds
                    if started, duration.isFinite, duration > 0, player.currentTime().seconds >= duration - 0.6 { break }
                }
                guard let self, !Task.isCancelled, self.player === player else { return }
                self.setPlaying(false)
                player.pause()
            }
        }

        private func setPlaying(_ value: Bool) {
            guard value != playing else { return }
            playing = value
            // Hors du cycle de mise à jour de la vue (appel possible depuis updateUIView).
            let callback = onPlayingChange
            Task { @MainActor in callback(value) }
        }

        private func stop(_ view: TrailerPlayerUIView) {
            monitor?.cancel()
            monitor = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            view.playerLayer.player = nil
            setPlaying(false)
        }
    }
}
