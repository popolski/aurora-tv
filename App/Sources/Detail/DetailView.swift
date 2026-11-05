import SwiftUI
import LanterneCore

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(Ambient.self) private var ambient
    @State private var detail: DetailModel
    @Namespace private var focusNamespace
    @State private var trailerURL: URL?
    @FocusState private var focusedAction: SecondaryAction?
    /// Logo de titre lisible (reconnaissance de texte) ; sinon le titre en texte.
    @State private var logoReadable = true

    /// Boutons ronds : leur rôle s'affiche en légende quand ils ont le focus.
    private enum SecondaryAction: Hashable { case trailer, restart, library, watched }

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
                // Film : informations sur la gauche, l'image du film reste visible à droite.
                // (Sources dans un panneau : essayé au build 35, retiré à la demande de l'utilisateur.)
                VStack(alignment: .leading, spacing: 30) {
                    header
                    failure
                }
                .frame(maxWidth: 1180, alignment: .leading)
            }
        }
        .focusScope(focusNamespace)
        .ignoresSafeArea(edges: .top)
        .task { detail.load(app: app) }
        .task(id: meta.displayLogo) {
            guard let url = meta.displayLogo else { return }
            logoReadable = await LogoCheck.shared.isReadable(url, nonLatinOrigin: meta.nonLatinOrigin)
        }
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
        VStack(alignment: .leading, spacing: 20) {
            if let logo = meta.displayLogo, logoReadable {
                RemoteImage(url: logo, maxPixel: 900, contentMode: .fit) {
                    Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary)
                }
                .frame(maxWidth: 680, maxHeight: 170, alignment: .bottomLeading)
            } else {
                Text(meta.name.isEmpty ? "…" : meta.name)
                    .font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.4), radius: 10)
            }
            if let original = meta.originalName {
                // Titre d'origine, en petit, quand le titre affiché a été rendu lisible.
                Text(original).font(.manrope(24, .semibold)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            MetaChips(meta: meta, showGenres: false)
            if let reviews = detail.reviews {
                ReviewChips(scores: reviews)
            }
            HStack(alignment: .top, spacing: 40) {
                LabeledChips(label: "Genres", values: meta.genres.map(Localize.genre))
                LabeledChips(label: "Réalisation", values: meta.directors, limit: 2, route: personRoute(.director))
            }
            LabeledChips(label: "Avec", values: meta.cast, limit: 4, route: personRoute(.cast))
            if detail.state == .loading && meta.description == nil {
                ShimmerBlock().frame(width: 860, height: 100)
            } else if let description = meta.description {
                Text(description)
                    .font(.bodyLarge)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            actions.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Theme.horizontalMargin)
        // Côté droit : le panneau (série) ou l'image ; marge réduite pour que les boutons
        // ne soient pas tronqués (constaté sur les captures : « Reprendre S02… »).
        .padding(.trailing, 20)
        .padding(.top, 100)
        .focusSection()
    }

    /// Noms cliquables vers leur filmographie (Wikidata), pour les fiches IMDb.
    private func personRoute(_ role: CreditRole) -> ((String) -> Route?)? {
        // Seulement une fois « Lire » affiché : sinon le focus initial se pose sur un nom
        // (premier élément focalisable) au lieu du bouton de lecture.
        guard FilmographyClient.isIMDbID(meta.id), !app.isDemo, detail.targetVideoID != nil else { return nil }
        let imdb = meta.id
        return { name in .person(PersonRef(name: name, role: role, fromIMDb: imdb)) }
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
                        // Bouton rond (légende au focus) : le libellé « Reprendre S02E03 · 18:20 »
                        // garde ainsi toute sa place.
                        NavigationLink(value: Route.sources(sourcesRoute(videoID: videoID, video: detail.targetVideo, start: nil))) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(CircleButtonStyle())
                        .focused($focusedAction, equals: .restart)
                        .accessibilityLabel(Text(caption(for: .restart)))
                    }
                }

                if let trailer = TrailerService.url(for: meta, settings: app.settings) {
                    Button {
                        trailerURL = nil
                        TrailerPresenter.present(trailer, title: meta.name, app: app)
                    } label: {
                        Label("Bande-annonce", systemImage: "film")
                    }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("detail.trailer")
                }

                // « Ma liste » et « Vu » regroupés dans une même capsule.
                HStack(spacing: 6) {
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
                .padding(6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
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
        case .restart:
            return "Reprendre depuis le début"
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
