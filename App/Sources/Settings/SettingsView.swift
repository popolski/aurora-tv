import SwiftUI
import LanterneCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    SettingsRow(icon: "play.tv", title: "Tester le lecteur", value: "Clips de test, journaux")
                }
                .accessibilityIdentifier("settings.diagnostics")
            } footer: {
                Text("À faire en premier sur une nouvelle installation : vérifie l'image, le son, la synchronisation et les sous-titres sans dépendre d'aucun addon.")
            }
            Section("Compte et contenus") {
                NavigationLink {
                    AccountView()
                } label: {
                    SettingsRow(icon: "person.crop.circle", title: "Compte Stremio",
                                value: app.session.map { $0.user.email.isEmpty ? "Connecté" : $0.user.email } ?? "Non connecté")
                }
                .accessibilityIdentifier("settings.account")
                NavigationLink {
                    AddonsView()
                } label: {
                    SettingsRow(icon: "puzzlepiece.extension", title: "Addons", value: "\(app.addons.count) actif(s)")
                }
                NavigationLink {
                    HomeSettingsView()
                } label: {
                    SettingsRow(icon: "house", title: "Accueil", value: "Catalogues affichés")
                }
            }
            Section("Lecture") {
                NavigationLink { PlaybackSettingsView() } label: {
                    SettingsRow(icon: "play.rectangle", title: "Lecteur", value: app.settings.playback.engine.label)
                }
                NavigationLink { LanguageSettingsView() } label: {
                    SettingsRow(icon: "captions.bubble", title: "Langues et sous-titres",
                                value: "\(LanguageCode.displayName(app.settings.languages.preferredAudio)) · \(app.settings.languages.subtitleMode.label)")
                }
                NavigationLink { SourceSettingsView() } label: {
                    SettingsRow(icon: "list.bullet.rectangle", title: "Sources", value: app.settings.sources.sortMode.label)
                }
                NavigationLink { TrailerSettingsView() } label: {
                    SettingsRow(icon: "film.stack", title: "Bandes-annonces",
                                value: app.settings.trailers.server == nil ? "Désactivées" : "Service du NAS")
                }
                .accessibilityIdentifier("settings.trailers")
            }
            Section("Assistance") {
                NavigationLink { DiagnosticsView() } label: {
                    SettingsRow(icon: "stethoscope", title: "Diagnostics", value: "Journaux, stockage, version")
                }
                NavigationLink { AboutView() } label: {
                    SettingsRow(icon: "info.circle", title: "À propos", value: AppInfo.versionString)
                }
            }
        }
        .navigationTitle("Réglages")
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: icon).frame(width: 44)
            Text(title)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Ligne d'information non interactive : libellé à gauche, valeur à droite, sur une seule ligne.
