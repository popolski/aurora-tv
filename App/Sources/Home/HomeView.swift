import SwiftUI
import LanterneCore

@MainActor
@Observable
final class HomeModel {
    private(set) var rows: [CatalogRowModel] = []
    /// Fiches complètes des éléments de bibliothèque (qui n'ont que nom + affiche).
    private(set) var enriched: [String: MetaItem] = [:]
    @ObservationIgnored private var cache: [String: CatalogRowModel] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    private static func isRich(_ meta: MetaItem) -> Bool { meta.background != nil && meta.description != nil }

    /// Précharge les fiches complètes (4 en parallèle) pour que le bandeau n'ait
    /// jamais à afficher un état intermédiaire.
    func prefetch(_ items: [MetaItem], aggregator: AddonAggregator, addons: [AddonDescriptor]) {
        let todo = items.filter { !Self.isRich($0) && enriched[$0.id] == nil && !pending.contains($0.id) }
        guard !todo.isEmpty, !addons.isEmpty else { return }
        todo.forEach { pending.insert($0.id) }
        prefetchTask = Task { [weak self] in
            for start in stride(from: 0, to: todo.count, by: 4) {
                let batch = Array(todo[start..<min(start + 4, todo.count)])
                let results = await withTaskGroup(of: (String, MetaItem?).self) { group in
                    for meta in batch {
                        group.addTask {
                            let detail = try? await withDeadline(seconds: 8) {
                                try await aggregator.meta(type: meta.type, id: meta.id, addons: addons)
                            }
                            return (meta.id, detail.flatMap { $0 }.map { meta.merged(withDetail: $0) })
                        }
                    }
                    var out: [(String, MetaItem?)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                guard let self, !Task.isCancelled else { return }
                for (id, meta) in results {
                    self.pending.remove(id)
                    if let meta { self.enriched[id] = meta }
                }
            }
        }
    }

    @ObservationIgnored private var trailerChecked: Set<String> = []

    /// Fiche avec ses bandes-annonces (les catalogues ne les donnent pas toujours).
    func withTrailer(_ meta: MetaItem, aggregator: AddonAggregator, addons: [AddonDescriptor]) async -> MetaItem {
        if TrailerLink.firstValidID(in: meta) != nil { return meta }
        if let rich = enriched[meta.id], TrailerLink.firstValidID(in: rich) != nil { return rich }
        guard !trailerChecked.contains(meta.id) else { return meta }
        trailerChecked.insert(meta.id)
        let detail = try? await withDeadline(seconds: 6) {
            try await aggregator.meta(type: meta.type, id: meta.id, addons: addons)
        }
        guard let detail = detail.flatMap({ $0 }) else { return meta }
        let merged = (enriched[meta.id] ?? meta).merged(withDetail: detail)
        enriched[meta.id] = merged
        return merged
    }

    /// Version complète d'un contenu (attend au plus ~3 s si elle n'est pas encore là).
    func resolve(_ meta: MetaItem, aggregator: AddonAggregator, addons: [AddonDescriptor]) async -> MetaItem {
        if Self.isRich(meta) { return meta }
        if let rich = enriched[meta.id] { return rich }
        let detail = try? await withDeadline(seconds: 3) {
            try await aggregator.meta(type: meta.type, id: meta.id, addons: addons)
        }
        guard let detail = detail.flatMap({ $0 }) else { return meta }
        let merged = meta.merged(withDetail: detail)
        enriched[meta.id] = merged
        return merged
    }

    /// Reconstruit les rangées quand les addons ou les réglages changent,
    /// en réutilisant les rangées déjà chargées.
    func configure(addons: [AddonDescriptor], settings: AppSettings, aggregator: AddonAggregator) {
        var refs = aggregator.browsableCatalogs(addons)
            .filter { !settings.hiddenHomeCatalogs.contains($0.id) }
        if !settings.homeCatalogOrder.isEmpty {
            let order = Dictionary(settings.homeCatalogOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            refs = refs.enumerated().sorted { a, b in
                (order[a.element.id] ?? 10_000 + a.offset) < (order[b.element.id] ?? 10_000 + b.offset)
            }.map(\.element)
        }
        let newRows = refs.map { ref in
            if let existing = cache[ref.id], existing.ref == ref { return existing }
            let row = CatalogRowModel(ref: ref, aggregator: aggregator)
            cache[ref.id] = row
            return row
        }
        if newRows.map(\.id) != rows.map(\.id) { rows = newRows }
    }

    /// Élément mis en avant : premier contenu avec image de fond.
    var hero: MetaItem? {
        for row in rows {
            if let m = row.items.first(where: { $0.background != nil }) { return m }
        }
        return rows.first?.items.first
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var home = HomeModel()
    /// Contenu affiché dans le bandeau (celui qui a le focus, après un court délai).
    @State private var featured: MetaItem?
    @State private var candidate: MetaItem?
    @State private var trailerURL: URL?
    @State private var trailerPlaying = false

    private var shown: MetaItem? { (featured ?? home.hero).map { home.enriched[$0.id] ?? $0 } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            BillboardBackdrop(meta: shown, trailerURL: trailerURL, onTrailerPlaying: { trailerPlaying = $0 })
            VStack(alignment: .leading, spacing: 0) {
                BillboardInfo(meta: shown, dimmed: trailerPlaying)
                    .frame(height: 470, alignment: .bottomLeading)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.bottom, 18)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        rows
                    }
                    // Chaque rangée s'aligne en haut de la zone : position constante, pas de saut.
                    .scrollTargetLayout()
                    .padding(.top, 24)
                    .padding(.bottom, 60)
                }
                .scrollTargetBehavior(.viewAligned)
                // Masque : les rangées qui remontent disparaissent en fondu au lieu de
                // passer sous le résumé du bandeau (constaté sur l'appareil, build 10).
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .black, location: 0.1),
                                           .init(color: .black, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .onAppear { configure(); prefetch() }
        .onChange(of: model.addons) { _, _ in configure(); prefetch() }
        .onChange(of: model.settings) { _, _ in configure() }
        .onChange(of: model.libraryRevision) { _, _ in prefetch() }
        // Le bandeau suit le focus après une courte pause, et ne change qu'une fois la
        // fiche complète disponible : un seul fondu, jamais d'état intermédiaire.
        .task(id: candidate?.id) {
            guard let candidate else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let full = await home.resolve(candidate, aggregator: model.aggregator, addons: model.addons)
            guard !Task.isCancelled else { return }
            featured = full
        }
        // Bande-annonce du titre mis en avant, après quelques secondes d'arrêt dessus.
        .task(id: trailerKey) {
            trailerURL = nil
            guard trailerKey != nil, let meta = shown else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(1, model.settings.trailers.delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let full = await home.withTrailer(meta, aggregator: model.aggregator, addons: model.addons)
            guard !Task.isCancelled else { return }
            trailerURL = TrailerService.url(for: full, settings: model.settings)
        }
        .task(id: trailerPrefetchKey) { prefetchTrailers() }
        .onDisappear { trailerURL = nil }
    }

    @ViewBuilder private var rows: some View {
        if home.rows.isEmpty && model.continueWatching.isEmpty && model.isBootstrapped {
            MessageView(systemImage: "puzzlepiece.extension",
                        title: "Aucun catalogue",
                        message: model.addons.isEmpty
                            ? "Aucun addon n'est disponible. Vérifiez la connexion réseau ou ajoutez des addons dans Réglages."
                            : "Vos addons ne proposent pas de catalogue affichable sur l'accueil.")
        }
        if !model.continueWatching.isEmpty {
            ShelfRow(title: "Continuer à regarder", items: model.continueWatching, cardHeight: BackdropCard.height) { item in
                ContinueWatchingBackdrop(item: item, meta: home.enriched[item.id]) { candidate = item.previewMeta }
            }
        }
        if !model.libraryItems.isEmpty {
            ShelfRow(title: "Ma liste", items: Array(model.libraryItems.prefix(30)), cardHeight: BackdropCard.height) { item in
                let rich = home.enriched[item.id]
                BackdropCard(title: item.name, imageURL: rich?.background, fallbackURL: item.poster, logoURL: rich?.logo,
                             route: .meta(rich ?? item.previewMeta), onFocus: { candidate = item.previewMeta })
            }
        }
        ForEach(home.rows) { row in
            CatalogShelf(row: row) { meta in candidate = meta }
        }
    }

    private func configure() {
        home.configure(addons: model.addons, settings: model.settings, aggregator: model.aggregator)
    }

    private var trailerKey: String? {
        guard model.settings.trailers.onHome, model.settings.trailers.server != nil, model.playback == nil else { return nil }
        return shown?.id
    }

    private var trailerPrefetchKey: String {
        "\(home.rows.first?.items.count ?? 0)|\(home.enriched.count)|\(model.settings.trailers.serverURL)"
    }

    /// Prépare sur le NAS les bandes-annonces les plus probables : en cours, puis première rangée.
    private func prefetchTrailers() {
        let continuing = model.continueWatching.compactMap { home.enriched[$0.id] }
        let firstRow = home.rows.first?.items.prefix(10) ?? []
        TrailerService.prefetch(continuing + Array(firstRow), settings: model.settings)
    }

    private func prefetch() {
        let items = (model.continueWatching + model.libraryItems.prefix(24)).map(\.previewMeta)
        home.prefetch(items, aggregator: model.aggregator, addons: model.addons)
    }
}

/// Rangée de catalogue (cartes paysage).
struct CatalogShelf: View {
    let row: CatalogRowModel
    var onFocus: (MetaItem) -> Void = { _ in }

    var body: some View {
        ShelfRow(title: row.title, subtitle: row.subtitle, items: row.items, isLoading: row.isLoading, error: row.error,
                 cardHeight: BackdropCard.height, onReachEnd: { row.loadNextPage() }) { meta in
            BackdropCard(title: meta.name, imageURL: meta.background, fallbackURL: meta.poster, logoURL: meta.logo,
                         route: .meta(meta), onFocus: { onFocus(meta) })
        }
        .onAppear { row.loadIfNeeded() }
    }
}

/// Carte « Continuer à regarder » (paysage, avec progression).
struct ContinueWatchingBackdrop: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItem
    /// Fiche complète préchargée (image de fond, logo), si disponible.
    var meta: MetaItem?
    var onFocus: () -> Void = {}

    var body: some View {
        BackdropCard(title: item.name, imageURL: meta?.background, fallbackURL: item.poster, logoURL: meta?.logo,
                     subtitle: ContinueWatchingCard.subtitle(for: item),
                     progress: item.state.progress, route: .meta(meta ?? item.previewMeta), onFocus: onFocus)
            .contextMenu {
                Button("Retirer de « Continuer à regarder »", role: .destructive) {
                    Task { await model.library.dismissFromContinueWatching(item.id) }
                }
            }
    }
}

/// Affiche d'un contenu qui ouvre sa fiche.
struct MetaPosterLink: View {
    let meta: MetaItem

    var body: some View {
        PosterCard(title: meta.name, imageURL: meta.poster, subtitle: meta.displayYear, shape: meta.posterShape,
                   route: .meta(meta))
    }
}

struct LibraryPosterCard: View {
    let item: LibraryItem

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster, subtitle: item.type == ContentType.series ? "Série" : "Film",
                   shape: item.posterShape, route: .meta(item.previewMeta))
    }
}

