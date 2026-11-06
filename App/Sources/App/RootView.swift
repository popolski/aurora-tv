import SwiftUI
import LanterneCore

/// Destinations de navigation communes à tous les onglets.
nonisolated enum Route: Hashable {
    case meta(MetaItem)
    case catalog(CatalogRef)
    case sources(SourcesRoute)
    /// Filmographie d'une personne citée sur une fiche.
    case person(PersonRef)
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
        .onOpenURL { url in open(url) }
        // Mode démonstration : `-openURL aurora://…` ouvre directement un écran (captures de la CI,
        // sans la confirmation système qu'impose l'ouverture d'un lien depuis l'extérieur).
        .task {
            guard model.isDemo, let url = Self.launchURL else { return }
            open(url)
        }
    }

    private static var launchURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openURL"), i + 1 < args.count else { return nil }
        return URL(string: args[i + 1])
    }

    /// Lien du Top Shelf : fiche du contenu, ou directement ses sources (« Lire »).
    private func open(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            LogChannel("app").warning("lien ignoré (format inattendu)")
            return
        }
        let preview = MetaItem(id: link.id, type: link.type, name: link.name ?? "")
        var path = NavigationPath()
        path.append(Route.meta(preview))
        if link.action == .play, link.type == ContentType.movie {
            let item = model.continueWatching.first { $0.id == link.id }
            let resume = item.map { TimeInterval($0.state.timeOffset) / 1000 }.flatMap { $0 > 30 ? $0 : nil }
            path.append(Route.sources(SourcesRoute(meta: preview, videoID: link.id, video: nil, startPosition: resume,
                                                   autoPlay: model.settings.sources.autoPlay)))
        }
        tab = .home
        paths[.home] = path
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
                        case .person(let person): PersonView(person: person)
                        }
                    }
                    .screenBackground()
                    // Écrans poussés : plein écran, sans la barre d'onglets.
                    .toolbar(.hidden, for: .tabBar)
                }
        }
    }
}
