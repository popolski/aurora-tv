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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                header
                if let row {
                    CatalogGrid(row: row)
                } else if app.isBootstrapped {
                    MessageView(systemImage: "square.grid.2x2", title: "Aucun catalogue à explorer",
                                message: "Le catalogue Cinemeta n'est pas disponible. Vérifiez vos addons dans Réglages.")
                }
            }
            .padding(.vertical, 40)
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
        .focusSection()
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
    let row: CatalogRowModel
    private let columns = Array(repeating: GridItem(.fixed(Theme.Poster.width), spacing: 48), count: 6)

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
                    ForEach(row.items) { meta in
                        MetaPosterLink(meta: meta)
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
        .padding(.horizontal, Theme.horizontalMargin)
        .focusSection()
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
