import SwiftUI
import LanterneCore

/// Interface superposée au lecteur : barre de progression, états de
/// démarrage/erreur/fin, panneau de pistes et d'informations.
struct PlayerOverlay: View {
    let session: PlayerSession

    var body: some View {
        ZStack {
            if session.chromeVisible || session.scrubTarget != nil {
                ChromeView(session: session)
                    .transition(.opacity)
            }
            statusLayer
            if session.stillWatchingPrompt {
                StillWatchingCard(session: session)
                    .transition(.opacity)
            } else if let panel = session.panel {
                PlayerPanel(session: session, initial: panel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let next = session.upNext {
                UpNextCard(session: session, next: next)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 80)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let skip = session.activeSkip {
                SkipPrompt(segment: skip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90)
                    .padding(.bottom, session.chromeVisible ? 190 : 90)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if session.sleepFade > 0 {
                SleepFadeLayer(progress: session.sleepFade)
            }
            // Jalon atteint, exposé aux tests d'interface (quasi invisible).
            Text(session.milestones.highest?.label ?? "aucun")
                .font(.system(size: 2))
                .opacity(0.02)
                .accessibilityIdentifier("player.milestone")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.25), value: session.chromeVisible)
        .animation(.easeInOut(duration: 0.25), value: session.panel)
        .animation(.easeInOut(duration: 0.3), value: session.upNext?.id)
        .animation(.easeInOut(duration: 0.3), value: session.activeSkip)
        .animation(.easeInOut(duration: 0.3), value: session.stillWatchingPrompt)
        .animation(.linear(duration: 0.25), value: session.sleepFade)
        .ignoresSafeArea()
        // Menu dans la surcouche : revient au film (panneau, encart) au lieu de fermer le lecteur.
        .onExitCommand { session.handleOverlayExit() }
    }

    @ViewBuilder private var statusLayer: some View {
        switch session.status {
        case .starting(let message):
            StartingView(message: message, session: session)
        case .active:
            if session.snapshot.phase == .buffering {
                ProgressView().scaleEffect(1.6).tint(Theme.accent)
            }
        case .noPicture:
            ProblemCard(
                icon: "eye.slash",
                title: "Aucune image affichée",
                message: "Le moteur avance dans la vidéo mais ne signale aucune image prête à l'affichage. Cette source n'est probablement pas lisible correctement sur l'Apple TV.",
                session: session, showWait: true)
        case .failed(let message):
            ProblemCard(icon: "exclamationmark.triangle", title: "Lecture impossible", message: message,
                        session: session, showWait: false)
        case .ended:
            if !session.stillWatchingPrompt { EndCard(session: session) }
        }
    }
}

// MARK: - Barre de transport

private struct ChromeView: View {
    let session: PlayerSession

    var body: some View {
        let s = session.snapshot
        VStack(alignment: .leading, spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title).font(.system(size: 44, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        if let line = session.subtitleLine {
                            Text(line).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 90).padding(.top, 60)
                }
                .overlay(alignment: .topTrailing) {
                    if let status = session.sleepTimerStatus {
                        Label(status, systemImage: "moon.zzz.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(.trailing, 90).padding(.top, 60)
                    }
                }
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 18) {
                        TimelineBar(position: session.displayedPosition, duration: s.duration, buffered: s.buffered,
                                    isScrubbing: session.scrubTarget != nil)
                            .frame(height: 12)
                        HStack {
                            Image(systemName: s.phase == .playing ? "pause.fill" : "play.fill")
                            Text(TimeFormat.clock(session.displayedPosition))
                            Spacer()
                            if let rate = session.shuttleRate {
                                Text("\(rate > 0 ? "▶▶" : "◀◀") ×\(Int(abs(rate))) · Relâchez pour reprendre la lecture")
                                    .foregroundStyle(Theme.accent)
                                    .contentTransition(.numericText())
                            } else if session.scrubTarget != nil {
                                Text("Cliquez pour aller à \(TimeFormat.clock(session.displayedPosition)) · Menu pour annuler")
                                    .foregroundStyle(Theme.accent)
                            } else {
                                Text("▼ Audio et sous-titres").foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            if s.duration > 0 {
                                let remaining = max(0, s.duration - session.displayedPosition)
                                Text("−\(TimeFormat.clock(remaining)) · Fin à \(TimeFormat.endTime(after: remaining))")
                            } else {
                                Text("--:--")
                            }
                        }
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 90).padding(.bottom, 60)
                }
        }
        .allowsHitTesting(false)
    }
}

private struct TimelineBar: View {
    let position: TimeInterval
    let duration: TimeInterval
    let buffered: TimeInterval
    let isScrubbing: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = duration > 0 ? min(1, max(0, position / duration)) : 0
            let b = duration > 0 ? min(1, max(0, buffered / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white.opacity(0.35)).frame(width: w * b)
                Capsule().fill(Theme.accent).frame(width: max(12, w * p))
                Circle().fill(.white)
                    .frame(width: isScrubbing ? 30 : 20, height: isScrubbing ? 30 : 20)
                    .offset(x: w * p - (isScrubbing ? 15 : 10))
            }
        }
    }
}

