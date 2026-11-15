import SwiftUI
import LanterneCore

/// Les façons d'explorer Films et Séries : catalogues Cinemeta, et pour les films
/// « Disponibles » (sorties vidéo récentes, TMDB via le service du NAS).
enum DiscoverKind: String, CaseIterable, Identifiable {
    case popular = "top", new = "year", featured = "imdbRating", available = "available"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popular: "Populaires"
        case .new: "Nouveautés"
        case .featured: "À la une"
        case .available: "Disponibles"
        }
    }
}

/// Exploration d'un type (Films ou Séries) : Populaires (filtre par genre),
/// Nouveautés (filtre par année), À la une, Disponibles (films). Fond immersif : l'image
/// du titre qui a le focus remplit l'écran, son résumé au-dessus d'une grille de 6 colonnes.
/// Les autres catalogues (Trakt, etc.) restent sur l'accueil.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    /// Type affiché par l'onglet (Films, Séries).
    var fixedType: String?
    @State private var kind: DiscoverKind = .popular
    /// Genre (Populaires) ou année (Nouveautés) ; `nil` = tous / valeur par défaut.
    @State private var filter: String?
    @State private var row: CatalogRowModel?
    /// Affiche qui a le focus ; titre affiché en grand (fond et résumé), mis à jour après une
    /// courte pause et une fois sa fiche complète chargée : un seul fondu, sans état intermédiaire.
    @State private var focused: MetaItem?
    @State private var featured: MetaItem?
    @State private var details: [String: MetaItem] = [:]
    /// « Disponibles » : période (jours) et résultat (`nil` = chargement ou NAS indisponible).
    @State private var availableDays = 60
    @State private var available: [DiscoveryItem]?
    @State private var availableFailed = false

    private var type: String { fixedType ?? ContentType.movie }

    /// Catalogue d'un des trois choix : Cinemeta d'abord, sinon tout addon qui expose le même identifiant.
    private func catalog(for kind: DiscoverKind) -> CatalogRef? {
        let refs = app.addons.flatMap { addon in
            addon.manifest.catalogs
                .filter { $0.type == type && $0.id == kind.rawValue }
                .map { CatalogRef(addon: addon, catalog: $0) }
        }
        return refs.first { $0.addon.manifest.id == "com.linvo.cinemeta" } ?? refs.first
    }

    /// « Disponibles » : films seulement, avec le service du NAS (clé TMDB).
    private var availableEnabled: Bool { type == ContentType.movie && app.settings.trailers.server != nil }

    private var kinds: [DiscoverKind] {
        DiscoverKind.allCases.filter { $0 == .available ? availableEnabled : catalog(for: $0) != nil }
    }
    private var current: CatalogRef? { catalog(for: kind) }

    /// Options du menu déroulant : genres (Populaires) ou années, de la plus récente (Nouveautés).
    private var filterOptions: [String] {
        guard kind != .featured, kind != .available, let options = current?.catalog.genreOptions else { return [] }
        if kind == .new, options.allSatisfy({ Int($0) != nil }) {
            return options.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
        }
        return options
    }

    private var filterRequired: Bool {
        current?.catalog.requiredExtras.contains { $0.name == ExtraName.genre } ?? false
    }

    /// Valeur envoyée à l'addon : choix de l'utilisateur, ou première option si le filtre est obligatoire.
    private var effectiveFilter: String? {
        if let filter { return filter }
        return filterRequired ? filterOptions.first : nil
    }

    /// Titre à mettre en avant : celui qui a le focus, sinon le premier de la liste.
    private var candidate: MetaItem? {
        if let focused { return focused }
        if kind == .available { return available.flatMap { app.visibleTitles($0.map(\.meta)).first } }
        return row.flatMap { app.visibleTitles($0.items).first }
    }

    private var shown: MetaItem? { featured.map { details[$0.id] ?? $0 } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Fond plein écran : image du titre mis en avant (comme l'accueil).
            BillboardBackdrop(meta: shown)
            VStack(alignment: .leading, spacing: 0) {
                header
                BillboardInfo(meta: shown, compact: true)
                    .frame(height: 262, alignment: .bottomLeading)
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.top, 20)
                ScrollView(.vertical) {
                    Group {
                        if kind == .available {
                            availableGrid
                        } else if let row {
                            CatalogGrid(row: row, columnCount: 6) { meta in focused = meta }
                        } else if app.isBootstrapped {
                            MessageView(systemImage: "square.grid.2x2", title: "Aucun catalogue à explorer",
                                        message: "Le catalogue Cinemeta n'est pas disponible. Vérifiez vos addons dans Réglages.")
                        }
                    }
                    .padding(.top, 34)
                    .padding(.bottom, 120)
                }
                // Les rangées qui remontent s'effacent en fondu sous le résumé ; la grille va
                // jusqu'au bas de l'écran.
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                           .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .padding(.top, 40)
        }
        .task(id: candidate?.id) {
            guard let meta = candidate else { return }
            if featured != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            if details[meta.id] == nil {
                let aggregator = app.aggregator, addons = app.addons
                let detail = try? await withDeadline(seconds: 3) {
                    try await aggregator.meta(type: meta.type, id: meta.id, addons: addons)
                }
                guard !Task.isCancelled else { return }
                if let detail { details[meta.id] = meta.merged(withDetail: detail) }
            }
            featured = meta
        }
        .onAppear {
            if !kinds.contains(kind), let first = kinds.first { kind = first }
            rebuild()
        }
        .task(id: kind == .available ? availableDays : -1) {
            guard kind == .available, let server = app.settings.trailers.server else { return }
            available = nil
            availableFailed = false
            let items = await app.discovery.available(server: server, days: availableDays)
            guard !Task.isCancelled else { return }
            available = items
            availableFailed = items == nil
        }
        .onChange(of: kind) { _, _ in filter = nil; focused = nil; rebuild() }
        .onChange(of: filter) { _, _ in focused = nil; row?.reload(genre: effectiveFilter) }
        .onChange(of: availableDays) { _, _ in focused = nil }
        .onChange(of: app.addons) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard let ref = current else { row = nil; return }
        if row?.ref == ref { return }
        let model = CatalogRowModel(ref: ref, aggregator: app.aggregator, genre: effectiveFilter)
        row = model
        model.loadIfNeeded()
    }

    // MARK: En-tête : titre, sélecteur à trois choix, menu déroulant

    private var header: some View {
        // Titre et choix sur une seule ligne : la place va à l'image et à la grille.
        HStack(spacing: 34) {
            Text(ContentTypeLabel.label(for: type))
                .font(.screenTitle)
                .shadow(color: .black.opacity(0.35), radius: 10)
            if kinds.count > 1 { segments }
            if kind == .available { periodMenu }
            if !filterOptions.isEmpty { filterMenu }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .focusGroup()
    }

    /// Sélecteur segmenté : un seul choix actif, clairement marqué.
    private var segments: some View {
        HStack(spacing: 6) {
            ForEach(kinds) { k in
                Button { kind = k } label: { Text(k.label) }
                    .buttonStyle(SegmentButtonStyle(selected: k == kind))
                    .accessibilityAddTraits(k == kind ? .isSelected : [])
            }
        }
        .padding(8)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.backgroundDeep.opacity(0.3)))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        )
    }

    /// « Disponibles » : sorties vidéo des 30, 60 ou 90 derniers jours.
    private var periodMenu: some View {
        Menu {
            ForEach(DiscoveryClient.availablePeriods, id: \.self) { days in
                Button {
                    availableDays = days
                } label: {
                    if days == availableDays {
                        Label("\(days) derniers jours", systemImage: "checkmark")
                    } else {
                        Text("\(days) derniers jours")
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Text("Sortis depuis \(availableDays) jours")
                Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
            }
        }
        .buttonStyle(PillButtonStyle())
    }

    /// Grille « Disponibles » (même présentation que les catalogues).
    @ViewBuilder private var availableGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(Theme.Poster.width), spacing: 48), count: 6)
        VStack(alignment: .leading, spacing: 20) {
            if availableFailed {
                MessageView(systemImage: "wifi.exclamationmark", title: "Sorties vidéo indisponibles",
                            message: "Le service du NAS ne répond pas, ou n'a pas de clé TMDB (fichier .env, voir trailer-server/README.md).")
            } else if let available {
                let movies = app.visibleTitles(available.map(\.meta))
                if movies.isEmpty {
                    MessageView(systemImage: "tray", title: "Aucune sortie vidéo sur cette période")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                        ForEach(movies) { meta in
                            MetaPosterLink(meta: meta, onFocus: { focused = $0 })
                        }
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 60) {
                    ForEach(0..<12, id: \.self) { _ in ShimmerBlock().frame(width: Theme.Poster.width, height: Theme.Poster.height) }
                }
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .focusGroup()
    }

    private var filterMenu: some View {
        let isYear = kind == .new
        let items: [(String, String)] = (filterRequired ? [] : [("", isYear ? "Toutes" : "Tous")])
            + filterOptions.map { ($0, isYear ? $0 : Localize.genre($0)) }
        let selected = effectiveFilter ?? ""
        let selectedLabel = items.first { $0.0 == selected }?.1 ?? (isYear ? "Toutes" : "Tous")
        return Menu {
            ForEach(items, id: \.0) { item in
                Button {
                    filter = item.0.isEmpty ? nil : item.0
                } label: {
                    if item.0 == selected {
                        Label(item.1, systemImage: "checkmark")
                    } else {
                        Text(item.1)
                    }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Text("\(isYear ? "Année" : "Genre") : \(selectedLabel)")
                Image(systemName: "chevron.down").font(.system(size: 20, weight: .bold))
            }
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityIdentifier("discover.filter")
    }
}

/// Élément du sélecteur segmenté : choix actif en blanc plein, focus agrandi.
struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, selected: selected)
    }

    private struct SegmentBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.manrope(26, .heavy))
                .lineLimit(1)
                .padding(.horizontal, 38)
                .padding(.vertical, 18)
                .foregroundStyle(selected || isFocused ? Theme.onFocus : Theme.textSecondary)
                .background(Capsule().fill(isFocused ? Theme.focus : (selected ? Color.white.opacity(0.85) : Color.clear)))
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 18, y: 8)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        }
    }
}

