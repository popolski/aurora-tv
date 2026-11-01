import UIKit
import SwiftUI
import LanterneCore

/// Vue racine focalisable : reçoit les appuis de la télécommande quand
/// aucune surcouche interactive n'est ouverte.
final class PlayerRootView: UIView {
    override var canBecomeFocused: Bool { true }
}

/// Contrôleur du lecteur : vue de rendu du moteur, surcouche de sous-titres,
/// surcouche d'interface SwiftUI, gestion de la Siri Remote.
///
/// Commandes :
/// - clic central / Lecture-Pause : lecture ↔ pause (ou validation d'un déplacement) ;
/// - clic à gauche/droite du pavé : −/+ intervalle de saut ;
/// - balayage horizontal : déplacement dans la vidéo, validé par un clic ;
/// - bas : panneau Audio / Sous-titres / Sources / Infos ; haut : affiche l'interface ;
/// - Menu : annule le déplacement, masque l'interface, puis ferme le lecteur.
final class PlayerViewController: UIViewController {
    let session: PlayerSession
    private let root = PlayerRootView()
    private var engineView: UIView
    private let subtitleHost: UIHostingController<SubtitleLayer>
    private let overlayHost: UIHostingController<PlayerOverlay>
    private var pan: UIPanGestureRecognizer?
    private var started = false
    private let skipInterval: TimeInterval

    init(session: PlayerSession, skipInterval: TimeInterval) {
        self.session = session
        self.skipInterval = skipInterval
        self.engineView = session.engine.renderView
        self.subtitleHost = UIHostingController(rootView: SubtitleLayer(session: session))
        self.overlayHost = UIHostingController(rootView: PlayerOverlay(session: session))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    override func loadView() {
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        install(engineView)
        for host in [subtitleHost, overlayHost] as [UIViewController] {
            addChild(host)
            host.view.backgroundColor = .clear
            host.view.frame = root.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.addSubview(host.view)
            host.didMove(toParent: self)
        }
        subtitleHost.view.isUserInteractionEnabled = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        root.addGestureRecognizer(pan)
        self.pan = pan

        session.onFocusContextChange = { [weak self] in self?.updateFocusTarget() }
        session.onEngineViewChange = { [weak self] view in self?.replaceEngineView(view) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            session.start()
        }
        updateFocusTarget()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Filet de sécurité : toute disparition du lecteur libère le moteur.
        if isBeingDismissed || isMovingFromParent || presentingViewController == nil {
            session.close()
        }
    }

    private func install(_ view: UIView) {
        view.frame = root.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.insertSubview(view, at: 0)
    }

    private func replaceEngineView(_ view: UIView) {
        engineView.removeFromSuperview()
        engineView = view
        install(view)
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        session.needsInteractiveOverlay ? [overlayHost] : [root]
    }

    private func updateFocusTarget() {
        pan?.isEnabled = !session.needsInteractiveOverlay
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // MARK: Télécommande

    private func handles(_ type: UIPress.PressType) -> Bool {
        if session.needsInteractiveOverlay { return type == .menu }
        switch type {
        case .select, .playPause, .leftArrow, .rightArrow, .upArrow, .downArrow, .menu: return true
        default: return false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, handles(press.type) else {
            super.pressesBegan(presses, with: event)
            return
        }
        guard !session.needsInteractiveOverlay else { return }
        switch press.type {
        case .leftArrow:
            session.seek(by: -skipInterval)
        case .rightArrow:
            session.seek(by: skipInterval)
        default:
            break
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, handles(press.type) else {
            super.pressesEnded(presses, with: event)
            return
        }
        if session.needsInteractiveOverlay {
            // Menu dans une surcouche : ferme le panneau, ou le lecteur sur un écran d'erreur/fin.
            if session.panel != nil {
                session.panel = nil
                updateFocusTarget()
            } else {
                session.close()
            }
            return
        }
        switch press.type {
        case .select:
            if session.scrubTarget != nil { session.commitScrub() } else { session.togglePlayPause() }
        case .playPause:
            session.togglePlayPause()
        case .downArrow:
            session.touch()
            session.panel = .tracks
        case .upArrow:
            session.touch()
        case .menu:
            if session.scrubTarget != nil {
                session.cancelScrub()
            } else if session.chromeVisible && session.snapshot.phase == .playing {
                session.chromeVisible = false
            } else {
                session.close()
            }
        default:
            break
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let press = presses.first, handles(press.type) else {
            super.pressesCancelled(presses, with: event)
            return
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !session.needsInteractiveOverlay, root.bounds.width > 0 else { return }
        let translation = gesture.translation(in: root)
        switch gesture.state {
        case .began:
            session.beginScrub()
        case .changed:
            // Ignore les mouvements essentiellement verticaux.
            guard abs(translation.x) > abs(translation.y) else { return }
            session.updateScrub(fraction: Double(translation.x / root.bounds.width))
        default:
            break
        }
    }
}

/// Intégration SwiftUI du lecteur (présenté en plein écran depuis la racine).
struct PlayerScreen: UIViewControllerRepresentable {
    @Environment(AppModel.self) private var app
    let context: PlaybackContext

    func makeUIViewController(context ctx: Context) -> PlayerViewController {
        let session = PlayerSession(context: context, app: app)
        session.onClose = { [weak app] in app?.playbackDidEnd() }
        return PlayerViewController(session: session, skipInterval: app.settings.playback.skipInterval)
    }

    func updateUIViewController(_ controller: PlayerViewController, context ctx: Context) {}

    static func dismantleUIViewController(_ controller: PlayerViewController, coordinator: ()) {
        controller.session.close()
    }
}
