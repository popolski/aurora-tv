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
                Picker("Encart « Épisode suivant »", selection: $app.settings.playback.nextEpisodeLeadTime) {
                    ForEach([30.0, 45, 60, 90, 120, 180], id: \.self) { Text("\(Int($0)) s avant la fin").tag($0) }
                }
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
        List {
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
