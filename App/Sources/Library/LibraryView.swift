import SwiftUI
import LanterneCore

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var section: LibrarySection = .continueWatching

    enum LibrarySection: String, CaseIterable, Identifiable {
        case continueWatching, movies, series, history
        var id: String { rawValue }
        var label: String {
            switch self {
            case .continueWatching: "En cours"
            case .movies: "Films"
            case .series: "Séries"
            case .history: "Historique"
            }
        }
    }

    private var items: [LibraryItem] {
        switch section {
        case .continueWatching: app.continueWatching
        case .movies: app.libraryItems.filter { $0.type == ContentType.movie }
        case .series: app.libraryItems.filter { $0.type == ContentType.series }
        case .history: app.history
        }
    }

    private let columns = Array(repeating: GridItem(.fixed(Theme.Poster.width), spacing: 48), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 18) {
                    ForEach(LibrarySection.allCases) { s in
                        Button { section = s } label: {
                            Text(s.label).foregroundStyle(s == section ? Theme.accent : Theme.textPrimary)
                        }
                        .buttonStyle(PillButtonStyle(prominent: s == section))
                    }
                    Spacer()
                    syncLabel
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .focusSection()

                if items.isEmpty {
                    MessageView(systemImage: "books.vertical", title: emptyTitle, message: emptyMessage)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                        ForEach(items) { item in
                            if section == .continueWatching {
                                ContinueWatchingCard(item: item)
                            } else {
                                LibraryPosterCard(item: item)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.horizontalMargin)
                    .focusSection()
                }
            }
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder private var syncLabel: some View {
        switch app.syncState {
        case .syncing:
            Label("Synchronisation…", systemImage: "arrow.triangle.2.circlepath").font(.meta).foregroundStyle(Theme.textTertiary)
        case .succeeded(let date):
            Text("Synchronisé \(date.formatted(date: .omitted, time: .shortened))").font(.meta).foregroundStyle(Theme.textTertiary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud").font(.meta).foregroundStyle(Theme.danger).lineLimit(1)
        case .idle:
            Text(app.session == nil ? "Bibliothèque locale (non connectée)" : "").font(.meta).foregroundStyle(Theme.textTertiary)
        }
    }

    private var emptyTitle: String {
        switch section {
        case .continueWatching: "Rien en cours"
        case .movies: "Aucun film"
        case .series: "Aucune série"
        case .history: "Historique vide"
        }
    }

    private var emptyMessage: String {
        switch section {
        case .continueWatching, .history: "Les contenus que vous regardez apparaîtront ici."
        case .movies, .series: "Ajoutez des contenus depuis leur fiche (bouton « Ajouter »)."
        }
    }
}