/// (`LabeledContent` s'affichait décalé d'une ligne dans les listes tvOS.)
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 30) {
            Text(label)
            Spacer(minLength: 20)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Lecteur

struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var serverDraft = ""

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Picker("Moteur", selection: $app.settings.playback.engine) {
                    ForEach(PlayerEngineChoice.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Automatique : AetherEngine lit MKV, HEVC, HDR10/Dolby Vision, DTS/TrueHD et les sous-titres texte et image. Le lecteur système (AVPlayer) ne lit que HLS et MP4 ; il sert au diagnostic.")
            }
            Section {
                Toggle("Adapter l'écran au contenu", isOn: $app.settings.playback.matchContent)
                Toggle("Mon téléviseur affiche le Dolby Vision", isOn: $app.settings.playback.panelSupportsDolbyVision)
            } footer: {
                Text("Fréquence d'images et plage dynamique : activez aussi Réglages tvOS › Vidéo et audio › Adapter le contenu. N'activez l'option Dolby Vision que si votre téléviseur le prend réellement en charge.")
            }
            Section {
                Picker("Saut gauche/droite", selection: $app.settings.playback.skipInterval) {
                    ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Toggle("Épisode suivant automatique", isOn: $app.settings.playback.autoPlayNextEpisode)
                Picker("« Êtes-vous toujours là ? »", selection: $app.settings.playback.stillWatchingAfter) {
                    Text("Jamais").tag(0)
                    ForEach([2, 3, 4, 5], id: \.self) { Text("Après \($0) épisodes").tag($0) }
                }
                Picker("Encart « Épisode suivant »", selection: $app.settings.playback.nextEpisodeLeadTime) {
                    ForEach([30.0, 45, 60, 90, 120, 180], id: \.self) { Text("\(Int($0)) s avant la fin").tag($0) }
                }
            }
            Section {
                InfoRow(label: "Mode nuit", value: "Réduire les sons forts")
                    .focusable()
                InfoRow(label: "Dialogues plus clairs", value: "Améliorer les dialogues")
                    .focusable()
            } header: {
                Text("Son : mode nuit et dialogues")
            } footer: {
                Text("Ces deux réglages sont ceux de l'Apple TV, appliqués à toutes les apps : Réglages de l'Apple TV › Vidéo et audio. « Réduire les sons forts » atténue les explosions et garde les voix audibles à faible volume ; « Améliorer les dialogues » fait ressortir les voix (selon la sortie audio). Le moteur de lecture d'Aurora ne permet pas de les reproduire lui-même.")
            }
            Section {
                Toggle("Bouton « Passer l'intro »", isOn: $app.settings.playback.skipButtons)
                Toggle("Passer l'intro et le résumé automatiquement", isOn: $app.settings.playback.autoSkipIntro)
            } footer: {
                Text("Minutages communautaires de TheIntroDB (theintrodb.org) et, pour les animés de Kitsu, d'AniSkip, quand ils existent pour le film ou l'épisode. Ils peuvent être décalés selon la version du fichier : le bouton laisse le choix (OK pour passer, Menu pour regarder). Pour une série, l'encart « Épisode suivant » apparaît dès le début du générique s'il est connu.")
            }
            Section {
                TextField("http://192.168.1.20:11470", text: $serverDraft)
                    .textContentType(.URL)
                    .onSubmit { app.settings.playback.streamingServerURL = serverDraft.trimmingCharacters(in: .whitespaces) }
                if !app.settings.playback.streamingServerURL.isEmpty {
                    Button("Retirer le serveur", role: .destructive) {
                        app.settings.playback.streamingServerURL = ""
                        serverDraft = ""
                    }
                }
            } header: {
                Text("Serveur de streaming (torrents) : \(app.settings.playback.streamingServerURL.isEmpty ? "aucun" : app.settings.playback.streamingServerURL)")
            } footer: {
                Text("Saisissez l'adresse puis validez. Aurora ne lit pas les torrents elle-même. Les sources torrent ne sont lisibles que via un serveur de streaming Stremio que vous hébergez (par exemple un conteneur Docker sur votre NAS). Aurora ne fournit ni ne recommande aucun contenu.")
            }
        }
        .navigationTitle("Lecteur")
        .onAppear { serverDraft = app.settings.playback.streamingServerURL }
    }
}

// MARK: - Bandes-annonces

