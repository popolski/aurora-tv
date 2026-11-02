import Foundation
import Observation
import LanterneCore

@MainActor
@Observable
final class DetailModel {
    enum LoadState: Equatable { case loading, loaded, failed(String) }

    private(set) var meta: MetaItem
    private(set) var state: LoadState = .loading
    private(set) var libraryItem: LibraryItem?
    private(set) var watched: Set<String> = []
    var selectedSeason: Int?
    /// Position de reprise (s) pour la vidéo cible, si significative.
    private(set) var resumePosition: TimeInterval?
    /// Notes de la critique (Wikidata), si connues.
    private(set) var reviews: ReviewScores?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(preview: MetaItem) {
        self.meta = preview
    }

    var isSeries: Bool { meta.type == ContentType.series || meta.isSeries }
    var isInLibrary: Bool { libraryItem?.isInLibrary ?? false }

    /// Vidéo visée par le bouton principal (reprise, épisode suivant, ou premier épisode).
    var targetVideo: MetaVideo? {
        guard isSeries else { return nil }
        return NextEpisode.resumeTarget(item: libraryItem, videos: meta.videos, watched: watched)
    }

    /// Identifiant de la vidéo à lire : épisode cible, `defaultVideoId`, ou l'id du film.
    var targetVideoID: String? {
        if isSeries { return targetVideo?.id }
        if let only = meta.videos.first, meta.videos.count == 1, meta.type != ContentType.movie { return only.id }
        return meta.defaultVideoID ?? meta.id
    }

    var episodesInSelectedSeason: [MetaVideo] {
        guard let season = selectedSeason ?? meta.seasons.first else { return [] }
        return meta.episodes(inSeason: season)
    }

    func load(app: AppModel) {
        loadTask?.cancel()
        state = .loading
        let preview = meta
        loadTask = Task { [weak self] in
            do {
                let detail = try await app.aggregator.meta(type: preview.type, id: preview.id, addons: app.addons)
                guard let self, !Task.isCancelled else { return }
                if let detail {
                    self.meta = preview.merged(withDetail: detail)
                    self.state = .loaded
                } else {
                    // Aucun addon ne connaît ce contenu : on garde l'aperçu exploitable.
                    self.state = preview.name.isEmpty ? .failed("Contenu introuvable chez vos addons.") : .loaded
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? "Fiche indisponible."
                self.state = self.meta.name.isEmpty ? .failed(message) : .loaded
                LogChannel("detail").warning("fiche \(preview.id) : \(message)")
            }
            await self?.refreshLibrary(app: app)
            if let self, self.selectedSeason == nil {
                self.selectedSeason = self.targetVideo?.season ?? self.meta.seasons.first
            }
            if let self, !app.isUITest, self.meta.id.hasPrefix("tt") {
                let scores = await app.reviews.scores(imdbID: self.meta.id)
                if !scores.isEmpty { self.reviews = scores }
            }
        }
    }

    func refreshLibrary(app: AppModel) async {
        let item = await app.library.item(meta.id)
        libraryItem = item
        watched = await app.library.watchedVideoIDs(itemID: meta.id, videos: meta.videos)
        if let videoID = targetVideoID {
            resumePosition = await app.library.resumePosition(itemID: meta.id, videoID: videoID)
        } else {
            resumePosition = nil
        }
    }

    func toggleLibrary(app: AppModel) {
        let ref = LibraryMetaRef(meta)
        let inLibrary = isInLibrary
        Task {
            if inLibrary { await app.library.removeFromLibrary(ref.id) } else { await app.library.addToLibrary(ref) }
            await refreshLibrary(app: app)
        }
    }

    func setWatched(_ watched: Bool, video: MetaVideo?, app: AppModel) {
        let ref = LibraryMetaRef(meta)
        let videos = meta.videos
        Task {
            if let video {
                await app.library.setEpisodeWatched(ref, videoID: video.id, watched: watched, videos: videos)
            } else {
                await app.library.markWatched(ref, watched: watched)
            }
            await refreshLibrary(app: app)
        }
    }

    func progress(for video: MetaVideo) -> Double? {
        guard let item = libraryItem, item.state.videoID == video.id, item.state.timeOffset > 1 else { return nil }
        return item.state.progress
    }
}
