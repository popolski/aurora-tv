import SwiftUI
import LanterneCore

/// Destinations de navigation communes à tous les onglets.
nonisolated enum Route: Hashable {
    case meta(MetaItem)
    case catalog(CatalogRef)
    case sources(SourcesRoute)
}

/// Demande d'affichage des sources d'une vidéo.
nonisolated struct SourcesRoute: Hashable {
    var meta: MetaItem
    var videoID: String
    var video: MetaVideo?
    /// Position de départ choisie sur la fiche (`nil` = début).
    var startPosition: TimeInterval?
    /// Lancer automatiquement la meilleure source (réglage).
    var autoPlay: Bool
}

nonisolated enum RootTab: Hashable {
    case home, discover, search, library, settings
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: RootTab = .home

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Accueil", systemImage: "house", value: RootTab.home) {
                NavigationRoot { HomeView() }
            }
            Tab("Explorer", systemImage: "square.grid.2x2", value: RootTab.discover) {
                NavigationRoot { DiscoverView() }
            }
            Tab("Rechercher", systemImage: "magnifyingglass", value: RootTab.search) {
                NavigationRoot { SearchView() }
            }
            Tab("Bibliothèque", systemImage: "books.vertical", value: RootTab.library) {
                NavigationRoot { LibraryView() }
            }
            Tab("Réglages", systemImage: "gearshape", value: RootTab.settings) {
                NavigationRoot { SettingsView() }
            }
        }
        .tint(Theme.accent)
        .fullScreenCover(item: $model.playback) { context in
            PlayerScreen(context: context)
                .environment(model)
        }
    }
}

/// Pile de navigation avec les destinations communes.
struct NavigationRoot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .meta(let meta): DetailView(preview: meta)
                    case .catalog(let ref): CatalogGridView(ref: ref)
                    case .sources(let request): SourcesView(request: request)
                    }
                }
        }
        .screenBackground()
    }
}
