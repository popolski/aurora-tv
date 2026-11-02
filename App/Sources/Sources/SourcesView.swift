import SwiftUI
import LanterneCore

struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SourcesModel
    @State private var unplayableMessage: String?
    @State private var filter = SourceFilter()

    init(request: SourcesRoute) {
        _model = State(initialValue: SourcesModel(request: request))
    }

    private var ranked: [RankedSource] { model.ranked(settings: app.settings) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                header
                addonChips
                if !ranked.isEmpty {
                    SourceFilterBar(filter: $filter, sources: ranked)
                }
                content
            }
            .padding(.horizontal, Theme.horizontalMargin)
            .padding(.vertical, 50)
        }
        .screenBackground()
        .task { model.load(app: app) }
        .onDisappear { model.cancel() }
        .onChange(of: model.isFinished) { _, finished in
            guard finished, let best = model.autoPlayCandidate(settings: app.settings) else { return }
            app.play(model.playbackContext(for: best, settings: app.settings))
        }
        .alert("Source non lisible", isPresented: Binding(get: { unplayableMessage != nil }, set: { if !$0 { unplayableMessage = nil } })) {
            Button("OK", role: .cancel) { unplayableMessage = nil }
        } message: {
            Text(unplayableMessage ?? "")
        }
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").font(.screenTitle).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Picker("Tri", selection: Binding(get: { app.settings.sources.sortMode },
                                                 set: { app.settings.sources.sortMode = $0 })) {
                    ForEach(SourceSortMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Langue", selection: Binding(get: { app.settings.sources.language },
                                                    set: { app.settings.sources.language = $0 })) {
                    ForEach(SourceLanguagePreference.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Masquer les CAM/TS", isOn: Binding(get: { app.settings.sources.hideCam },
                                                           set: { app.settings.sources.hideCam = $0 }))
                Toggle("Masquer les sources non lisibles", isOn: Binding(get: { app.settings.sources.hideUnplayable },
                                                                         set: { app.settings.sources.hideUnplayable = $0 }))
            } label: {
                Label(app.settings.sources.sortMode.label, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle())
        }
        .focusSection()
    }

    private var subtitle: String {
        var parts = [model.request.meta.name]
        if let video = model.request.video {
            if let code = video.episodeCode { parts.append(code) }
            if !video.title.isEmpty { parts.append(video.title) }
        }
        if let start = model.request.startPosition { parts.append("reprise à \(TimeFormat.clock(start))") }
        return parts.joined(separator: " · ")
    }

    private var addonChips: some View {
        HStack(spacing: 14) {
            ForEach(model.addonStatuses) { status in
                HStack(spacing: 8) {
                    switch status.state {
                    case .loading:
                        ProgressView().scaleEffect(0.6).frame(width: 22, height: 22)
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    }
                    Text(chipText(status)).lineLimit(1)
                }
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface))
            }
        }
    }

    private func chipText(_ status: SourcesModel.AddonStatus) -> String {
        switch status.state {
        case .loading: return status.name
        case .done(let count, let duration): return "\(status.name) · \(count) · \(String(format: "%.1f s", duration))"
        case .failed(let message): return "\(status.name) · \(message)"
        }
    }

    // MARK: Liste

    @ViewBuilder private var content: some View {
        let all = ranked
        let list = filter.apply(all)
        if !all.isEmpty && list.isEmpty {
            MessageView(systemImage: "line.3.horizontal.decrease.circle", title: "Aucune source pour ces filtres",
                        message: "\(all.count) source(s) au total.", actionTitle: "Effacer les filtres") { filter = SourceFilter() }
        } else if model.addonStatuses.isEmpty && model.raw.isEmpty {
            MessageView(systemImage: "antenna.radiowaves.left.and.right.slash", title: "Aucun addon de flux",
                        message: "Aucun addon installé ne fournit de sources pour ce contenu. Ajoutez un addon de flux dans Réglages › Addons.")
        } else if list.isEmpty && model.isFinished {
            MessageView(systemImage: "film.stack", title: "Aucune source trouvée",
                        message: model.raw.isEmpty ? "Les addons n'ont renvoyé aucun flux pour cette vidéo."
                                                   : "Des sources existent mais sont masquées par vos filtres (CAM, non lisibles).")
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, source in
                    Button {
                        select(source)
                    } label: {
                        SourceRow(source: source, isBest: index == 0 && source.playability.isPlayable,
                                  wasUsed: source.stream.fingerprint == model.previousFingerprint)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("source.\(index)")
                }
                if !model.isFinished {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Recherche en cours…").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 10)
                }
            }
            .focusSection()
        }
    }

    private func select(_ source: RankedSource) {
        if case .unsupported(let reason) = source.playability {
            unplayableMessage = reason
            return
        }
        app.play(model.playbackContext(for: source, settings: app.settings))
    }
}

