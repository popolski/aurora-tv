import SwiftUI
import LanterneCore

/// Exploration : type de contenu → catalogue → genre, en grille paginée.
struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedType: String = ContentType.movie
    @State private var selectedCatalogID: String?
    @State private var genre: String?
    @State private var row: CatalogRowModel?

    /// Catalogues explorables : sans extra obligatoire, ou dont le seul extra obligatoire est un genre à options.
    private var catalogs: [CatalogRef] {
        app.addons.flatMap { addon in
            addon.manifest.catalogs.filter { c in
                c.requiredExtras.allSatisfy { $0.name == ExtraName.genre && !$0.options.isEmpty }
            }.map { CatalogRef(addon: addon, catalog: $0) }
        }
    }

    private var types: [String] {
        var seen: [String] = []
        for c in catalogs where !seen.contains(c.catalog.type) { seen.append(c.catalog.type) }
        return seen.sorted { a, b in
            let order = [ContentType.movie, ContentType.series]
            return (order.firstIndex(of: a) ?? 99, a) < (order.firstIndex(of: b) ?? 99, b)
        }
    }

    private var catalogsOfType: [CatalogRef] { catalogs.filter { $0.catalog.type == selectedType } }

    private var current: CatalogRef? {
        catalogsOfType.first { $0.id == selectedCatalogID } ?? catalogsOfType.first
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                pickers
                if let row {
                    CatalogGrid(row: row)
                } else if app.isBootstrapped {
                    MessageView(systemImage: "square.grid.2x2", title: "Aucun catalogue à explorer",
                                message: "Vos addons ne proposent pas de catalogue explorable.")
                }
            }
            .padding(.vertical, 40)
        }
        .onAppear { if !types.contains(selectedType), let first = types.first { selectedType = first }; rebuild() }
        .onChange(of: selectedType) { _, _ in selectedCatalogID = nil; genre = nil; rebuild() }
        .onChange(of: selectedCatalogID) { _, _ in genre = nil; rebuild() }
        .onChange(of: genre) { _, _ in row?.reload(genre: effectiveGenre) }
        .onChange(of: app.addons) { _, _ in rebuild() }
    }

    private var effectiveGenre: String? {
        if let genre { return genre }
        // Genre obligatoire : premier choix par défaut.
        if let required = current?.catalog.requiredExtras.first(where: { $0.name == ExtraName.genre }) { return required.options.first }
        return nil
    }

    private func rebuild() {
        guard let ref = current else { row = nil; return }
        if row?.ref == ref { return }
        let model = CatalogRowModel(ref: ref, aggregator: app.aggregator, genre: effectiveGenre)
        row = model
        model.loadIfNeeded()
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 18) {
            chipRow(items: types.map { ($0, ContentTypeLabel.label(for: $0)) }, selected: selectedType) { selectedType = $0 }
            if catalogsOfType.count > 1 {
                chipRow(items: catalogsOfType.map { ($0.id, "\(Localize.catalogTitle(name: $0.title, type: $0.catalog.type)) · \($0.addon.manifest.name)") },
                        selected: current?.id ?? "") { selectedCatalogID = $0 }
            }
            if let options = current?.catalog.genreOptions, !options.isEmpty {
                let required = current?.catalog.requiredExtras.contains { $0.name == ExtraName.genre } ?? false
                let items = (required ? [] : [("", "Tous")]) + options.map { ($0, Localize.genre($0)) }
                chipRow(items: items, selected: effectiveGenre ?? "") { genre = $0.isEmpty ? nil : $0 }
            }
        }
    }

    private func chipRow(items: [(String, String)], selected: String, onSelect: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(items, id: \.0) { item in
                    Button { onSelect(item.0) } label: {
                        Text(item.1)
                    }
                    .buttonStyle(PillButtonStyle(prominent: item.0 == selected, selected: item.0 == selected))
                }
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.vertical, 14)
        }
        .scrollClipDisabled()
        .focusSection()
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
