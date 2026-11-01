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

nonisolated enum RootTab: Hashable, CaseIterable, Identifiable {
    case home, movies, series, library, search, settings

    var id: Self { self }

    var label: String {
        switch self {
        case .home: "Accueil"
        case .movies: "Films"
        case .series: "Séries"
        case .library: "Ma liste"
        case .search: "Rechercher"
        case .settings: "Réglages"
        }
    }
}

/// Racine : barre d'onglets native tvOS, en haut de l'écran.
///
/// Comportement système : la barre change d'onglet au focus, Menu depuis le
/// contenu y ramène, Menu depuis la barre quitte l'app ; elle s'efface quand
/// on descend dans le contenu et sur les écrans poussés (fiche, sources).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: RootTab = .home
    @State private var paths: [RootTab: NavigationPath] = [:]

    var body: some View {
        TabView(selection: $tab) {
            ForEach([RootTab.home, .movies, .series, .library, .settings]) { t in
                Tab(value: t) { root(t) } label: { Text(t.label) }
            }
            Tab(RootTab.search.label, systemImage: "magnifyingglass", value: RootTab.search, role: .search) {
                root(.search)
            }
        }
        .background(AmbientBackground())
    }

    private func root(_ t: RootTab) -> some View {
        NavigationRoot(path: binding(for: t)) { tabRoot(t) }
            .accessibilityIdentifier("tab.\(t)")
    }

    @ViewBuilder private func tabRoot(_ t: RootTab) -> some View {
        switch t {
        case .home: HomeView()
        case .movies: DiscoverView(fixedType: ContentType.movie)
        case .series: DiscoverView(fixedType: ContentType.series)
        case .library: LibraryView()
        case .search: SearchView()
        case .settings: SettingsView()
        }
    }

    private func binding(for t: RootTab) -> Binding<NavigationPath> {
        Binding(get: { paths[t] ?? NavigationPath() }, set: { paths[t] = $0 })
    }
}

/// Pile de navigation avec les destinations communes.
struct NavigationRoot<Content: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .screenBackground()
                .navigationDestination(for: Route.self) { route in
                    Group {
                        switch route {
                        case .meta(let meta): DetailView(preview: meta)
                        case .catalog(let ref): CatalogGridView(ref: ref)
                        case .sources(let request): SourcesView(request: request)
                        }
                    }
                    .screenBackground()
                    // Écrans poussés : plein écran, sans la barre d'onglets.
                    .toolbar(.hidden, for: .tabBar)
                }
        }
    }
}