struct TrailerSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var serverDraft = ""
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                TextField("http://192.168.1.20:8787", text: $serverDraft)
                    .textContentType(.URL)
                    .onSubmit { save() }
                if app.settings.trailers.server != nil {
                    Button(checking ? "Test en cours…" : "Tester la connexion") { check() }
                        .disabled(checking)
                    Button("Retirer le service", role: .destructive) {
                        app.settings.trailers.serverURL = ""
                        serverDraft = ""
                        checkResult = nil
                    }
                }
                if let checkResult {
                    Text(checkResult).foregroundStyle(.secondary)
                }
            } header: {
                Text("Service aurora-trailers : \(app.settings.trailers.serverURL.isEmpty ? "aucun" : app.settings.trailers.serverURL)")
            } footer: {
                Text("Les addons ne donnent que des liens YouTube, que l'Apple TV ne lit pas. Le service aurora-trailers, installé sur votre NAS (dossier trailer-server du projet), prépare les bandes-annonces et les sert sur le réseau local. Saisissez son adresse puis validez.")
            }
            Section {
                Toggle("Sur les fiches", isOn: $app.settings.trailers.onDetail)
                Toggle("Dans le bandeau de l'accueil", isOn: $app.settings.trailers.onHome)
                Picker("Lancement après", selection: $app.settings.trailers.delay) {
                    ForEach([2.0, 3, 5, 8], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
            } footer: {
                Text("Toujours sans le son. L'image s'affiche d'abord ; la bande-annonce apparaît en fondu quand elle est prête. La première fois, le NAS met quelques secondes à la préparer.")
            }
        }
        .navigationTitle("Bandes-annonces")
        .onAppear { serverDraft = app.settings.trailers.serverURL }
    }

    private func save() {
        app.settings.trailers.serverURL = serverDraft.trimmingCharacters(in: .whitespaces)
        checkResult = nil
        if app.settings.trailers.server != nil { check() }
        else if !serverDraft.isEmpty { checkResult = "Adresse invalide : elle doit commencer par http:// suivi de l'adresse du NAS et du port." }
    }

    private func check() {
        guard let server = app.settings.trailers.server else { return }
        checking = true
        Task {
            let result = await TrailerService.check(server: server)
            checkResult = result
            checking = false
        }
    }
}

// MARK: - Langues

struct LanguageSettingsView: View {
    @Environment(AppModel.self) private var app
    private let languages = ["fr", "en", "es", "de", "it", "pt", "ja", "ko", "zh", "ru", "nl", "ar"]