/// Ligne de source : informations annoncées (contour) et compatibilité estimée.
struct SourceRow: View {
    let source: RankedSource
    let isBest: Bool
    let wasUsed: Bool
    /// Version étroite (panneau de la fiche film).
    var compact = false

    private var t: StreamTraits { source.traits }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(t.resolution?.label ?? "—")
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(t.resolution == .uhd2160 ? Theme.accent : Theme.textPrimary)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(source.title).font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if isBest { Badge(text: "Recommandée", tint: Theme.accent, announced: false) }
                    if wasUsed { Badge(text: "Déjà utilisée", tint: Theme.success, announced: false) }
                }
                badges
                HStack(spacing: 10) {
                    Text(source.addonName).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    playabilityLabel
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(source.playability.isPlayable ? 1 : 0.55)
    }

    private var fullBody: some View {
        HStack(alignment: .center, spacing: 26) {
            Text(t.resolution?.label ?? "—")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(t.resolution == .uhd2160 ? Theme.accent : Theme.textPrimary)
                .frame(width: 110)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(source.title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if isBest { Badge(text: "Recommandée", tint: Theme.accent, announced: false) }
                    if wasUsed { Badge(text: "Déjà utilisée", tint: Theme.success, announced: false) }
                }
                if let subtitle = source.subtitle {
                    Text(subtitle).font(.system(size: 21)).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
                badges
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 8) {
                Text(source.addonName).font(.system(size: 21, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                playabilityLabel
            }
            .frame(maxWidth: 300, alignment: .trailing)
        }
        .opacity(source.playability.isPlayable ? 1 : 0.55)
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 8) {
            ForEach(t.hdr, id: \.self) { Badge(text: $0.shortLabel, tint: Theme.accent) }
            if let codec = t.videoCodec { Badge(text: codec.label) }
            if t.bitDepth10 { Badge(text: "10 bits") }
            ForEach(t.audioCodecs, id: \.self) { Badge(text: $0.label) }
            if t.atmos { Badge(text: "Atmos") }
            if let channels = t.audioChannels { Badge(text: channels) }
            if t.isMultiAudio { Badge(text: "MULTI", tint: Theme.success) }
            if let variant = t.frenchVariant { Badge(text: variant, tint: Theme.success) }
            else if t.hasFrench { Badge(text: "VF", tint: Theme.success) }
            if t.isVOSTFR { Badge(text: "VOSTFR", tint: Theme.success) }
            ForEach(t.audioLanguages.filter { $0 != "fr" }.prefix(3), id: \.self) { Badge(text: $0.uppercased()) }
            if let size = t.sizeLabel { Badge(text: size) }
            if let q = t.sourceQuality.label { Badge(text: q) }
            if t.debridCached { Badge(text: "En cache", tint: Theme.success) }
            if let seeders = t.seeders { Badge(text: "👤 \(seeders)") }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var playabilityLabel: some View {
        switch source.playability {
        case .direct(let p):
            Label(p.fit.label, systemImage: p.fit == .native ? "checkmark.seal" : "cpu")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(p.fit >= .needsFFmpeg ? Theme.success : Theme.textTertiary)
        case .viaStreamingServer:
            Label("Serveur de streaming", systemImage: "server.rack")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        case .unsupported:
            Label("Non lisible", systemImage: "nosign")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.danger)
        }
    }
}