/// Grille paginée d'un catalogue.
struct CatalogGrid: View {
    @Environment(AppModel.self) private var model
    let row: CatalogRowModel
    var columnCount = 6
    var leading: CGFloat = Theme.horizontalMargin
    var trailing: CGFloat = Theme.horizontalMargin
    var onFocus: ((MetaItem) -> Void)?
    private var columns: [GridItem] { Array(repeating: GridItem(.fixed(Theme.Poster.width), spacing: 48), count: columnCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = row.error, row.items.isEmpty {
                MessageView(systemImage: "wifi.exclamationmark", title: "Catalogue indisponible", message: error,
                            actionTitle: "Réessayer") { row.reload(genre: row.genre) }
            } else if row.items.isEmpty && row.isLoading {
                LazyVGrid(columns: columns, spacing: 60) {
                    ForEach(0..<12, id: \.self) { _ in ShimmerBlock().frame(width: Theme.Poster.width, height: Theme.Poster.height) }
                }
            } else if row.items.isEmpty {
                MessageView(systemImage: "tray", title: "Catalogue vide")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                    ForEach(model.visibleTitles(row.items)) { meta in
                        MetaPosterLink(meta: meta, onFocus: onFocus)
                            .onAppear {
                                if let index = row.items.firstIndex(where: { $0.id == meta.id }), index >= row.items.count - 12 {
                                    row.loadNextPage()
                                }
                            }
                    }
                }
                if row.isLoading { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .padding(.leading, leading)
        .padding(.trailing, trailing)
        .focusGroup()
    }
}

/// Grille plein écran d'un catalogue (depuis « voir tout »).
struct CatalogGridView: View {
    @Environment(AppModel.self) private var app
    let ref: CatalogRef
    @State private var row: CatalogRowModel?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text(ref.title).font(.screenTitle).padding(.horizontal, Theme.horizontalMargin)
                if let row { CatalogGrid(row: row) }
            }
            .padding(.vertical, 40)
        }
        .onAppear {
            if row == nil {
                let model = CatalogRowModel(ref: ref, aggregator: app.aggregator)
                row = model
                model.loadIfNeeded()
            }
        }
    }
}
