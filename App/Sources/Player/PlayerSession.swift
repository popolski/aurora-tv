import Foundation
import Observation
import UIKit
import LanterneCore

/// Coordonne une lecture : moteur, jalons de démarrage, pistes, progression,
/// épisode suivant, changement de source. Toujours sur le fil principal.
@MainActor
@Observable
final class PlayerSession {
    enum Status: Equatable {
        case starting(String)
        case active
        /// L'horloge avance mais aucune image n'est signalée prête : on ne
        /// prétend pas que la vidéo est lisible.
        case noPicture
        case failed(String)
        case ended
    }

    enum Panel: Equatable { case tracks, sources, info }

    private(set) var context: PlaybackContext
    private(set) var snapshot = EngineSnapshot()
    private(set) var cues: [DisplayCue] = []
    private(set) var milestones = PlaybackMilestoneTracker()
    private(set) var status: Status = .starting("Ouverture…")
    private(set) var engineName = ""
    private(set) var nextEpisode: MetaVideo?
    private(set) var nextCountdown: Int?
    private(set) var scrubTarget: TimeInterval?
    private(set) var subtitleDelay: TimeInterval
    /// Préférences d'affichage des sous-titres (la surcouche est hors de l'environnement SwiftUI).
    let languagePrefs: LanguagePreferences
    var chromeVisible = true
    var panel: Panel? {
        didSet { if panel != oldValue { onFocusContextChange?() } }
    }

