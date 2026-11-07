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
    /// Personnes du cinéma dont le nom correspond (Wikidata).
    private(set) var people: [PersonHit] = []
    private(set) var isSearching = false
    private(set) var lastQuery = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    func search(_ raw: String, app: AppModel) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard query.count >= 2 else {
            groups = []
            people = []
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
            self.people = []
            if !app.isUITest || app.isDemo, let url = PeopleSearch.requestURL(query: query) {
                let http = app.webHTTP
                Task { [weak self] in
                    guard let response = try? await http.send(HTTPRequest(url: url, timeout: 10, maxBytes: 256 * 1024)),
                          response.status == 200 else { return }
                    let hits = PeopleSearch.parse(response.data)
                    guard let self, !Task.isCancelled, self.lastQuery == query else { return }
                    self.people = Array(hits.prefix(12))
                }
            }
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
                if !model.people.isEmpty {
                    PeopleRow(people: model.people)
                }
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
                             items: app.visibleTitles(group.items)) { meta in
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

/// Personnes trouvées : un appui ouvre leur filmographie.
private struct PeopleRow: View {
    let people: [PersonHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Personnes").font(.sectionTitle).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.horizontalMargin)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 22) {
                    ForEach(people) { person in
                        NavigationLink(value: Route.person(PersonRef(name: person.name, role: .cast, fromIMDb: "",
                                                                     wikidataID: person.wikidataID))) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(person.name, systemImage: "person.crop.circle").font(.manrope(24, .bold)).lineLimit(1)
                                if let description = person.description {
                                    Text(description.capitalizedFirst).font(.system(size: 19)).lineLimit(1).opacity(0.75)
                                }
                            }
                            .frame(width: 420, alignment: .leading)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusGroup()
    }
}