// MARK: - États

private struct StartingView: View {
    let message: String
    let session: PlayerSession

    var body: some View {
        VStack(spacing: 26) {
            ProgressView().scaleEffect(1.8).tint(Theme.accent)
            Text(message).font(.sectionTitle).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PlaybackMilestone.allCases, id: \.self) { m in
                    let reached = session.milestones.reached[m] != nil
                    HStack(spacing: 12) {
                        Image(systemName: reached ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(reached ? Theme.success : Theme.textTertiary)
                        Text(m.label).foregroundStyle(reached ? Theme.textSecondary : Theme.textTertiary)
                    }
                    .font(.system(size: 22))
                }
            }
            Text("Menu pour annuler").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
        }
        .padding(50)
        .background(RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.65)))
    }
}

private struct ProblemCard: View {
    let icon: String
    let title: String
    let message: String
    let session: PlayerSession
    let showWait: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon).font(.system(size: 60)).foregroundStyle(Theme.accent)
            Text(title).font(.sectionTitle).foregroundStyle(.white)
            Text(message).font(.meta).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 1000)
            Text("Moteur : \(session.engineName) · étape atteinte : \(session.milestones.highest?.label ?? "aucune")")
                .font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 22) {
                if showWait {
                    Button("Continuer quand même") { session.acknowledgeNoPicture() }.buttonStyle(PillButtonStyle())
                } else {
                    Button("Réessayer") { session.retry() }.buttonStyle(PillButtonStyle(prominent: true))
                }
                if !session.playableAlternatives.isEmpty {
                    Button("Autre source…") { session.panel = .sources }.buttonStyle(PillButtonStyle())
                }
                Button(session.engine is SystemPlaybackEngine ? "Réessayer avec AetherEngine" : "Réessayer avec AVPlayer") {
                    session.retryWithOtherEngine()
                }
                .buttonStyle(PillButtonStyle())
                Button("Fermer") { session.close() }.buttonStyle(PillButtonStyle())
            }
            .focusSection()
        }
        .padding(60)
        .background(RoundedRectangle(cornerRadius: 30).fill(.black.opacity(0.8)))
        .padding(80)
    }
}

private struct EndCard: View {
    let session: PlayerSession

