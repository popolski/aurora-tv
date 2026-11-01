import SwiftUI
import LanterneCore

@MainActor
@Observable
final class HomeModel {
    private(set) var rows: [CatalogRowModel] = []
    @ObservationIgnored private var cache: [String: CatalogRowModel] = [:]

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

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if let hero = home.hero {
                    HeroBanner(meta: hero)
                } else if home.rows.isEmpty && model.isBootstrapped {
                    MessageView(systemImage: "puzzlepiece.extension",
                                title: "Aucun catalogue",
                                message: model.addons.isEmpty
                                    ? "Aucun addon n'est disponible. Vérifiez la connexion réseau ou ajoutez des addons dans Réglages."
                                    : "Vos addons ne proposent pas de catalogue affichable sur l'accueil.")
                } else {
                    ShimmerBlock().frame(height: 560).padding(.horizontal, Theme.horizontalMargin)
                }

                if !model.continueWatching.isEmpty {
                    ShelfRow(title: "Continuer à regarder", items: model.continueWatching) { item in
                        ContinueWatchingCard(item: item)
                    }
                }

                if !model.libraryItems.isEmpty {
                    ShelfRow(title: "Ma bibliothèque", items: Array(model.libraryItems.prefix(30))) { item in
                        LibraryPosterCard(item: item)
                    }
                }

                ForEach(home.rows) { row in
                    CatalogShelf(row: row)
                }
            }
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .onAppear { configure() }
        .onChange(of: model.addons) { _, _ in configure() }
        .onChange(of: model.settings) { _, _ in configure() }
    }

    private func configure() {
        home.configure(addons: model.addons, settings: model.settings, aggregator: model.aggregator)
    }
}

/// Rangée de catalogue avec navigation vers la fiche ou la grille complète.
struct CatalogShelf: View {
    let row: CatalogRowModel

    var body: some View {
        ShelfRow(title: row.title, subtitle: row.subtitle, items: row.items, isLoading: row.isLoading, error: row.error,
                 onReachEnd: { row.loadNextPage() }) { meta in
            MetaPosterLink(meta: meta)
        }
        .onAppear { row.loadIfNeeded() }
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

    private var subtitle: String {
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
                Text(meta.genres.prefix(3).joined(separator: " · ")).lineLimit(1)
            }
        }
        .font(.meta)
        .foregroundStyle(Theme.textSecondary)
    }
}
