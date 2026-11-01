import Foundation
import Observation
import LanterneCore

/// Une rangée de catalogue : chargement initial, pagination (`skip`), erreurs.
@MainActor
@Observable
final class CatalogRowModel: Identifiable {
    let ref: CatalogRef
    var genre: String?
    private(set) var items: [MetaItem] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var reachedEnd = false
    @ObservationIgnored private let aggregator: AddonAggregator
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedOnce = false

    nonisolated var id: String { ref.id }

    init(ref: CatalogRef, aggregator: AddonAggregator, genre: String? = nil) {
        self.ref = ref
        self.aggregator = aggregator
        self.genre = genre
    }

    var title: String { ref.title }
    var subtitle: String { "\(ref.typeLabel) · \(ref.addon.manifest.name)" }

    func loadIfNeeded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        loadNextPage()
    }

    func reload(genre: String?) {
        task?.cancel()
        self.genre = genre
        items = []
        error = nil
        reachedEnd = false
        isLoading = false
        loadedOnce = true
        loadNextPage()
    }

    func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        // Pagination seulement si le catalogue la déclare.
        if !items.isEmpty && !ref.catalog.supportsSkip { reachedEnd = true; return }
        isLoading = true
        let skip = items.count
        let genre = self.genre
        let aggregator = self.aggregator
        let ref = self.ref
        task = Task { [weak self] in
            do {
                let page = try await aggregator.page(ref, genre: genre, skip: skip)
                guard let self, !Task.isCancelled else { return }
                let known = Set(self.items.map(\.id))
                let fresh = page.filter { !known.contains($0.id) }
                self.items.append(contentsOf: fresh)
                self.reachedEnd = fresh.isEmpty
                self.error = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? "Catalogue indisponible."
                self.reachedEnd = true
            }
            self?.isLoading = false
        }
    }
}