    var body: some View {
        VStack(spacing: 24) {
            if let next = session.nextEpisode {
                Text("Épisode suivant").font(.meta).foregroundStyle(Theme.textSecondary)
                Text([next.episodeCode, next.title.isEmpty ? nil : next.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.sectionTitle).foregroundStyle(.white)
                if let n = session.nextCountdown {
                    Text("Lecture dans \(n) s").font(.meta).foregroundStyle(Theme.accent)
                }
                HStack(spacing: 22) {
                    Button("Lire maintenant") { session.playNext() }.buttonStyle(PillButtonStyle(prominent: true))
                    if session.nextCountdown != nil {
                        Button("Annuler") { session.cancelCountdown() }.buttonStyle(PillButtonStyle())
                    }
                    Button("Fermer") { session.close() }.buttonStyle(PillButtonStyle())
                }
                .focusSection()
            } else {
                Text("Lecture terminée").font(.sectionTitle).foregroundStyle(.white)
                Button("Fermer") { session.close() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(60)
        .background(RoundedRectangle(cornerRadius: 30).fill(.black.opacity(0.8)))
    }
}

// MARK: - Mise en veille, « toujours là ? »

private struct SleepFadeLayer: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(min(1, progress * 1.1))
            VStack(spacing: 16) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 54))
                Text("Bonne nuit").font(.sectionTitle)
                Text("Appuyez sur une touche pour continuer à regarder")
                    .font(.meta).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(.white)
            .opacity(min(1, progress * 3))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct StillWatchingCard: View {
    let session: PlayerSession
    @FocusState private var continueFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 26) {
                Text("Êtes-vous toujours là ?").font(.sectionTitle).foregroundStyle(.white)
                if let next = session.nextEpisode {
                    Text("Épisode suivant : " + [next.episodeCode, next.title.isEmpty ? nil : next.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.meta).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 22) {
                    Button("Continuer à regarder") { session.continueWatching() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .focused($continueFocused)
                        .accessibilityIdentifier("player.stillWatching.continue")
                    Button("Arrêter") { session.close() }
                        .buttonStyle(PillButtonStyle())
                }
                .focusSection()
            }
            .padding(60)
            .background(RoundedRectangle(cornerRadius: 30).fill(.black.opacity(0.8)))
        }
        .ignoresSafeArea()
        .onAppear { continueFocused = true }
    }
}

// MARK: - Épisode suivant (pendant le générique)

/// « Passer l'intro » : bouton blanc en bas à droite ; le clic central de la
/// télécommande l'actionne (le lecteur garde le focus), Menu le masque.
private struct SkipPrompt: View {
    let segment: SkipSegment

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "forward.end.fill")
            Text(segment.actionLabel)
        }
        .font(.manrope(26, .heavy))
        .foregroundStyle(Theme.onFocus)
        .padding(.horizontal, 34)
        .padding(.vertical, 20)
        .background(Capsule().fill(Color.white))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .overlay(alignment: .bottom) {
            Text("OK pour passer · Menu pour regarder")
                .font(.manrope(17, .bold))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .offset(y: 36)
        }
        .accessibilityIdentifier("player.skip")
    }
}

private struct UpNextCard: View {
    let session: PlayerSession
    let next: MetaVideo
    @FocusState private var playFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            RemoteImage(url: next.thumbnail, maxPixel: 560) {
                ZStack {
                    Theme.surfaceRaised
                    Image(systemName: "play.rectangle").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 280, height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text("Épisode suivant").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                Text([next.episodeCode, next.title.isEmpty ? nil : next.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 16) {
                    Button {
                        session.playNext()
                    } label: {
                        Label(session.nextCountdown.map { "Lire (\($0) s)" } ?? "Lire", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .focused($playFocused)
                    Button("Générique") { session.dismissUpNext() }
                        .buttonStyle(PillButtonStyle())
                }
                .focusSection()
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.45)))
        )
        .onAppear { playFocused = true }
    }
}

// MARK: - Panneau

private struct PlayerPanel: View {
    let session: PlayerSession
    @State private var tab: PlayerSession.Panel

    init(session: PlayerSession, initial: PlayerSession.Panel) {
        self.session = session
        _tab = State(initialValue: initial)
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    tabButton("Audio et sous-titres", .tracks, alsoSelected: .subtitleSync)
                    if !session.playableAlternatives.isEmpty { tabButton("Sources", .sources) }
                    tabButton("Minuteur", .timer)
                    tabButton("Informations", .info)
                }
                .focusSection()
                ScrollView(.vertical) {
                    Group {
                        switch tab {
                        case .tracks: TracksPanel(session: session) { tab = .subtitleSync }
                        case .subtitleSync: SubtitleSyncPanel(session: session) { tab = .tracks }
                        case .sources: SourcesPanel(session: session)
                        case .timer: SleepTimerPanel(session: session)
                        case .info: InfoPanel(session: session)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 520)
            }
            .padding(50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black.opacity(0.45)))
            )
            .padding(.horizontal, 60)
            .padding(.bottom, 40)
        }
        .onChange(of: tab) { _, new in
            if new == .subtitleSync { session.beginSubtitleSync() } else { session.endSubtitleSync() }
        }
        .onDisappear { session.endSubtitleSync() }
    }

    private func tabButton(_ title: String, _ value: PlayerSession.Panel, alsoSelected: PlayerSession.Panel? = nil) -> some View {
        let on = tab == value || (alsoSelected != nil && tab == alsoSelected)
        return Button(title) { tab = value }
            .buttonStyle(PillButtonStyle(prominent: on, selected: on))
    }
}

private struct TracksPanel: View {
    let session: PlayerSession
    let openSync: () -> Void

