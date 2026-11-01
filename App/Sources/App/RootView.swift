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

    /// Onglets affichés en icône seule dans la capsule.
    var iconOnly: String? {
        switch self {
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        default: nil
        }
    }
}

/// Racine : contenu de l'onglet + capsule de navigation flottante en bas.
///
/// Conventions tvOS conservées : la capsule change d'onglet au focus ; Menu
/// depuis le contenu ramène à la capsule ; Menu depuis la capsule quitte l'app.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: RootTab = .home
    @State private var visited: Set<RootTab> = [.home]
    @State private var paths: [RootTab: NavigationPath] = [:]
    @FocusState private var dockFocus: RootTab?

    private var atTabRoot: Bool { (paths[tab]?.count ?? 0) == 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Les onglets visités restent en mémoire (positions et chargements conservés).
            ForEach(RootTab.allCases.filter { visited.contains($0) }) { t in
                NavigationRoot(path: binding(for: t)) {
                    tabRoot(t)
                        // Réserve la place de la capsule : le dernier élément n'est jamais masqué.
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Theme.dockClearance - 40) }
                }
                    .opacity(t == tab ? 1 : 0)
                    .disabled(t != tab)
                    .accessibilityHidden(t != tab)
            }
            if atTabRoot {
                dock
                    .padding(.bottom, 34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(AmbientBackground())
        .animation(.easeInOut(duration: 0.25), value: atTabRoot)
        .onExitCommand(perform: atTabRoot && dockFocus == nil ? { dockFocus = tab } : nil)
        .onChange(of: dockFocus) { _, focused in
            guard let focused else { return }
            visited.insert(focused)
            tab = focused
        }
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

    private var dock: some View {
        HStack(spacing: 6) {
            ForEach(RootTab.allCases) { t in
                Button {
                    visited.insert(t)
                    tab = t
                } label: {
                    if let icon = t.iconOnly {
                        Image(systemName: icon).accessibilityLabel(Text(t.label))
                    } else {
                        Text(t.label)
                    }
                }
                .buttonStyle(DockItemStyle(selected: t == tab))
                .focused($dockFocus, equals: t)
                .accessibilityIdentifier("dock.\(t)")
            }
        }
        .padding(10)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.backgroundDeep.opacity(0.35)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .focusSection()
    }
}

/// Élément de la capsule : onglet courant en blanc, focus agrandi.
struct DockItemStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        DockBody(configuration: configuration, selected: selected)
    }

    private struct DockBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.manrope(23, .heavy))
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
                .foregroundStyle(selected || isFocused ? Theme.onFocus : Theme.textSecondary)
                .background(Capsule().fill(selected || isFocused ? Theme.focus : Color.clear))
                .scaleEffect(isFocused ? 1.1 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        }
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
                }
        }
    }
}