struct ContinueWatchingCard: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItem

    private var subtitle: String { Self.subtitle(for: item) }

    static func subtitle(for item: LibraryItem) -> String {
        if let video = item.state.videoID, item.type == ContentType.series {
            let parts = video.split(separator: ":")
            if parts.count >= 3, let s = Int(parts[parts.count - 2]), let e = Int(parts[parts.count - 1]) {
                return item.state.timeOffset <= 1 ? String(format: "Suivant : S%02dE%02d", s, e) : String(format: "S%02dE%02d", s, e)
            }
        }
        if item.state.duration > 0 {
            let remaining = max(0, item.state.duration - item.state.timeOffset) / 60_000
            return "Reste \(remaining) min"
        }
        return ContentTypeLabel.label(for: item.type)
    }

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster, subtitle: subtitle, shape: item.posterShape,
                   progress: item.state.progress, route: .meta(item.previewMeta))
        .contextMenu {
            Button("Retirer de « Continuer à regarder »", role: .destructive) {
                Task { await model.library.dismissFromContinueWatching(item.id) }
            }
        }
    }
}

extension LibraryItem {
    /// Aperçu minimal pour ouvrir la fiche (la fiche complète est rechargée).
    var previewMeta: MetaItem {
        MetaItem(id: id, type: type, name: name, poster: poster, posterShape: posterShape, defaultVideoID: defaultVideoID)
    }
}

