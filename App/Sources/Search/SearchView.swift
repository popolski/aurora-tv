import SwiftUI
import LanterneCore

struct SearchGroup: Identifiable {
    let ref: CatalogRef
    var items: [MetaItem]
    var error: String?
    var id: String { ref.id }
}

@MainActor
@Observable
final class SearchModel {
    private(set) var groups: [SearchGroup] = []
    private(set) var isSearching = false
    private(set) var lastQuery = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    func search(_ raw: String, app: AppModel) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard query.count >= 2 else {
            groups = []
            isSearching = false
            lastQuery = ""
            return
        }
        let addons = app.addons
        let aggregator = app.aggregator
        let order = aggregator.searchCatalogs(addons).map(\.id)
        task = Task { [weak self] in
            // Anti-rebond : on attend la fin de la saisie.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isSearching = true
            self.lastQuery = query
            self.groups = []
            LogChannel("search").info("recherche (\(query.count) caractères) sur \(order.count) catalogue(s)")
            for await (ref, result) in aggregator.search(query, addons: addons) {
                guard !Task.isCancelled else { return }
                var group = SearchGroup(ref: ref, items: [], error: nil)
                switch result {
                case .success(let items): group.items = items
                case .failure(let error): group.error = error.errorDescription
                }
                guard !group.items.isEmpty else { continue }
                self.groups.append(group)
                self.groups.sort { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
            }
            self.isSearching = false
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var model = SearchModel()

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if model.groups.isEmpty {
                    if model.isSearching {
                        ProgressView().frame(maxWidth: .infinity).padding(60)
                    } else if !model.lastQuery.isEmpty {
                        MessageView(systemImage: "magnifyingglass", title: "Aucun résultat",
                                    message: "Aucun catalogue de vos addons ne renvoie de résultat pour « \(model.lastQuery) ».")
                    } else if app.aggregator.searchCatalogs(app.addons).isEmpty && app.isBootstrapped {
                        MessageView(systemImage: "magnifyingglass", title: "Recherche indisponible",
                                    message: "Aucun addon installé ne propose de catalogue de recherche.")
                    }
                }
                ForEach(model.groups) { group in
                    ShelfRow(title: group.ref.typeLabel, subtitle: "\(group.ref.title) · \(group.ref.addon.manifest.name)",
                             items: group.items) { meta in
                        MetaPosterLink(meta: meta)
                    }
                }
            }
            .padding(.vertical, 30)
        }
        .searchable(text: $query, prompt: "Films, séries…")
        .onChange(of: query) { _, newValue in model.search(newValue, app: app) }
    }
}
