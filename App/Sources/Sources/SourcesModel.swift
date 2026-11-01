import Foundation
import Observation
import LanterneCore

@MainActor
@Observable
final class SourcesModel {
    enum AddonState: Equatable {
        case loading
        case done(count: Int, duration: TimeInterval)
        case failed(String)
    }

    struct AddonStatus: Identifiable, Equatable {
        let id: String
        let name: String
        var state: AddonState
    }

    let request: SourcesRoute
    private(set) var raw: [RankedSource] = []
    private(set) var addonStatuses: [AddonStatus] = []
    private(set) var isFinished = false
    private(set) var previousFingerprint: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var autoPlayDone = false
    @ObservationIgnored private let log = LogChannel("sources")

    init(request: SourcesRoute) {
        self.request = request
    }

    func ranked(settings: AppSettings) -> [RankedSource] {
        SourceRanker(preferences: settings.sources, previouslyUsedFingerprint: previousFingerprint,
                     preferredAudioLanguage: settings.languages.preferredAudio).rank(raw)
    }

    func load(app: AppModel) {
        guard task == nil else { return }
        let addons = app.addons
        let server = app.settings.playback.streamingServer
        let request = self.request
        let aggregator = app.aggregator
        addonStatuses = addons
            .filter { $0.manifest.supports(resource: "stream", type: request.meta.type, id: request.videoID) }
            .map { AddonStatus(id: $0.manifest.id, name: $0.manifest.name, state: .loading) }
        // Flux embarqués dans la fiche (rare).
        if let embedded = request.video?.streams, !embedded.isEmpty {
            let pseudo = AddonDescriptor(transportURL: URL(string: "https://lanterne.invalid/manifest.json")!,
                                         manifest: AddonManifest(id: "meta", version: "1", name: "Fiche", types: [], resources: []))
            raw += embedded.enumerated().map {
                SourceRanker.analyze($0.element, addon: pseudo, addonIndex: -1, indexInAddon: $0.offset, streamingServer: server)
            }
        }
        log.info("recherche de sources \(request.videoID) auprès de \(addonStatuses.count) addon(s)")
        task = Task { [weak self] in
            let previous = await app.library.lastStreamFingerprint(videoID: request.videoID)
            self?.previousFingerprint = previous
            let addonIndex = Dictionary(addons.enumerated().map { ($1.manifest.id, $0) }, uniquingKeysWith: { a, _ in a })
            for await outcome in aggregator.streams(type: request.meta.type, id: request.videoID, addons: addons) {
                guard let self else { return }
                let id = outcome.addon.manifest.id
                switch outcome.result {
                case .success(let streams):
                    let index = addonIndex[id] ?? 999
                    self.raw += streams.enumerated().map {
                        SourceRanker.analyze($0.element, addon: outcome.addon, addonIndex: index, indexInAddon: $0.offset,
                                             streamingServer: server)
                    }
                    self.update(id, .done(count: streams.count, duration: outcome.duration))
                case .failure(let error):
                    self.update(id, .failed(error.errorDescription ?? "erreur"))
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isFinished = true
            let summary = self.addonStatuses.map { "\($0.name)=\($0.state)" }.joined(separator: ", ")
            self.log.info("sources : \(self.raw.count) trouvées (\(summary))")
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func update(_ id: String, _ state: AddonState) {
        if let i = addonStatuses.firstIndex(where: { $0.id == id }) { addonStatuses[i].state = state }
    }

    /// Lecture automatique de la meilleure source, une seule fois, une fois toutes les réponses reçues.
    func autoPlayCandidate(settings: AppSettings) -> RankedSource? {
        guard request.autoPlay, isFinished, !autoPlayDone else { return nil }
        autoPlayDone = true
        return SourceRanker(preferences: settings.sources, previouslyUsedFingerprint: previousFingerprint,
                            preferredAudioLanguage: settings.languages.preferredAudio).best(raw)
    }

    func playbackContext(for source: RankedSource, settings: AppSettings) -> PlaybackContext {
        PlaybackContext(meta: request.meta, videoID: request.videoID, video: request.video, source: source,
                        startPosition: request.startPosition, alternatives: ranked(settings: settings))
    }
}