/// Bandeau de mise en avant en tête d'accueil.
struct HeroBanner: View {
    let meta: MetaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: meta.background ?? meta.poster, maxPixel: 1920) {
                Theme.surface
            }
            .frame(height: 640)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(colors: [Theme.background.opacity(0.0), Theme.background.opacity(0.65), Theme.background],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                LinearGradient(colors: [Theme.background.opacity(0.85), .clear], startPoint: .leading, endPoint: .center)
            )

            VStack(alignment: .leading, spacing: 18) {
                if let logo = meta.logo {
                    RemoteImage(url: logo, maxPixel: 900, contentMode: .fit) {
                        Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary)
                    }
                    .frame(maxWidth: 700, maxHeight: 180, alignment: .leading)
                } else {
                    Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                }
                MetaLine(meta: meta)
                if let description = meta.description {
                    Text(description)
                        .font(.bodyLarge)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                HStack(spacing: 24) {
                    NavigationLink(value: Route.meta(meta)) {
                        Label("Voir la fiche", systemImage: "info.circle")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.bottom, 30)
        }
        .frame(height: 640)
        .focusSection()
    }
}

/// Ligne d'informations : année · durée · note · genres. N'affiche que ce qui existe.
struct MetaLine: View {
    let meta: MetaItem

    var body: some View {
        HStack(spacing: 18) {
            if let year = meta.displayYear { Text(year) }
            if let runtime = meta.runtime { Text(runtime) }
            if let rating = meta.imdbRating {
                HStack(spacing: 6) {
                    Text("IMDb").font(.badge).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent)).foregroundStyle(.black)
                    Text(rating)
                }
                .accessibilityLabel(Text("Note IMDb \(rating)"))
            }
            if !meta.genres.isEmpty {
                Text(meta.genres.prefix(3).map(Localize.genre).joined(separator: " · ")).lineLimit(1)
            }
        }
        .font(.meta)
        .foregroundStyle(Theme.textSecondary)
    }
}
