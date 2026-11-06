import SwiftUI
import LanterneCore

/// Les trois façons d'explorer Films et Séries (catalogues Cinemeta).
enum DiscoverKind: String, CaseIterable, Identifiable {
    case popular = "top", new = "year", featured = "imdbRating"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popular: "Populaires"
        case .new: "Nouveautés"
        case .featured: "À la une"
        }
    }
}

/// Exploration d'un type (Films ou Séries) : Populaires (filtre par genre),
/// Nouveautés (filtre par année) ou À la une. Seuls ces trois choix sont
/// proposés ; les autres catalogues (Trakt, etc.) restent sur l'accueil.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    /// Type affiché par l'onglet (Films, Séries).
    var fixedType: String?
    @State private var kind: DiscoverKind = .popular
    /// Genre (Populaires) ou année (Nouveautés) ; `nil` = tous / valeur par défaut.
    @State private var filter: String?
    @State private var row: CatalogRowModel?
    /// Affiche qui a le focus, et fiches complètes déjà chargées (distribution, réalisation…).
    @State private var focused: MetaItem?
    @State private var details: [String: MetaItem] = [:]

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

    private var kinds: [DiscoverKind] { DiscoverKind.allCases.filter { catalog(for: $0) != nil } }
    private var current: CatalogRef? { catalog(for: kind) }

    /// Options du menu déroulant : genres (Populaires) ou années, de la plus récente (Nouveautés).
    private var filterOptions: [String] {
        guard kind != .featured, let options = current?.catalog.genreOptions else { return [] }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            HStack(alignment: .top, spacing: 30) {
                ScrollView(.vertical) {
                    if let row {
                        CatalogGrid(row: row, columnCount: 4, trailing: 10) { meta in focused = meta }
                            .padding(.top, 20)
                            .padding(.bottom, 120)
                    } else if app.isBootstrapped {
                        MessageView(systemImage: "square.grid.2x2", title: "Aucun catalogue à explorer",
                                    message: "Le catalogue Cinemeta n'est pas disponible. Vérifiez vos addons dans Réglages.")
                    }
                }
                // La grille va jusqu'au bas de l'écran et s'efface en fondu (build 35 : rangée coupée
                // net au-dessus du bas, effet de « cadre »).
                .mask(
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                           .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .ignoresSafeArea(edges: .bottom)
                // Panneau de détails : suit l'affiche qui a le focus.
                DiscoverDetailPanel(meta: focused.map { details[$0.id] ?? $0 })
                    .frame(width: 560)
                    .padding(.trailing, 80)
                    .padding(.bottom, 40)
            }
        }
        .padding(.top, 40)
        .task(id: focused?.id) {
            guard let meta = focused, details[meta.id] == nil else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if let detail = try? await app.aggregator.meta(type: meta.type, id: meta.id, addons: app.addons) {
                details[meta.id] = meta.merged(withDetail: detail)
            }
        }
        .onAppear {
            if !kinds.contains(kind), let first = kinds.first { kind = first }
            rebuild()
        }
        .onChange(of: kind) { _, _ in filter = nil; rebuild() }
        .onChange(of: filter) { _, _ in row?.reload(genre: effectiveFilter) }
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
        VStack(alignment: .leading, spacing: 26) {
            Text(ContentTypeLabel.label(for: type))
                .font(.screenTitle)
            HStack(spacing: 30) {
                if kinds.count > 1 { segments }
                if !filterOptions.isEmpty { filterMenu }
                Spacer(minLength: 0)
            }
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

/// Panneau de détails d'Explorer : image, titre, informations, résumé, genres,
/// distribution, réalisation du titre qui a le focus dans la grille.
struct DiscoverDetailPanel: View {
    let meta: MetaItem?
    @State private var unreadableLogos: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let meta {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: meta.background ?? meta.poster, maxPixel: 1100) { Theme.surface }
                        .frame(width: 504, height: 284)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    if let logo = meta.displayLogo, !unreadableLogos.contains(logo) {
                        RemoteImage(url: logo, maxPixel: 600, contentMode: .fit) {
                            Text(meta.name).font(.manrope(30, .heavy)).foregroundStyle(.white).lineLimit(2)
                        }
                        .frame(maxWidth: 300, maxHeight: 90, alignment: .bottomLeading)
                        .padding(18)
                    } else {
                        Text(meta.name).font(.manrope(30, .heavy)).foregroundStyle(.white).lineLimit(2).padding(18)
                    }
                }
                .frame(width: 504, height: 284)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack(spacing: 14) {
                    if let year = meta.displayYear { Text(year) }
                    if let runtime = meta.runtime { Text(runtime) }
                    if let note = RatingBadge.display(meta.imdbRating) { ImdbScoreBox(rating: note) }
                    if meta.isInCinema { CinemaBadge() }
                }
                .font(.manrope(20, .bold))
                .foregroundStyle(Theme.textSecondary)

                if let description = meta.description {
                    Text(description)
                        .font(.system(size: 21))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledChips(label: "Genres", values: meta.genres.map(Localize.genre))
                LabeledChips(label: "Avec", values: meta.cast, limit: 3)
                LabeledChips(label: "Réalisation", values: meta.directors, limit: 2)
            } else {
                Text("Parcourez la grille : le résumé du titre sélectionné s'affiche ici.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlassPanel(cornerRadius: 36))
        .animation(.easeInOut(duration: 0.25), value: meta?.id)
        .accessibilityElement(children: .combine)
        .task(id: meta?.displayLogo) {
            guard let meta, let url = meta.displayLogo else { return }
            let readable = await LogoCheck.shared.isReadable(url, nonLatinOrigin: meta.nonLatinOrigin)
            if !readable { unreadableLogos.insert(url) }
        }
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
