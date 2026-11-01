import UIKit
import AVFoundation
import LanterneCore

/// Vue dont la couche est une `AVPlayerLayer`.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Moteur « système » : AVPlayer seul. Lit HLS, MP4/MOV (H.264, HEVC, AAC,
/// AC-3, E-AC-3). Ne lit pas MKV, DTS, TrueHD ni les sous-titres externes.
/// Sert de repli et de référence de diagnostic.
@MainActor
final class SystemPlaybackEngine: PlaybackEngine {
    let displayName = "AVPlayer (système)"
    /// Les sous-titres sélectionnés sont dessinés par AVPlayerLayer.
    let rendersSubtitlesItself = true
    private let player = AVPlayer()
    private let view = PlayerLayerView()
    private var item: AVPlayerItem?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    var renderView: UIView { view }

    init() {
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    func load(_ request: EngineLoadRequest) async throws {
        var options: [String: Any] = [:]
        if !request.headers.isEmpty {
            // Clé non documentée mais largement utilisée pour les en-têtes HTTP.
            options["AVURLAssetHTTPHeaderFieldsKey"] = request.headers
        }
        let asset = AVURLAsset(url: request.url, options: options)
        let item = AVPlayerItem(asset: asset)
        self.item = item
        player.replaceCurrentItem(with: item)

        // Attente de l'état « prêt » (ou échec) avec délai maximal.
        let deadline = Date().addingTimeInterval(45)
        while item.status == .unknown {
            try Task.checkCancellation()
            if Date() > deadline { throw EngineError.timeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if item.status == .failed {
            throw EngineError.failed(item.error?.localizedDescription ?? "lecture impossible")
        }
        audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        if let start = request.startPosition, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }
        // Langue audio préférée si l'asset propose plusieurs options.
        if let group = audibleGroup {
            for lang in request.preferredAudioLanguages {
                if let option = group.options.first(where: { LanguageCode.normalize($0.extendedLanguageTag ?? $0.locale?.identifier) == lang }) {
                    item.select(option, in: group)
                    break
                }
            }
        }
        if let legible = legibleGroup { item.select(nil, in: legible) }
        player.play()
    }

    func snapshot() -> EngineSnapshot {
        var s = EngineSnapshot()
        guard let item else { return s }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        s.position = position.isFinite ? position : 0
        s.duration = duration.isFinite ? duration : 0
        if let range = item.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeRangeGetEnd(range).seconds
            s.buffered = end.isFinite ? end : 0
        }
        s.dataReceived = item.status == .readyToPlay
        s.firstFrameReady = view.playerLayer.isReadyForDisplay
        switch item.status {
        case .failed:
            s.phase = .failed(item.error?.localizedDescription ?? "échec AVPlayer")
        case .unknown:
            s.phase = .loading
        default:
            switch player.timeControlStatus {
            case .playing: s.phase = .playing
            case .waitingToPlayAtSpecifiedRate: s.phase = .buffering
            case .paused:
                s.phase = (s.duration > 0 && s.position >= s.duration - 0.5) ? .ended : .paused
            @unknown default: s.phase = .paused
            }
        }
        if let group = audibleGroup {
            s.audioTracks = group.options.enumerated().map { i, o in
                TrackDescriptor(id: i, kind: .audio, language: o.extendedLanguageTag ?? o.locale?.identifier, title: o.displayName)
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                s.selectedAudioID = group.options.firstIndex(of: selected)
            }
        }
        if let group = legibleGroup {
            s.subtitleTracks = group.options.enumerated().map { i, o in
                TrackDescriptor(id: i, kind: .subtitle, language: o.extendedLanguageTag ?? o.locale?.identifier, title: o.displayName,
                                isForced: o.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
            }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
                s.selectedSubtitleID = group.options.firstIndex(of: selected)
            }
        }
        let presentation = item.presentationSize
        if presentation.width > 0 {
            s.detected.width = Int(presentation.width)
            s.detected.height = Int(presentation.height)
        }
        s.diagnostics = [
            .init(label: "Moteur", value: displayName),
            .init(label: "Statut", value: "\(item.status.rawValue) / \(player.timeControlStatus.rawValue)"),
        ]
        if let event = item.errorLog()?.events.last {
            s.diagnostics.append(.init(label: "Dernière erreur", value: "\(event.errorDomain) \(event.errorStatusCode)"))
        }
        return s
    }

    func currentCues(delay: TimeInterval) -> [DisplayCue] { [] }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: TimeInterval) async {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                          toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                          toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { _ in }
    }

    func selectAudio(_ id: Int) {
        guard let group = audibleGroup, group.options.indices.contains(id) else { return }
        item?.select(group.options[id], in: group)
    }

    func selectSubtitle(_ id: Int?) {
        guard let group = legibleGroup else { return }
        if let id, group.options.indices.contains(id) {
            item?.select(group.options[id], in: group)
        } else {
            item?.select(nil, in: group)
        }
    }

    func addExternalSubtitle(_ subtitle: SubtitleItem) -> Int? { nil }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        audibleGroup = nil
        legibleGroup = nil
    }
}

enum EngineError: LocalizedError {
    case timeout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "Délai dépassé à l'ouverture de la vidéo."
        case .failed(let message): message
        }
    }
}
