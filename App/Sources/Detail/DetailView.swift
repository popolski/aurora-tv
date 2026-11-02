import SwiftUI
import LanterneCore

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(Ambient.self) private var ambient
    @State private var detail: DetailModel
    @Namespace private var focusNamespace
    @State private var trailerURL: URL?
    @FocusState private var focusedAction: SecondaryAction?

    /// Boutons ronds : leur rôle s'affiche en légende quand ils ont le focus.
    private enum SecondaryAction: Hashable { case trailer, library, watched }

    init(preview: MetaItem) {
        _detail = State(initialValue: DetailModel(preview: preview))
    }

    private var meta: MetaItem { detail.meta }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            if detail.isSeries {
                // Série : informations à gauche, épisodes dans un panneau à droite (toujours visibles).
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 30) {
                        header
                        failure
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    episodesPanel
                        .frame(width: 680)
                        .padding(.top, 70)
                        .padding(.bottom, 50)
                        .padding(.trailing, 70)
                }
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 40) {
                        header
                        failure
                        credits
                    }
                    .padding(.bottom, 70)
                }
                .scrollClipDisabled()
            }
        }
        .focusScope(focusNamespace)
        .ignoresSafeArea(edges: .top)
        .task { detail.load(app: app) }
        // Bande-annonce muette après quelques secondes ; coupée dès qu'on lance la lecture.
        .task(id: trailerCandidate) {
            trailerURL = nil
            guard let candidate = trailerCandidate else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(1, app.settings.trailers.delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            trailerURL = candidate
        }
        .onDisappear { trailerURL = nil }
        .onChange(of: app.libraryRevision) { _, _ in
            Task { await detail.refreshLibrary(app: app) }
        }
    }

    private var trailerCandidate: URL? {
        guard app.settings.trailers.onDetail, app.playback == nil, !app.isTrailerPresented else { return nil }
        return TrailerService.url(for: meta, settings: app.settings)
    }

    @ViewBuilder private var failure: some View {
        if case .failed(let message) = detail.state {
            MessageView(systemImage: "exclamationmark.triangle", title: "Fiche indisponible", message: message,
                        actionTitle: "Réessayer") { detail.load(app: app) }
                .padding(.horizontal, Theme.horizontalMargin)
        }
    }

    // MARK: Fond : l'image du contenu teinte tout l'écran

    private var backdrop: some View {
        ZStack {
            RemoteImage(url: meta.background ?? meta.poster, maxPixel: 1920,
                        placeholder: { Color.clear }, onLoaded: { ambient.update(from: $0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            TrailerBackdrop(url: trailerURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            LinearGradient(colors: [Theme.backgroundDeep.opacity(0.8), ambient.tint.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                   .init(color: Theme.backgroundDeep.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let logo = meta.logo {
                RemoteImage(url: logo, maxPixel: 900, contentMode: .fit) {
                    Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: 720, maxHeight: 200, alignment: .bottomLeading)
            } else {
                Text(meta.name.isEmpty ? "…" : meta.name)
                    .font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.4), radius: 10)
            }
            MetaChips(meta: meta)
            if let reviews = detail.reviews {
                ReviewChips(scores: reviews)
            }
            if detail.state == .loading && meta.description == nil {
                ShimmerBlock().frame(width: 900, height: 110)
            } else if let description = meta.description {
                Text(description)
                    .font(.bodyLarge)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                    .frame(maxWidth: 960, alignment: .leading)
            }
            actions.padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.horizontalMargin)
        .padding(.top, 120)
        .focusSection()
    }

    private var playLabel: String {
        if let video = detail.targetVideo {
            let code = video.episodeCode ?? video.title
            if detail.resumePosition != nil { return "Reprendre \(code)" }
            return "Lire \(code)"
        }
        return detail.resumePosition != nil ? "Reprendre" : "Lire"
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                if let videoID = detail.targetVideoID {
                    NavigationLink(value: Route.sources(sourcesRoute(videoID: videoID, video: detail.targetVideo,
                                                                     start: detail.resumePosition))) {
                        Label {
                            if let resume = detail.resumePosition {
                                Text("\(playLabel) · \(TimeFormat.clock(resume))")
                            } else {
                                Text(playLabel)
                            }
                        } icon: { Image(systemName: "play.fill") }
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .prefersDefaultFocus(in: focusNamespace)
                    .accessibilityIdentifier("detail.play")

                    if detail.resumePosition != nil {
                        NavigationLink(value: Route.sources(sourcesRoute(videoID: videoID, video: detail.targetVideo, start: nil))) {
                            Label("Depuis le début", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }

                if let trailer = TrailerService.url(for: meta, settings: app.settings) {
                    Button {
                        trailerURL = nil
                        TrailerPresenter.present(trailer, title: meta.name, app: app)
                    } label: {
                        Image(systemName: "film")
                    }
                    .buttonStyle(CircleButtonStyle())
                    .focused($focusedAction, equals: .trailer)
                    .accessibilityLabel(Text("Bande-annonce"))
                    .accessibilityIdentifier("detail.trailer")
                }

                Button {
                    detail.toggleLibrary(app: app)
                } label: {
                    Image(systemName: detail.isInLibrary ? "checkmark" : "plus")
                }
                .buttonStyle(CircleButtonStyle())
                .focused($focusedAction, equals: .library)
                .accessibilityLabel(Text(caption(for: .library)))
                .accessibilityIdentifier("detail.library")

                if !detail.isSeries {
                    let watched = detail.libraryItem?.isWatched ?? false
                    Button {
                        detail.setWatched(!watched, video: nil, app: app)
                    } label: {
                        Image(systemName: watched ? "eye.fill" : "eye")
                    }
                    .buttonStyle(CircleButtonStyle())
                    .focused($focusedAction, equals: .watched)
                    .accessibilityLabel(Text(caption(for: .watched)))
                }
            }
            // Légende du bouton rond qui a le focus (hauteur réservée : rien ne bouge).
            Text(focusedAction.map(caption(for:)) ?? " ")
                .font(.manrope(21, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(height: 28, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: focusedAction)
        }
    }

    private func caption(for action: SecondaryAction) -> String {
        switch action {
        case .trailer:
            return "Voir la bande-annonce"
        case .library:
            return detail.isInLibrary ? "Dans ma liste · retirer" : "Ajouter à ma liste"
        case .watched:
            return (detail.libraryItem?.isWatched ?? false) ? "Déjà vu · marquer comme non vu" : "Marquer comme vu"
        }
    }

    private func sourcesRoute(videoID: String, video: MetaVideo?, start: TimeInterval?) -> SourcesRoute {
        SourcesRoute(meta: meta, videoID: videoID, video: video, startPosition: start, autoPlay: app.settings.sources.autoPlay)
    }

    // MARK: Panneau des épisodes (série)

    private var currentSeason: Int? { detail.selectedSeason ?? meta.seasons.first }

    private func seasonLabel(_ season: Int) -> String { season == 0 ? "Bonus" : "Saison \(season)" }

    @ViewBuilder private var episodesPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                if meta.seasons.count > 1, let current = currentSeason {
                    Menu {
                        ForEach(meta.seasons, id: \.self) { season in
                            Button {
                                detail.selectedSeason = season
                            } label: {
                                if season == current {
                                    Label(seasonLabel(season), systemImage: "checkmark")
                                } else {
                                    Text(seasonLabel(season))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(seasonLabel(current))
                            Image(systemName: "chevron.down").font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("detail.season")
                } else if let current = currentSeason {
                    Text(seasonLabel(current)).font(.sectionTitle).foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 10)
                if !detail.episodesInSelectedSeason.isEmpty {
                    Text("\(detail.episodesInSelectedSeason.count) épisodes")
                        .font(.manrope(19, .bold)).foregroundStyle(Theme.textTertiary)
                }
            }

            if meta.videos.isEmpty {
                if detail.state == .loading {
                    ShimmerBlock().frame(height: 300)
                } else {
                    Text("Aucun épisode n'est listé pour cette série.")
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 10) {
                            ForEach(detail.episodesInSelectedSeason) { video in
                                EpisodeRow(video: video,
                                           isWatched: detail.watched.contains(video.id),
                                           isNext: video.id == detail.targetVideo?.id,
                                           progress: detail.progress(for: video),
                                           route: .sources(sourcesRoute(videoID: video.id, video: video,
                                                                        start: video.id == detail.targetVideo?.id ? detail.resumePosition : nil)),
                                           onToggleWatched: { watched in detail.setWatched(watched, video: video, app: app) })
                                    .id(video.id)
                            }
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 12)
                    }
                    // La liste reste dans le panneau (constaté au build 32 : les épisodes remontaient
                    // par-dessus l'en-tête) ; fondu discret en haut et en bas.
                    .clipped()
                    .mask(
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                               .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .onAppear {
                        if let target = detail.targetVideo?.id { proxy.scrollTo(target, anchor: .top) }
                    }
                    .onChange(of: detail.selectedSeason) { _, _ in
                        if let first = detail.episodesInSelectedSeason.first?.id { proxy.scrollTo(first, anchor: .top) }
                    }
                }
            }
        }
        .padding(28)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassPanel(cornerRadius: 36))
        .focusSection()
    }

    @ViewBuilder private var credits: some View {
        let lines: [(String, [String])] = [("Avec", meta.cast), ("Réalisation", meta.directors), ("Scénario", meta.writers)]
            .filter { !$0.1.isEmpty }
        if !lines.isEmpty {
            HStack(alignment: .top, spacing: 60) {
                ForEach(lines, id: \.0) { line in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(line.0).font(.manrope(19, .heavy)).foregroundStyle(Theme.textTertiary)
                        Text(line.1.prefix(6).joined(separator: "\n"))
                            .font(.manrope(23, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(6)
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(36)
            .background(GlassPanel(cornerRadius: 40))
            .padding(.horizontal, 70)
            // Lignes non focalisables : on garantit l'accès au défilement.
            .focusable()
        }
    }
}

/// Épisode dans le panneau de droite : vignette, titre, résumé, date ; « À suivre »
/// sur l'épisode visé par le bouton Lire.
struct EpisodeRow: View {
    let video: MetaVideo
    let isWatched: Bool
    let isNext: Bool
    let progress: Double?
    let route: Route
    let onToggleWatched: (Bool) -> Void
    @FocusState private var focused: Bool

    private let thumbWidth: CGFloat = 232

    var body: some View {
        NavigationLink(value: route) {
            HStack(alignment: .top, spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: video.thumbnail, maxPixel: 480) {
                        ZStack {
                            Theme.surfaceRaised
                            Image(systemName: "play.rectangle").font(.system(size: 34)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                    .clipped()
                    if let progress {
                        ProgressBar(value: progress).frame(height: 5).padding(8)
                    }
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.accent, .black)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.manrope(22, .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if let overview = video.overview {
                        Text(overview)
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(focused ? 4 : 2)
                    }
                    HStack(spacing: 10) {
                        if isNext { Badge(text: "À suivre", tint: Theme.accent) }
                        if !video.isReleased() { Badge(text: "À venir", tint: Theme.textPrimary) }
                        if let released = video.released {
                            Text(released.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 17)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.2), value: focused)
        }
        .buttonStyle(RowButtonStyle())
        .focused($focused)
        .contextMenu {
            Button(isWatched ? "Marquer comme non vu" : "Marquer comme vu") { onToggleWatched(!isWatched) }
        }
    }

    private var title: String {
        let number = video.episode.map { "\($0). " } ?? ""
        return number + (video.title.isEmpty ? "Épisode" : video.title)
    }
}

/// Notes de la critique : Tomatometer et Metascore.
struct ReviewChips: View {
    let scores: ReviewScores

    var body: some View {
        HStack(spacing: 10) {
            if let tomato = scores.tomatometer {
                Chip(text: "Rotten Tomatoes \(tomato) %",
                     tint: tomato >= 60 ? Color(red: 0.98, green: 0.36, blue: 0.29) : Theme.textSecondary)
            }
            if let meta = scores.metascore {
                Chip(text: "Metacritic \(meta)",
                     tint: meta >= 61 ? Color(red: 0.40, green: 0.80, blue: 0.20) : (meta >= 40 ? Color(red: 1.0, green: 0.80, blue: 0.20) : Color(red: 1.0, green: 0.35, blue: 0.35)))
            }
        }
    }
}

enum TimeFormat {
    /// Heure de fin si la lecture continue sans pause : « 22:47 ».
    static func endTime(after remaining: TimeInterval, from now: Date = Date()) -> String {
        guard remaining.isFinite, remaining >= 0 else { return "--:--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: now.addingTimeInterval(remaining))
    }

    /// « 1:02:03 » ou « 12:34 ».
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