    @ObservationIgnored var onFocusContextChange: (() -> Void)?
    @ObservationIgnored var onEngineViewChange: ((UIView) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    @ObservationIgnored private(set) var engine: any PlaybackEngine
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var auxTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var lastPosition: TimeInterval?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var playedSinceRecord: TimeInterval = 0
    @ObservationIgnored private var lastRecord = Date()
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var lastScrubActivity = Date()
    @ObservationIgnored private var scrubOrigin: TimeInterval = 0
    @ObservationIgnored private var tracksConfigured = false
    @ObservationIgnored private var userChoseSubtitle = false
    @ObservationIgnored private var externalAdded = false
    @ObservationIgnored private var streamRemembered = false
    @ObservationIgnored private var endHandled = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var loggedMilestone: PlaybackMilestone?
    @ObservationIgnored private let log = LogChannel("player")

    init(context: PlaybackContext, app: AppModel) {
        self.context = context
        self.app = app
        self.subtitleDelay = app.settings.languages.subtitleDelay
        self.languagePrefs = app.settings.languages
        self.engine = Self.makeEngine(choice: app.settings.playback.engine)
        self.engineName = engine.displayName
    }

    private static func makeEngine(choice: PlayerEngineChoice) -> any PlaybackEngine {
        if choice == .system { return SystemPlaybackEngine() }
        do {
            return try AetherPlaybackEngine.make()
        } catch {
            LogChannel("player").error("AetherEngine indisponible (\(error)) : repli sur AVPlayer")
            return SystemPlaybackEngine()
        }
    }

    // MARK: Interface de pilotage

    /// La surcouche doit recevoir le focus (panneau, erreur, fin).
    var needsInteractiveOverlay: Bool {
        if panel != nil { return true }
        switch status {
        case .failed, .ended, .noPicture: return true
        case .starting, .active: return false
        }
    }

    var title: String { context.meta.name }

    var subtitleLine: String? {
        if let test = context.localTest { return test.title }
        guard let video = context.video else { return nil }
        return [video.episodeCode, video.title.isEmpty ? nil : video.title].compactMap { $0 }.joined(separator: " · ")
    }

    var playableAlternatives: [RankedSource] {
        context.alternatives.filter { $0.playability.isPlayable && $0.id != context.source?.id }
    }

    var displayedPosition: TimeInterval { scrubTarget ?? snapshot.position }

    // MARK: Démarrage

    func start() {
        guard !closed else { return }
        loadTask?.cancel()
        auxTask?.cancel()
        milestones.reset()
        loggedMilestone = nil
        tracksConfigured = false
        userChoseSubtitle = false
        externalAdded = false
        streamRemembered = false
        endHandled = false
        nextCountdown = nil
        nextEpisode = nil
        lastPosition = nil
        playedSinceRecord = 0
        lastRecord = Date()
        openedAt = Date()
        status = .starting("Ouverture de la source…")
        chromeVisible = true
        panel = nil
        UIApplication.shared.isIdleTimerDisabled = true

        guard let request = makeRequest() else {
            fail("Cette source ne peut pas être lue.")
            return
        }
        milestones.mark(.sourceOpened, at: openedAt)
        log.info("ouverture [\(engine.displayName)] \(Redactor.redact(url: request.url)) départ=\(request.startPosition.map { TimeFormat.clock($0) } ?? "0") en-têtes=\(request.headers.count)")
        let engine = self.engine
        loadTask = Task { [weak self] in
            do {
                try await engine.load(request)
                self?.log.info("chargement accepté par le moteur")
                self?.afterLoad()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    private func makeRequest() -> EngineLoadRequest? {
        let prefs = app.settings
        let audioLangs = [prefs.languages.preferredAudio, prefs.languages.secondaryAudio].filter { !$0.isEmpty }
        if let test = context.localTest {
            guard let url = test.url else { return nil }
            var subs: [SubtitleItem] = []
            if let sub = test.subtitleURL {
                subs.append(SubtitleItem(id: "local", lang: "fre", url: sub, label: "Français (externe)", addonName: "Test"))
            }
            return EngineLoadRequest(url: url, headers: [:], startPosition: context.startPosition, preferredAudioLanguages: audioLangs,
                                     matchContent: prefs.playback.matchContent, panelSupportsDolbyVision: prefs.playback.panelSupportsDolbyVision,
                                     externalSubtitles: subs)
        }
        guard let playable = context.source?.playability.playable else { return nil }
        return EngineLoadRequest(url: playable.url, headers: playable.headers, startPosition: context.startPosition,
                                 preferredAudioLanguages: audioLangs, matchContent: prefs.playback.matchContent,
                                 panelSupportsDolbyVision: prefs.playback.panelSupportsDolbyVision,
                                 externalSubtitles: Array((context.source?.stream.subtitles ?? []).prefix(10)))
    }

    /// Après acceptation : sous-titres externes des addons (sans retarder le démarrage).
    private func afterLoad() {
        guard context.localTest == nil, !externalAdded else { return }
        let addons = app.addons
        let meta = context.meta
        let videoID = context.videoID
        let hints = context.source?.stream.behaviorHints
        let wanted = Set([app.settings.languages.preferredSubtitle, app.settings.languages.secondaryAudio, "en"].compactMap(LanguageCode.normalize))
        let aggregator = app.aggregator
        auxTask = Task { [weak self] in
            let subtitles = await aggregator.subtitles(type: meta.type, id: videoID, hints: hints, addons: addons)
            guard let self, !Task.isCancelled, !self.closed else { return }
            let selected = subtitles.filter { LanguageCode.normalize($0.lang).map(wanted.contains) ?? false }.prefix(12)
            var added = 0
            for sub in selected where self.engine.addExternalSubtitle(sub) != nil { added += 1 }
            self.externalAdded = true
            self.log.info("sous-titres externes : \(subtitles.count) proposés, \(added) ajoutés")
            if !self.userChoseSubtitle { self.tracksConfigured = false }
        }
    }

    // MARK: Boucle d'observation (4 Hz)

    private func tick() {
        guard !closed else { return }
        let now = Date()
        let s = engine.snapshot()
        snapshot = s

        if s.dataReceived { milestones.mark(.dataReceived, at: now) }
        if [.playing, .paused, .buffering, .seeking].contains(s.phase) || s.position > 0 {
            if s.dataReceived { milestones.mark(.decodingStarted, at: now) }
        }
        if s.firstFrameReady { milestones.mark(.firstFramePresented, at: now) }
        milestones.observe(position: s.position, isPlaying: s.phase == .playing, at: now)
        logMilestones()

        cues = engine.rendersSubtitlesItself ? [] : engine.currentCues(delay: subtitleDelay)

        if !tracksConfigured, s.phase == .playing || s.phase == .paused, !s.audioTracks.isEmpty || !s.subtitleTracks.isEmpty {
            configureTracks(s)
        }

        switch s.phase {
        case .failed(let message):
            if status != .failed(message) && !isFailed { fail(message) }
        case .ended:
            handleEnded()
        default:
            if case .starting = status, milestones.highest.map({ $0 >= .playing }) == true {
                status = .active
                rememberStream()
            } else if status == .noPicture, s.firstFrameReady {
                status = .active
            }
        }
        watchdog(now: now, s: s)
        accumulateProgress(now: now, s: s)
        autoHideChrome(now: now, s: s)
        if scrubTarget != nil, now.timeIntervalSince(lastScrubActivity) > 8 { cancelScrub() }
        lastTick = now
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func logMilestones() {
        guard let highest = milestones.highest, highest != loggedMilestone else { return }
        loggedMilestone = highest
        let latency = milestones.latency(of: highest).map { String(format: "%.2f s", $0) } ?? "?"
        log.info("jalon : \(highest.label) (+\(latency))")
        if highest == .firstFramePresented || highest == .stable {
            let d = snapshot.detected
            let announced = context.source.map { t in
                [t.traits.resolution?.label, t.traits.hdr.first?.label, t.traits.videoCodec?.label].compactMap { $0 }.joined(separator: " ")
            } ?? "—"
            log.info("détecté : \(d.resolutionLabel ?? "?") \(d.videoCodec ?? "?") \(d.dynamicRange ?? "?") ; annoncé : \(announced)")
        }
    }

    private func watchdog(now: Date, s: EngineSnapshot) {
        guard case .starting = status else { return }
        let elapsed = now.timeIntervalSince(openedAt)
        if !s.firstFrameReady, s.phase == .playing, s.position > 3, elapsed > 20 {
            // Le son et l'horloge avancent sans image : échec silencieux typique.
            log.error("aucune image après \(Int(elapsed)) s alors que l'horloge avance (position \(TimeFormat.clock(s.position)))")
            status = .noPicture
        } else if elapsed > 60, !s.dataReceived {
            fail("La source ne répond pas (aucune donnée après 60 s).")
        } else {
            switch s.phase {
            case .loading: status = .starting(s.dataReceived ? "Analyse du média…" : "Connexion à la source…")
            case .buffering: status = .starting("Mise en mémoire tampon…")
            default: break
            }
        }
    }

    private func accumulateProgress(now: Date, s: EngineSnapshot) {
        defer { lastPosition = s.position }
        guard context.localTest == nil else { return }
        if s.phase == .playing, let last = lastPosition {
            let delta = s.position - last
            let wall = now.timeIntervalSince(lastTick)
            // Uniquement le temps réellement regardé (pas les sauts).
            if delta > 0, delta < max(1.5, wall * 2.5) { playedSinceRecord += delta }
        }
        let paused = s.phase == .paused
        if now.timeIntervalSince(lastRecord) >= 15 || (paused && playedSinceRecord > 0) {
            recordProgress()
        }
    }

    private func autoHideChrome(now: Date, s: EngineSnapshot) {
        guard chromeVisible, panel == nil, scrubTarget == nil, status == .active, s.phase == .playing else { return }
        if now.timeIntervalSince(lastInteraction) > 5 { chromeVisible = false }
    }

    // MARK: Pistes

    private func configureTracks(_ s: EngineSnapshot) {
        tracksConfigured = true
        let selector = TrackSelector(preferences: app.settings.languages)
        let audio = s.audioTracks.first { $0.id == s.selectedAudioID } ?? selector.audio(s.audioTracks)
        if engine is SystemPlaybackEngine, let wanted = selector.audio(s.audioTracks), wanted.id != s.selectedAudioID {
            engine.selectAudio(wanted.id)
        }
        guard !userChoseSubtitle else { return }
        let subtitle = selector.subtitle(s.subtitleTracks, selectedAudio: audio)
        if subtitle?.id != s.selectedSubtitleID {
            engine.selectSubtitle(subtitle?.id)
        }
        log.info("pistes : audio=\(audio?.displayName ?? "aucune") sous-titres=\(subtitle?.displayName ?? "désactivés") (\(s.audioTracks.count) audio, \(s.subtitleTracks.count) sous-titres)")
    }

    func selectAudio(_ id: Int) {
        engine.selectAudio(id)
        touch()
    }

    func selectSubtitle(_ id: Int?) {
        userChoseSubtitle = true
        engine.selectSubtitle(id)
        touch()
    }

    func adjustSubtitleDelay(by delta: TimeInterval) {
        subtitleDelay = (subtitleDelay + delta).limited(to: -30...30)
        app.settings.languages.subtitleDelay = subtitleDelay
        touch()
    }

    // MARK: Transport

    func touch() {
        lastInteraction = Date()
        chromeVisible = true
    }

    func togglePlayPause() {
        touch()
        if snapshot.phase == .playing { engine.pause() } else { engine.play() }
    }

    func seek(by delta: TimeInterval) {
        touch()
        let target = max(0, min(snapshot.position + delta, snapshot.duration > 0 ? snapshot.duration - 1 : .greatestFiniteMagnitude))
        seek(to: target)
    }

    func seek(to target: TimeInterval) {
        lastPosition = nil
        let engine = self.engine
        Task { await engine.seek(to: target) }
    }

    func beginScrub() {
        guard snapshot.duration > 0 else { return }
        touch()
        if scrubTarget == nil { scrubTarget = snapshot.position }
        scrubOrigin = scrubTarget ?? snapshot.position
        lastScrubActivity = Date()
    }

    /// `fraction` : déplacement horizontal relatif (largeur de la surface tactile = 1).
    func updateScrub(fraction: Double) {
        guard scrubTarget != nil, snapshot.duration > 0 else { return }
        let start = scrubOrigin
        // Un balayage complet couvre 10 % de la durée (au moins 2 min, au plus 10 min).
        let span = min(max(snapshot.duration * 0.10, 120), 600)
        scrubTarget = (start + fraction * span).limited(to: 0...max(0, snapshot.duration - 1))
        lastScrubActivity = Date()
        touch()
    }

    func commitScrub() {
        guard let target = scrubTarget else { return }
        scrubTarget = nil
        seek(to: target)
    }

    func cancelScrub() { scrubTarget = nil }

    // MARK: Erreurs, fin, épisode suivant

    private func fail(_ message: String) {
        guard !closed else { return }
        status = .failed(message)
        chromeVisible = true
        log.error("échec de lecture : \(message) (jalon atteint : \(milestones.highest?.label ?? "aucun"))")
        onFocusContextChange?()
    }

    private func handleEnded() {
        guard !endHandled else { return }
        endHandled = true
        recordProgress()
        let next = context.localTest == nil ? NextEpisode.after(videoID: context.videoID, in: context.meta.videos) : nil
        nextEpisode = next
        if context.localTest == nil {
            let ref = LibraryMetaRef(context.meta)
            let s = snapshot
            let videoID = context.videoID
            Task { await app.library.finishPlayback(ref, videoID: videoID, position: s.position, duration: s.duration, nextVideoID: next?.id, ended: true) }
        }
        status = .ended
        log.info("fin de lecture\(next.map { " ; épisode suivant \($0.id)" } ?? "")")
        onFocusContextChange?()
        if next != nil, app.settings.playback.autoPlayNextEpisode { startCountdown() }
    }

    private func startCountdown() {
        nextCountdown = 10
        auxTask?.cancel()
        auxTask = Task { [weak self] in
            while let self, let n = self.nextCountdown, n > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.nextCountdown != nil else { return }
                self.nextCountdown = n - 1
            }
            guard let self, !Task.isCancelled, self.nextCountdown == 0 else { return }
            self.playNext()
        }
    }

    func cancelCountdown() {
        nextCountdown = nil
    }

    /// Recherche une source pour l'épisode suivant (même `bingeGroup` en priorité, comme Stremio).
    func playNext() {
        guard let next = nextEpisode else { return }
        nextCountdown = nil
        status = .starting("Recherche de sources pour \(next.episodeCode ?? next.title)…")
        onFocusContextChange?()
        let addons = app.addons
        let meta = context.meta
        let binge = context.source?.stream.behaviorHints.bingeGroup
        let server = app.settings.playback.streamingServer
        let prefs = app.settings
        let aggregator = app.aggregator
        auxTask?.cancel()
        auxTask = Task { [weak self] in
            var found: [RankedSource] = []
            let index = Dictionary(addons.enumerated().map { ($1.manifest.id, $0) }, uniquingKeysWith: { a, _ in a })
            for await outcome in aggregator.streams(type: meta.type, id: next.id, addons: addons) {
                for (i, stream) in (outcome.value ?? []).enumerated() {
                    found.append(SourceRanker.analyze(stream, addon: outcome.addon, addonIndex: index[outcome.addon.manifest.id] ?? 99,
                                                      indexInAddon: i, streamingServer: server))
                }
            }
            guard let self, !Task.isCancelled else { return }
            let ranker = SourceRanker(preferences: prefs.sources, preferredAudioLanguage: prefs.languages.preferredAudio)
            let ranked = ranker.rank(found)
            let sameGroup = binge.flatMap { group in
                ranked.first { $0.stream.behaviorHints.bingeGroup == group && $0.playability.isPlayable }
            }
            guard let choice = sameGroup ?? ranker.best(found) else {
                self.fail("Aucune source lisible trouvée pour l'épisode suivant.")
                return
            }
            self.log.info("épisode suivant : source \(sameGroup != nil ? "du même groupe" : "la mieux classée")")
            self.finishCurrent()
            var ctx = self.context
            ctx.videoID = next.id
            ctx.video = next
            ctx.source = choice
            ctx.startPosition = nil
            ctx.alternatives = ranked
            self.context = ctx
            self.start()
        }
    }

    /// Change de source en conservant la position.
    func switchSource(_ source: RankedSource) {
        finishCurrent()
        var ctx = context
        ctx.source = source
        ctx.startPosition = snapshot.position > 5 ? snapshot.position : context.startPosition
        context = ctx
        log.info("changement de source → \(source.addonName)")
        start()
    }

    /// Relance avec l'autre moteur (diagnostic : HLS/MP4 avec AVPlayer).
    func retryWithOtherEngine() {
        finishCurrent()
        engine.stop()
        engine = engine is SystemPlaybackEngine ? Self.makeEngine(choice: .automatic) : SystemPlaybackEngine()
        engineName = engine.displayName
        onEngineViewChange?(engine.renderView)
        var ctx = context
        ctx.startPosition = snapshot.position > 5 ? snapshot.position : context.startPosition
        context = ctx
        start()
    }

    func retry() {
        start()
    }

    /// L'utilisateur choisit de continuer malgré l'absence d'image signalée.
    func acknowledgeNoPicture() {
        guard status == .noPicture else { return }
        status = .active
        onFocusContextChange?()
    }

    // MARK: Progression

    private func rememberStream() {
        guard !streamRemembered, let source = context.source, context.localTest == nil else { return }
        streamRemembered = true
        let videoID = context.videoID
        Task { await app.library.rememberStream(videoID: videoID, fingerprint: source.stream.fingerprint) }
    }

    private func recordProgress() {
        lastRecord = Date()
        guard context.localTest == nil, milestones.isConfirmedPlayable || snapshot.position > 0 else { return }
        let s = snapshot
        guard s.position > 0 else { return }
        let played = playedSinceRecord
        playedSinceRecord = 0
        let ref = LibraryMetaRef(context.meta)
        let videoID = context.videoID
        let videos = context.meta.videos
        Task {
            await app.library.recordProgress(ref, videoID: videoID, position: s.position, duration: s.duration,
                                             played: played, videos: videos)
        }
    }

    /// Clôt la vidéo courante côté bibliothèque (sans arrêter le moteur).
    private func finishCurrent() {
        guard context.localTest == nil else { return }
        recordProgress()
        let s = snapshot
        guard !endHandled, s.duration > 0 else { return }
        let next = NextEpisode.after(videoID: context.videoID, in: context.meta.videos)
        let ref = LibraryMetaRef(context.meta)
        let videoID = context.videoID
        Task {
            await app.library.finishPlayback(ref, videoID: videoID, position: s.position, duration: s.duration,
                                             nextVideoID: next?.id, ended: false)
        }
    }

    // MARK: Fermeture

    /// Arrête tout et libère les ressources. Idempotent.
    func close() {
        guard !closed else { return }
        finishCurrent()
        closed = true
        loadTask?.cancel()
        auxTask?.cancel()
        ticker?.cancel()
        ticker = nil
        engine.stop()
        cues = []
        UIApplication.shared.isIdleTimerDisabled = false
        log.info("lecteur fermé (jalon max : \(milestones.highest?.label ?? "aucun"), blocages : \(milestones.stallCount))")
        onClose?()
    }
}

extension Comparable {
    func limited(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
