import UIKit
import SwiftUI
import LanterneCore

/// Vue transparente focalisable qui capte la télécommande quand aucune
/// surcouche interactive n'est ouverte. Elle est **sœur** des surcouches (et
/// non leur parente) : sur tvOS, une vue focalisable empêche ses sous-vues de
/// recevoir le focus, ce qui bloquerait le panneau Audio/Sous-titres.
final class RemoteCatcherView: UIView {
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
    private let root = UIView()
    private let catcher = RemoteCatcherView()
    private var engineView: UIView
    private let subtitleHost: UIHostingController<SubtitleLayer>
    private let overlayHost: UIHostingController<PlayerOverlay>
    private var pan: UIPanGestureRecognizer?
    private var swipes: [UISwipeGestureRecognizer] = []
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
        catcher.frame = root.bounds
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.backgroundColor = .clear
        root.addSubview(catcher)
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
        pan.delegate = self
        root.addGestureRecognizer(pan)
        self.pan = pan
        // Balayages verticaux (convention du lecteur Apple) : bas = panneau, haut = interface.
        for direction in [UISwipeGestureRecognizer.Direction.down, .up] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = self
            root.addGestureRecognizer(swipe)
            swipes.append(swipe)
        }

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
        session.needsInteractiveOverlay ? [overlayHost] : [catcher]
    }

    private func updateFocusTarget() {
        pan?.isEnabled = !session.needsInteractiveOverlay
        for swipe in swipes { swipe.isEnabled = !session.needsInteractiveOverlay }
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
            // Menu dans une surcouche : ferme le panneau/l'encart (retour au film),
            // ou le lecteur sur un écran d'erreur/fin.
            session.handleOverlayExit()
            updateFocusTarget()
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

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard !session.needsInteractiveOverlay, session.scrubTarget == nil else { return }
        if gesture.direction == .down {
            session.touch()
            session.panel = .tracks
        } else {
            session.touch()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !session.needsInteractiveOverlay, root.bounds.width > 0 else { return }
        let translation = gesture.translation(in: root)
        switch gesture.state {
        case .began:
            // Le déplacement ne démarre qu'au premier mouvement horizontal franc.
            break
        case .changed:
            // Ignore les mouvements essentiellement verticaux (réservés aux balayages haut/bas).
            guard abs(translation.x) > abs(translation.y) * 1.5 else { return }
            if session.scrubTarget == nil { session.beginScrub() }
            session.updateScrub(fraction: Double(translation.x / root.bounds.width))
        default:
            break
        }
    }
}

extension PlayerViewController: UIGestureRecognizerDelegate {
    /// Le balayage horizontal (déplacement) et les balayages verticaux coexistent.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Présentation UIKit du lecteur, plein écran, par-dessus l'interface SwiftUI.
///
/// Un `fullScreenCover` SwiftUI garde la main sur le focus : les préférences de
/// focus du contrôleur UIKit étaient ignorées et la télécommande n'atteignait pas
/// le lecteur. Un contrôleur présenté par UIKit dispose de son propre contexte de
/// focus ; à sa fermeture, tvOS rend le focus à l'élément SwiftUI d'origine.
@MainActor
enum PlayerPresenter {
    private static weak var current: PlayerViewController?

    static func present(_ context: PlaybackContext, app: AppModel) {
        guard current == nil, let presenter = topViewController() else {
            LogChannel("player").warning("présentation du lecteur impossible (déjà ouvert ou fenêtre absente)")
            return
        }
        let session = PlayerSession(context: context, app: app)
        let controller = PlayerViewController(session: session, skipInterval: app.settings.playback.skipInterval)
        controller.modalPresentationStyle = .fullScreen
        session.onClose = { [weak controller, weak app] in
            if let controller, controller.presentingViewController != nil {
                controller.dismiss(animated: true)
            }
            app?.playbackDidEnd()
        }
        current = controller
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
