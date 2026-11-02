import UIKit
import Combine
import AetherEngine
import LanterneCore

/// Adaptateur AetherEngine (FFmpeg pour le démultiplexage, VideoToolbox pour
/// le décodage, présentation par AVFoundation) : MKV, HEVC/HDR/Dolby Vision,
/// DTS/TrueHD, sous-titres texte et image.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    let displayName = "AetherEngine"
    let rendersSubtitlesItself = false
    private let engine: AetherEngine
    private let surface = AetherPlayerView()
    private var cues: [SubtitleCue] = []
    private var cancellables: Set<AnyCancellable> = []
    private var externalIDs: [String: Int] = [:]

    var renderView: UIView { surface }

    /// Instance unique pour toute la durée de vie de l'application (recommandation
    /// du moteur : session audio et critères d'affichage gérés de bout en bout).
    private static var sharedEngine: AetherEngine?

    static func make() throws -> AetherPlaybackEngine {
        let engine: AetherEngine
        if let existing = sharedEngine {
            engine = existing
        } else {
            engine = try AetherEngine()
            // Lanterne ne joue aucun autre son : la session audio est libérée à l'arrêt
            // (évite qu'un récepteur HDMI boucle la dernière trame Atmos).
            engine.deactivatesAudioSessionOnStop = true
            sharedEngine = engine
        }
        return AetherPlaybackEngine(engine: engine)
    }

    private init(engine: AetherEngine) {
        self.engine = engine
        engine.bind(view: surface)
        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                MainActor.assumeIsolated { self?.cues = cues }
            }
            .store(in: &cancellables)
    }

    func load(_ request: EngineLoadRequest) async throws {
        var options = LoadOptions()
        options.httpHeaders = request.headers
        options.matchContentEnabled = request.matchContent
        options.panelPresentsDolbyVision = request.panelSupportsDolbyVision
        // Choix de la piste audio dès la première image (évite un rechargement).
        options.preferredAudioLanguages = request.preferredAudioLanguages
        options.externalSubtitles = request.externalSubtitles.map {
            ExternalSubtitleTrack(url: $0.url, name: $0.label ?? $0.addonName, language: LanguageCode.normalize($0.lang) ?? $0.lang)
        }
        for (i, sub) in request.externalSubtitles.enumerated() {
            externalIDs[sub.url.absoluteString] = AetherEngine.externalSubtitleTrackIDBase + i
        }
        try await engine.load(url: request.url, startPosition: request.startPosition, options: options)
    }

    func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        switch engine.playbackPhase {
        case .idle: s.phase = .idle
        case .loading: s.phase = .loading
        case .playing: s.phase = .playing
        case .paused: s.phase = .paused
        case .seeking: s.phase = .seeking
        case .rebuffering, .stalled: s.phase = .buffering
        case .ended: s.phase = .ended
        case .error(let message): s.phase = .failed(message)
        }
        s.position = engine.clock.currentTime
        s.duration = engine.duration.isFinite ? engine.duration : 0
        s.buffered = engine.clock.bufferedPosition
        s.firstFrameReady = engine.hasFirstFrameReadyForDisplay
        s.dataReceived = engine.duration > 0 || !engine.audioTracks.isEmpty || engine.sourceContainerFormat != nil
        s.audioTracks = engine.audioTracks.map { Self.descriptor($0, kind: .audio) }
        s.subtitleTracks = engine.subtitleTracks.map { Self.descriptor($0, kind: .subtitle) }
        s.selectedAudioID = engine.activeAudioTrackIndex
        s.selectedSubtitleID = engine.isSubtitleActive ? engine.activeSubtitleTrackIndex : nil

        var detected = DetectedMedia()
        if engine.sourceVideoWidth > 0 { detected.width = Int(engine.sourceVideoWidth) }
        if engine.sourceVideoHeight > 0 { detected.height = Int(engine.sourceVideoHeight) }
        detected.videoCodec = engine.sourceVideoCodecName
        detected.dynamicRange = Self.label(engine.videoFormat)
        detected.frameRate = engine.sourceVideoFrameRate
        detected.container = engine.sourceContainerFormat
        detected.audioCodec = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }?.codec
        s.detected = detected

        var lines: [DiagnosticLine] = [
            .init(label: "Moteur", value: displayName),
            .init(label: "Chemin vidéo", value: Self.label(engine.videoRoute)),
            .init(label: "Audio", value: engine.audioDelivery.rawValue),
            .init(label: "Plage dynamique affichée", value: Self.label(engine.videoFormat)),
            .init(label: "Plage dynamique source", value: Self.label(engine.sourceVideoFormat)),
        ]
        if let decoder = engine.activeVideoDecoder { lines.append(.init(label: "Décodeur vidéo", value: decoder)) }
        if let decoder = engine.activeAudioDecoder { lines.append(.init(label: "Décodeur audio", value: decoder)) }
        if let profile = engine.sourceDVProfile { lines.append(.init(label: "Profil Dolby Vision", value: "\(profile)")) }
        if engine.sourceVideoBitrate > 0 {
            lines.append(.init(label: "Débit vidéo", value: String(format: "%.1f Mb/s", Double(engine.sourceVideoBitrate) / 1_000_000)))
        }
        if let progress = engine.startupProgress, progress.completed < progress.total {
            lines.append(.init(label: "Démarrage", value: "\(progress.completed)/\(progress.total) · \(String(describing: progress.stage))"))
        }
        if let info = engine.errorInfo { lines.append(.init(label: "Erreur", value: "\(info)")) }
        s.diagnostics = lines
        return s
    }

    func currentCues(delay: TimeInterval) -> [DisplayCue] {
        // Les repères sont exprimés en temps source (PTS) : on les compare à
        // l'horloge source de l'image affichée.
        let t = engine.clock.sourceTime - delay
        return cues.filter { $0.startTime <= t && t < $0.endTime }.map(Self.display)
    }

    func subtitleSyncLines() -> (now: TimeInterval, lines: [SubtitleSyncLine])? {
        let now = engine.clock.sourceTime
        guard now.isFinite else { return nil }
        // Fichiers externes : liste complète ; pistes intégrées : fenêtre glissante du moteur.
        let lines = cues.compactMap { cue -> SubtitleSyncLine? in
            guard abs(cue.startTime - now) <= 45, let text = Self.plainText(cue) else { return nil }
            return SubtitleSyncLine(id: cue.id, start: cue.startTime, text: text)
        }
        return (now, SubtitleSync.candidates(lines, now: now))
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func seek(to seconds: TimeInterval) async { await engine.seek(to: seconds) }
    func selectAudio(_ id: Int) { engine.selectAudioTrack(index: id) }

    func selectSubtitle(_ id: Int?) {
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
    }

    func addExternalSubtitle(_ subtitle: SubtitleItem) -> Int? {
        if let known = externalIDs[subtitle.url.absoluteString] { return known }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: subtitle.url, name: subtitle.label ?? subtitle.addonName,
            language: LanguageCode.normalize(subtitle.lang) ?? subtitle.lang))
        externalIDs[subtitle.url.absoluteString] = track.id
        return track.id
    }

    func stop() {
        engine.stop()
        cues = []
        externalIDs = [:]
    }

    // MARK: Conversions

    private static func descriptor(_ t: TrackInfo, kind: TrackDescriptor.Kind) -> TrackDescriptor {
        TrackDescriptor(id: t.id, kind: kind, language: t.language, title: t.name.isEmpty ? nil : t.name,
                        codec: t.codec.isEmpty ? nil : t.codec, channels: kind == .audio && t.channels > 0 ? t.channels : nil,
                        isDefault: t.isDefault, isForced: t.isForced, isExternal: t.isExternal,
                        isHearingImpaired: t.isHearingImpaired)
    }

    private static func plainText(_ cue: SubtitleCue) -> String? {
        switch cue.body {
        case .text(let text): return text
        case .richText(let runs): return runs.map(\.text).joined()
        case .image: return nil
        }
    }

    private static func display(_ cue: SubtitleCue) -> DisplayCue {
        let alignment = cue.placement?.alignment ?? 2
        let top = (7...9).contains(alignment)
        switch cue.body {
        case .text(let text):
            return DisplayCue(id: cue.id, body: .text(text, italic: false, bold: false), top: top)
        case .richText(let runs):
            let text = runs.map(\.text).joined()
            let italic = !runs.isEmpty && runs.allSatisfy(\.isItalic)
            let bold = !runs.isEmpty && runs.allSatisfy(\.isBold)
            return DisplayCue(id: cue.id, body: .text(text, italic: italic, bold: bold), top: top)
        case .image(let image):
            return DisplayCue(id: cue.id, body: .image(image.cgImage, rect: image.position, canvas: image.canvasSize), top: false)
        }
    }

    private static func label(_ format: VideoFormat) -> String {
        switch format {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .dolbyVision: "Dolby Vision"
        case .hlg: "HLG"
        }
    }

    private static func label(_ route: VideoRoute) -> String {
        switch route {
        case .none: "—"
        case .remoteBypass: "AVPlayer direct (natif)"
        case .loopback: "Remux local → AVPlayer"
        case .software: "Décodage logiciel"
        case .audio: "Audio seul"
        }
    }
}
