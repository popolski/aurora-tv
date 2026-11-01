import SwiftUI
import LanterneCore

struct DetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(Ambient.self) private var ambient
    @State private var detail: DetailModel
    @Namespace private var focusNamespace

    init(preview: MetaItem) {
        _detail = State(initialValue: DetailModel(preview: preview))
    }

    private var meta: MetaItem { detail.meta }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    header
                    if case .failed(let message) = detail.state {
                        MessageView(systemImage: "exclamationmark.triangle", title: "Fiche indisponible", message: message,
                                    actionTitle: "Réessayer") { detail.load(app: app) }
                            .padding(.horizontal, Theme.horizontalMargin)
                    }
                    panel
                }
                .padding(.bottom, 70)
            }
            .scrollClipDisabled()
        }
        .focusScope(focusNamespace)
        .ignoresSafeArea(edges: .top)
        .task { detail.load(app: app) }
        .onChange(of: app.libraryRevision) { _, _ in
            Task { await detail.refreshLibrary(app: app) }
        }
    }

    // MARK: Fond : l'image du contenu teinte tout l'écran

    private var backdrop: some View {
        ZStack {
            RemoteImage(url: meta.background ?? meta.poster, maxPixel: 1920,
                        placeholder: { Color.clear }, onLoaded: { ambient.update(from: $0) })
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

            Button {
                detail.toggleLibrary(app: app)
            } label: {
                Image(systemName: detail.isInLibrary ? "checkmark" : "plus")
            }
            .buttonStyle(CircleButtonStyle())
            .accessibilityLabel(Text(detail.isInLibrary ? "Retirer de ma liste" : "Ajouter à ma liste"))
            .accessibilityIdentifier("detail.library")

            if !detail.isSeries {
                let watched = detail.libraryItem?.isWatched ?? false
                Button {
                    detail.setWatched(!watched, video: nil, app: app)
                } label: {
                    Image(systemName: watched ? "eye.fill" : "eye")
                }
                .buttonStyle(CircleButtonStyle())
                .accessibilityLabel(Text(watched ? "Marquer comme non vu" : "Marquer comme vu"))
            }
        }
    }

    private func sourcesRoute(videoID: String, video: MetaVideo?, start: TimeInterval?) -> SourcesRoute {
        SourcesRoute(meta: meta, videoID: videoID, video: video, startPosition: start, autoPlay: app.settings.sources.autoPlay)
    }

    // MARK: Panneau de verre : épisodes (série) ou générique (film)

    @ViewBuilder private var panel: some View {
        if detail.isSeries {
            VStack(alignment: .leading, spacing: 24) {
                if meta.videos.isEmpty {
                    if detail.state == .loading {
                        ShimmerBlock().frame(height: 280)
                    } else {
                        Text("Aucun épisode n'est listé pour cette série.")
                            .font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(meta.seasons, id: \.self) { season in
                                Button {
                                    detail.selectedSeason = season
                                } label: {
                                    Text(season == 0 ? "Bonus" : "Saison \(season)")
                                }
                                .buttonStyle(PillButtonStyle(selected: season == (detail.selectedSeason ?? meta.seasons.first)))
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                    }
                    .scrollClipDisabled()
                    .focusSection()

                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 34) {
                            ForEach(detail.episodesInSelectedSeason) { video in
                                EpisodeCard(video: video,
                                            isWatched: detail.watched.contains(video.id),
                                            progress: detail.progress(for: video),
                                            route: .sources(sourcesRoute(videoID: video.id, video: video,
                                                                         start: video.id == detail.targetVideo?.id ? detail.resumePosition : nil)),
                                            onToggleWatched: { watched in detail.setWatched(watched, video: video, app: app) })
                            }
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 6)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            }
            .padding(34)
            .background(GlassPanel(cornerRadius: 40))
            .padding(.horizontal, 70)
        } else {
            credits
        }
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

struct EpisodeCard: View {
    let video: MetaVideo
    let isWatched: Bool
    let progress: Double?
    let route: Route
    let onToggleWatched: (Bool) -> Void
    @FocusState private var focused: Bool

    private let width: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: route) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: video.thumbnail, maxPixel: 840) {
                        ZStack {
                            Theme.surfaceRaised
                            Image(systemName: "play.rectangle").font(.system(size: 54)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipped()
                    if let progress {
                        ProgressBar(value: progress).frame(height: 6).padding(12)
                    }
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.accent, .black)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    if !video.isReleased() {
                        Badge(text: "À venir", tint: Theme.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(GlassCardButtonStyle(cornerRadius: 20))
            .focused($focused)
            .contextMenu {
                Button(isWatched ? "Marquer comme non vu" : "Marquer comme vu") { onToggleWatched(!isWatched) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(focused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if let overview = video.overview {
                    Text(overview).font(.system(size: 21)).foregroundStyle(Theme.textTertiary).lineLimit(focused ? 4 : 2)
                }
                if let released = video.released {
                    Text(released.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 19)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: width, alignment: .leading)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }

    private var title: String {
        let number = video.episode.map { "\($0). " } ?? ""
        return number + (video.title.isEmpty ? "Épisode" : video.title)
    }
}

enum TimeFormat {
    /// « 1:02:03 » ou « 12:34 ».
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
