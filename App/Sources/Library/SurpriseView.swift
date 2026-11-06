import SwiftUI
import LanterneCore

/// « Je ne sais pas quoi regarder » : un titre de Ma liste tiré au sort, filtré par type et
/// par durée ; « Un autre » relance sans reproposer les précédents.
struct SurpriseView: View {
    @Environment(AppModel.self) private var app
    @State private var kind: SurpriseKind = .any
    @State private var duration: SurpriseDuration = .any
    @State private var shown: Set<String> = []
    @State private var pick: MetaItem?
    @State private var phase: Phase = .searching
    @State private var cache: [String: MetaItem] = [:]
    @State private var drawTask: Task<Void, Never>?
    @FocusState private var focus: Target?

    private enum Phase: Equatable { case searching, found, none }
    private enum Target: Hashable { case details, another }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 28) {
                Text("Je ne sais pas quoi regarder").font(.screenTitle).foregroundStyle(Theme.textPrimary)
                filters
                result
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.top, 70)
            .frame(maxWidth: 1240, alignment: .leading)
        }
        .onAppear { draw(reset: true) }
        .onDisappear { drawTask?.cancel() }
        .onChange(of: kind) { _, _ in draw(reset: true) }
        .onChange(of: duration) { _, _ in draw(reset: true) }
    }

    private var backdrop: some View {
        ZStack {
            RemoteImage(url: pick?.background ?? pick?.poster, maxPixel: 1920, placeholder: { Color.clear })
                .backdropFill()
                .animation(.easeInOut(duration: 0.5), value: pick?.id)
            LinearGradient(colors: [Theme.backgroundDeep.opacity(0.92), Theme.backgroundDeep.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Theme.backgroundDeep.opacity(0.8)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ForEach(SurpriseKind.allCases) { k in
                    Button(k.label) { kind = k }
                        .buttonStyle(PillButtonStyle(prominent: kind == k, selected: kind == k, compact: true))
                }
            }
            .focusGroup()
            HStack(spacing: 14) {
                ForEach(SurpriseDuration.allCases) { d in
                    Button(d.label) { duration = d }
                        .buttonStyle(PillButtonStyle(prominent: duration == d, selected: duration == d, compact: true))
                }
            }
            .focusGroup()
        }
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .searching:
            HStack(spacing: 18) {
                ProgressView().tint(Theme.accent)
                Text("Tirage au sort dans Ma liste…").font(.meta).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 40)
        case .none:
            MessageView(systemImage: "dice", title: "Rien à proposer",
                        message: app.libraryItems.contains(where: \.isInLibrary)
                            ? "Aucun titre de Ma liste ne correspond à ces choix (films déjà vus exclus). Essayez une autre durée ou un autre type."
                            : "Ma liste est vide : ajoutez des films ou des séries depuis leur fiche (bouton +).")
        case .found:
            if let pick {
                VStack(alignment: .leading, spacing: 20) {
                    Text(pick.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2).minimumScaleFactor(0.6)
                    MetaChips(meta: pick)
                    if let description = pick.description {
                        Text(description).font(.bodyLarge).foregroundStyle(Theme.textSecondary).lineLimit(4)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    HStack(spacing: 20) {
                        NavigationLink(value: Route.meta(pick)) {
                            Label("Voir la fiche", systemImage: "info.circle")
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .focused($focus, equals: .details)
                        Button { draw(reset: false) } label: {
                            Label("Un autre", systemImage: "dice")
                        }
                        .buttonStyle(PillButtonStyle())
                        .focused($focus, equals: .another)
                    }
                    .focusGroup()
                    .padding(.top, 8)
                }
                .padding(.top, 30)
            }
        }
    }

    /// Tire un titre : candidats de Ma liste dans un ordre aléatoire, fiche chargée (et
    /// gardée) pour connaître la durée, premier qui correspond. 15 fiches au plus par tirage.
    private func draw(reset: Bool) {
        drawTask?.cancel()
        if reset { shown = [] }
        let keepFocusOnAnother = focus == .another
        phase = .searching
        let candidates = SurprisePicker.candidates(from: app.libraryItems, kind: kind, alreadyShown: shown)
        drawTask = Task {
            for item in candidates.prefix(15) {
                guard !Task.isCancelled else { return }
                let meta: MetaItem
                if let cached = cache[item.id] {
                    meta = cached
                } else if let loaded = try? await app.aggregator.meta(type: item.type, id: item.id, addons: app.addons) {
                    cache[item.id] = loaded
                    meta = loaded
                } else {
                    continue
                }
                // Série : durée d'un épisode (Cinemeta indique celle-ci pour les séries).
                guard duration.accepts(runtime: meta.runtimeSeconds) else { continue }
                guard !Task.isCancelled else { return }
                pick = meta
                shown.insert(item.id)
                phase = .found
                focus = keepFocusOnAnother ? .another : .details
                return
            }
            guard !Task.isCancelled else { return }
            pick = nil
            phase = .none
        }
    }
}
