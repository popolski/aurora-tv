import SwiftUI
import LanterneCore

/// Filmographie d'une personne citée sur une fiche (« Avec », « Réalisation »),
/// d'après Wikidata : films puis séries, du plus récent au plus ancien.
struct PersonView: View {
    @Environment(AppModel.self) private var app
    let person: PersonRef

    private enum Phase: Equatable {
        case loading
        case loaded(Filmography)
        case unavailable
    }

    @State private var phase: Phase = .loading
    private let columns = Array(repeating: GridItem(.fixed(Theme.Poster.width), spacing: 48), count: 6)

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(displayName).font(.screenTitle).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.meta).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, Theme.horizontalMargin)

                switch phase {
                case .loading:
                    ProgressView().scaleEffect(1.4).tint(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 300)
                case .unavailable:
                    MessageView(systemImage: "person.crop.rectangle",
                                title: "Filmographie indisponible",
                                message: "Wikidata ne connaît pas \(person.name) pour ce titre, ou ne répond pas pour l'instant.",
                                actionTitle: "Réessayer") { Task { await load() } }
                        .padding(.horizontal, Theme.horizontalMargin)
                case .loaded(let filmography):
                    section("Films", filmography.movies)
                    section("Séries", filmography.series)
                    Text("Source : Wikidata. Certaines œuvres peuvent manquer ou ne pas avoir de sources dans vos addons.")
                        .font(.system(size: 19)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.horizontalMargin)
                }
            }
            .padding(.vertical, 50)
        }
        .task { if phase == .loading { await load() } }
    }

    private var displayName: String {
        if case .loaded(let f) = phase { return f.name }
        return person.name
    }

    private var subtitle: String {
        var roles: [CreditRole] = [person.role]
        if case .loaded(let f) = phase {
            roles = CreditRole.allCases.filter { f.roles.contains($0) }
            let counts = [f.movies.isEmpty ? nil : "\(f.movies.count) film\(f.movies.count > 1 ? "s" : "")",
                          f.series.isEmpty ? nil : "\(f.series.count) série\(f.series.count > 1 ? "s" : "")"].compactMap { $0 }
            return (roles.map(\.label) + [counts.joined(separator: ", ")]).filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return roles.map(\.label).joined(separator: " · ")
    }

    private func load() async {
        phase = .loading
        let result = await app.filmography.filmography(for: person)
        phase = result.map(Phase.loaded) ?? .unavailable
    }

    @ViewBuilder private func section(_ title: String, _ credits: [PersonCredit]) -> some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.sectionTitle).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.horizontalMargin)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                    ForEach(credits) { credit in
                        PosterCard(title: credit.title, imageURL: credit.posterURL, subtitle: caption(credit),
                                   route: .meta(MetaItem(id: credit.imdbID, type: credit.type, name: credit.title,
                                                         poster: credit.posterURL)))
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .focusSection()
            }
        }
    }

    private func caption(_ credit: PersonCredit) -> String {
        var parts: [String] = []
        if let year = credit.year { parts.append(String(year)) }
        if credit.roles.contains(.director) && person.role == .cast || credit.roles == [.director] {
            parts.append("Réalisation")
        }
        return parts.joined(separator: " · ")
    }
}