    var body: some View {
        @Bindable var app = app
        List {
            Section("Audio") {
                Picker("Langue préférée", selection: $app.settings.languages.preferredAudio) {
                    ForEach(languages, id: \.self) { Text(LanguageCode.displayName($0)).tag($0) }
                }
                Picker("Langue secondaire", selection: $app.settings.languages.secondaryAudio) {
                    ForEach(languages, id: \.self) { Text(LanguageCode.displayName($0)).tag($0) }
                }
            }
            Section {
                Picker("Langue des sous-titres", selection: $app.settings.languages.preferredSubtitle) {
                    ForEach(languages, id: \.self) { Text(LanguageCode.displayName($0)).tag($0) }
                }
                Picker("Activation automatique", selection: $app.settings.languages.subtitleMode) {
                    ForEach(SubtitleMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Sous-titres")
            } footer: {
                Text("« Si l'audio est en VO » : les sous-titres s'activent quand la piste audio retenue n'est pas dans la langue des sous-titres ; sinon seuls les sous-titres « forcés » sont affichés.")
            }
            Section("Apparence") {
                Picker("Taille", selection: $app.settings.languages.subtitleSize) {
                    ForEach(SubtitleSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("Position", selection: $app.settings.languages.subtitleVerticalOffset) {
                    Text("Bas").tag(0.04)
                    Text("Légèrement relevée").tag(0.06)
                    Text("Relevée").tag(0.12)
                    Text("Haute").tag(0.2)
                }
                Toggle("Fond sombre", isOn: $app.settings.languages.subtitleBackground)
            }
        }
        .navigationTitle("Langues et sous-titres")
    }
}

// MARK: - Sources

struct SourceSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List {
            Section("Tri") {
                Picker("Ordre", selection: $app.settings.sources.sortMode) {
                    ForEach(SourceSortMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Langue", selection: $app.settings.sources.language) {
                    ForEach(SourceLanguagePreference.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Privilégier les sources compatibles", isOn: $app.settings.sources.preferCompatible)
                Toggle("Privilégier la source déjà utilisée", isOn: $app.settings.sources.preferPreviouslyUsed)
            }
            Section {
                Toggle("Masquer les CAM/TS", isOn: $app.settings.sources.hideCam)
                Toggle("Masquer les sources non lisibles", isOn: $app.settings.sources.hideUnplayable)
                Toggle("Lancer automatiquement la meilleure source", isOn: $app.settings.sources.autoPlay)
            } header: {
                Text("Filtres et automatisme")
            } footer: {
                Text("Résolution, codecs, HDR, langue et taille sont lus dans les noms fournis par les addons : ce sont des informations annoncées, non vérifiées. Les caractéristiques réelles sont affichées pendant la lecture (Informations).")
            }
        }
        .navigationTitle("Sources")
    }
}

// MARK: - Accueil

struct HomeSettingsView: View {
    @Environment(AppModel.self) private var app

    private var refs: [CatalogRef] {
        let all = app.aggregator.browsableCatalogs(app.addons)
        let order = app.settings.homeCatalogOrder
        guard !order.isEmpty else { return all }
        return all.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.id) ?? 10_000 + a.offset) < (order.firstIndex(of: b.element.id) ?? 10_000 + b.offset)
        }.map(\.element)
    }

    var body: some View {
        @Bindable var app = app
        List {
            Section {
                Picker("Films déjà vus", selection: $app.settings.watchedTitles) {
                    ForEach(WatchedTitlesDisplay.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Dans les catalogues de l'accueil, de Films, de Séries et dans la recherche. « Continuer à regarder » et « Ma liste » ne changent pas.")
            }
            Section {
                Toggle("Le bandeau défile tout seul", isOn: $app.settings.homeBillboardRotation)
            } footer: {
                Text("Quand vous ne touchez à rien, le bandeau du haut passe au titre suivant à la fin de l'extrait de bande-annonce (ou après 15 s sans bande-annonce). Il revient au titre sélectionné dès que vous bougez.")
            }
            Section {
                ForEach(refs) { ref in
                    let hidden = app.settings.hiddenHomeCatalogs.contains(ref.id)
                    HStack {
                        Button {
                            toggle(ref)
                        } label: {
                            HStack {
                                Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(hidden ? Color.secondary : Theme.accent)
                                VStack(alignment: .leading) {
                                    Text("\(ref.title) · \(ref.typeLabel)")
                                    Text(ref.addon.manifest.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button { move(ref, by: -1) } label: { Image(systemName: "chevron.up") }
                        Button { move(ref, by: 1) } label: { Image(systemName: "chevron.down") }
                    }
                }
            } footer: {
                Text("Choisissez les catalogues de l'accueil et leur ordre.")
            }
        }
        .navigationTitle("Accueil")
    }

    private func toggle(_ ref: CatalogRef) {
        if let i = app.settings.hiddenHomeCatalogs.firstIndex(of: ref.id) {
            app.settings.hiddenHomeCatalogs.remove(at: i)
        } else {
            app.settings.hiddenHomeCatalogs.append(ref.id)
        }
    }

    private func move(_ ref: CatalogRef, by offset: Int) {
        var ids = refs.map(\.id)
        guard let i = ids.firstIndex(of: ref.id) else { return }
        let j = max(0, min(ids.count - 1, i + offset))
        ids.swapAt(i, j)
        app.settings.homeCatalogOrder = ids
    }
}

// MARK: - À propos

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(AppInfo.versionString).font(.screenTitle)
                Text("Client Stremio natif pour Apple TV. Aurora n'héberge, ne fournit ni ne recommande aucun contenu : elle affiche ce que renvoient les addons que vous installez.")
                Text("Compte Stremio : Aurora utilise l'API de compte non officielle de Stremio (celle des applications officielles). Elle peut changer sans préavis.")
                Text("Lecture : AetherEngine (LGPL-3.0 avec exception App Store) et FFmpeg (LGPL), liés dynamiquement.")
                Text("Médias de test : mires générées avec FFmpeg, libres de droits.")
            }
            .font(.meta)
            .foregroundStyle(Theme.textSecondary)
            .padding(Theme.horizontalMargin)
            .focusable()
        }
        .navigationTitle("À propos")
    }
}
