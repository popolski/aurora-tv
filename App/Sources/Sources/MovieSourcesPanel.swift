import SwiftUI
import LanterneCore

/// Sources d'un film, directement sur sa fiche (panneau de droite) : recherche auprès
/// des addons, filtres, et lecture en un clic, sans écran intermédiaire.
struct MovieSourcesPanel: View {
    @Environment(AppModel.self) private var app
    @State private var model: SourcesModel
    @State private var filter = SourceFilter()
    @State private var unplayableMessage: String?
    /// Position de reprise au moment du choix (elle peut arriver après l'ouverture de la fiche).
    let resume: TimeInterval?

    init(meta: MetaItem, videoID: String, resume: TimeInterval?) {
        _model = State(initialValue: SourcesModel(request: SourcesRoute(meta: meta, videoID: videoID, video: nil,
                                                                        startPosition: nil, autoPlay: false)))
        self.resume = resume
    }

    var body: some View {
        let all = model.ranked(settings: app.settings)
        let list = filter.apply(all)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sources").font(.sectionTitle).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 10)
                Text(status(total: all.count, shown: list.count))
                    .font(.manrope(19, .bold)).foregroundStyle(Theme.textTertiary)
            }
            if !all.isEmpty {
                ScrollView(.horizontal) {
                    SourceFilterBar(filter: $filter, sources: all, compact: true)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                }
                .scrollClipDisabled()
            }
            content(all: all, list: list)
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassPanel(cornerRadius: 36))
        .focusSection()
        .task { model.load(app: app) }
        .alert("Source non lisible", isPresented: Binding(get: { unplayableMessage != nil }, set: { if !$0 { unplayableMessage = nil } })) {
            Button("OK", role: .cancel) { unplayableMessage = nil }
        } message: {
            Text(unplayableMessage ?? "")
        }
    }

    private func status(total: Int, shown: Int) -> String {
        if !model.isFinished && total == 0 { return "Recherche…" }
        let base = shown == total ? "\(total) source(s)" : "\(shown) sur \(total)"
        return model.isFinished ? base : base + " · recherche…"
    }

    @ViewBuilder private func content(all: [RankedSource], list: [RankedSource]) -> some View {
        if model.addonStatuses.isEmpty && model.raw.isEmpty && model.isFinished {
            Text("Aucun addon installé ne fournit de sources pour ce film.")
                .font(.meta).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        } else if all.isEmpty && model.isFinished {
            Text(model.raw.isEmpty ? "Aucune source trouvée." : "Des sources existent mais sont masquées (CAM, non lisibles : voir Réglages › Sources).")
                .font(.meta).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        } else if all.isEmpty {
            HStack(spacing: 14) {
                ProgressView()
                Text("Recherche auprès de vos addons…").font(.meta).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        } else if list.isEmpty {
            Button("Aucune source pour ces filtres · Effacer") { filter = SourceFilter() }
                .buttonStyle(PillButtonStyle(compact: true))
            Spacer(minLength: 0)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, source in
                        Button {
                            select(source, alternatives: all)
                        } label: {
                            SourceRow(source: source, isBest: index == 0 && !filter.isActive && source.playability.isPlayable,
                                      wasUsed: source.stream.fingerprint == model.previousFingerprint, compact: true)
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityIdentifier("panel.source.\(index)")
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 10)
            }
            .clipped()
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func select(_ source: RankedSource, alternatives: [RankedSource]) {
        if case .unsupported(let reason) = source.playability {
            unplayableMessage = reason
            return
        }
        let request = model.request
        app.play(PlaybackContext(meta: request.meta, videoID: request.videoID, video: nil, source: source,
                                 startPosition: resume, alternatives: alternatives))
    }
}