    var body: some View {
        let s = session.snapshot
        HStack(alignment: .top, spacing: 50) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Audio").font(.cardTitle).foregroundStyle(Theme.textSecondary)
                if s.audioTracks.isEmpty {
                    Text("Aucune piste signalée").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(s.audioTracks) { track in
                    TrackButton(title: track.displayName, selected: track.id == s.selectedAudioID) {
                        session.selectAudio(track.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            VStack(alignment: .leading, spacing: 12) {
                Text("Sous-titres").font(.cardTitle).foregroundStyle(Theme.textSecondary)
                TrackButton(title: "Désactivés", selected: s.selectedSubtitleID == nil) { session.selectSubtitle(nil) }
                ForEach(s.subtitleTracks) { track in
                    TrackButton(title: track.displayName, selected: track.id == s.selectedSubtitleID) {
                        session.selectSubtitle(track.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            VStack(alignment: .leading, spacing: 12) {
                Text("Décalage").font(.cardTitle).foregroundStyle(Theme.textSecondary)
                Text(String(format: "%+.2f s", session.subtitleDelay)).font(.sectionTitle).foregroundStyle(.white)
                HStack(spacing: 14) {
                    Button("−0,25 s") { session.adjustSubtitleDelay(by: -0.25) }.buttonStyle(PillButtonStyle())
                    Button("+0,25 s") { session.adjustSubtitleDelay(by: 0.25) }.buttonStyle(PillButtonStyle())
                }
                if session.engine.rendersSubtitlesItself {
                    Text("Non applicable avec le lecteur système.").font(.system(size: 19)).foregroundStyle(Theme.textTertiary)
                } else if session.canSyncSubtitles {
                    Button(action: openSync) {
                        Label("Choisir la réplique entendue…", systemImage: "text.bubble")
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .accessibilityIdentifier("player.syncSubtitles")
                }
            }
            .focusSection()
        }
    }
}

/// Synchronisation par réplique : la lecture est en pause ; la réplique
/// choisie s'affichera à cet instant (le décalage est calculé et conservé).
private struct SubtitleSyncPanel: View {
    let session: PlayerSession
    let back: () -> Void
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Button(action: back) { Label("Retour", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle(compact: true))
                Text("Lecture en pause. Choisissez la réplique que vous venez d'entendre : elle s'affichera à cet instant.")
                    .font(.meta).foregroundStyle(Theme.textSecondary)
            }
            .focusSection()
            if let window = session.subtitleSync {
                if window.lines.isEmpty {
                    Text("Aucune réplique disponible autour de ce moment (piste en image, ou passage sans dialogue). Utilisez les boutons ±0,25 s.")
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                        .focusable()
                } else {
                    let current = SubtitleSync.current(in: window.lines, now: window.now, delay: session.subtitleDelay)
                    ForEach(window.lines) { line in
                        Button { session.applySubtitleSync(line) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 20) {
                                Text(relative(line, window.now))
                                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(line.id == current?.id ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 150, alignment: .leading)
                                Text(line.text).font(.system(size: 24, weight: .medium)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                        .focused($focused, equals: line.id)
                    }
                    .onAppear { focused = current?.id }
                }
            } else {
                Text("Les répliques de cette piste ne sont pas disponibles.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
                    .focusable()
            }
        }
    }

    /// Moment où la réplique s'affiche avec le décalage actuel, par rapport à maintenant.
    private func relative(_ line: SubtitleSyncLine, _ now: TimeInterval) -> String {
        let delta = Int((line.start + session.subtitleDelay - now).rounded())
        if delta == 0 { return "à l'écran" }
        return delta < 0 ? "il y a \(-delta) s" : "dans \(delta) s"
    }
}

/// Minuteur de mise en veille : fondu au noir puis arrêt (progression enregistrée).
private struct SleepTimerPanel: View {
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Arrêter la lecture automatiquement. L'image s'assombrit pendant quelques secondes avant l'arrêt : appuyez sur une touche pour continuer à regarder.")
                .font(.meta).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                option("Désactivé", nil)
                option(SleepTimerChoice.endOfItem.label(isSeries: session.isSeries), .endOfItem)
                ForEach(SleepTimerChoice.durations, id: \.self) { m in
                    option(SleepTimerChoice.minutes(m).label(isSeries: session.isSeries), .minutes(m))
                }
            }
            .focusSection()
            if let status = session.sleepTimerStatus {
                Label(status, systemImage: "moon.zzz.fill").font(.meta).foregroundStyle(Theme.accent)
            }
        }
    }

    private func option(_ title: String, _ choice: SleepTimerChoice?) -> some View {
        let selected = session.sleepTimer == choice
        return Button(title) { session.setSleepTimer(choice) }
            .buttonStyle(PillButtonStyle(prominent: selected, selected: selected, compact: true))
    }
}

private struct TrackButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 24, weight: .medium))
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct SourcesPanel: View {
    let session: PlayerSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changer de source (la position est conservée)").font(.meta).foregroundStyle(Theme.textSecondary)
            ForEach(session.playableAlternatives.prefix(25)) { source in
                Button { session.switchSource(source) } label: {
                    SourceRow(source: source, isBest: false, wasUsed: false)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}

private struct InfoPanel: View {
    let session: PlayerSession

    var body: some View {
        let s = session.snapshot
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Détecté par le moteur").font(.cardTitle).foregroundStyle(Theme.textSecondary)
                infoLine("Résolution", s.detected.resolutionLabel)
                infoLine("Codec vidéo", s.detected.videoCodec)
                infoLine("Plage dynamique", s.detected.dynamicRange)
                infoLine("Images/s", s.detected.frameRate.map { String(format: "%.3f", $0) })
                infoLine("Conteneur", s.detected.container)
                infoLine("Codec audio", s.detected.audioCodec)
                ForEach(s.diagnostics) { line in infoLine(line.label, line.value) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Annoncé par l'addon").font(.cardTitle).foregroundStyle(Theme.textSecondary)
                if let t = session.context.source?.traits {
                    infoLine("Résolution", t.resolution?.label)
                    infoLine("HDR", t.hdr.isEmpty ? nil : t.hdr.map(\.label).joined(separator: ", "))
                    infoLine("Codec vidéo", t.videoCodec?.label)
                    infoLine("Audio", t.audioCodecs.isEmpty ? nil : t.audioCodecs.map(\.label).joined(separator: ", "))
                    infoLine("Taille", t.sizeLabel)
                    infoLine("Addon", session.context.source?.addonName)
                } else {
                    Text("Média de test local").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Text("Démarrage").font(.cardTitle).foregroundStyle(Theme.textSecondary).padding(.top, 16)
                ForEach(PlaybackMilestone.allCases, id: \.self) { m in
                    infoLine(m.label, session.milestones.latency(of: m).map { String(format: "+%.2f s", $0) })
                }
                infoLine("Blocages", "\(session.milestones.stallCount)")
            }
        }
        // Lignes non focalisables : un bouton invisible garantit l'accès au défilement.
        .focusable()
    }

    private func infoLine(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 16) {
            Text(label).foregroundStyle(Theme.textTertiary).frame(width: 280, alignment: .leading)
            Text(value ?? "—").foregroundStyle(.white).lineLimit(1)
        }
        .font(.system(size: 21))
    }
}

// MARK: - Sous-titres

/// Surcouche de sous-titres (texte stylé ou images PGS/DVB), non interactive.
struct SubtitleLayer: View {
    let session: PlayerSession

    var body: some View {
        GeometryReader { geo in
            let prefs = session.languagePrefs
            ZStack {
                ForEach(session.cues) { cue in
                    switch cue.body {
                    case .text(let text, let italic, let bold):
                        Text(text)
                            .font(.system(size: prefs.subtitleSize.pointSize, weight: bold ? .heavy : .semibold))
                            .italic(italic)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2, x: 0, y: 0)
                            .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 2)
                            .padding(.horizontal, prefs.subtitleBackground ? 18 : 0)
                            .padding(.vertical, prefs.subtitleBackground ? 6 : 0)
                            .background(prefs.subtitleBackground ? Color.black.opacity(0.5) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: geo.size.width * 0.85)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cue.top ? .top : .bottom)
                            .padding(.bottom, cue.top ? 0 : geo.size.height * prefs.subtitleVerticalOffset)
                            .padding(.top, cue.top ? geo.size.height * 0.06 : 0)
                    case .image(let image, let rect, let canvas):
                        let cw = canvas.width > 0 ? canvas.width : 1920
                        let ch = canvas.height > 0 ? canvas.height : 1080
                        let scale = min(geo.size.width / cw, geo.size.height / ch)
                        let ox = (geo.size.width - cw * scale) / 2
                        let oy = (geo.size.height - ch * scale) / 2
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: rect.width * scale, height: rect.height * scale)
                            .position(x: ox + rect.midX * scale, y: oy + rect.midY * scale)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
