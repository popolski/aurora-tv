import SwiftUI
import LanterneCore

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var sendURL = ""
    @State private var sendResult: String?
    @State private var footprint: Int = 0

    var body: some View {
        List {
            Section {
                ForEach(LocalTestMedia.all) { media in
                    Button {
                        play(media)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(media.title)
                            Text(media.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("test.\(media.id)")
                }
            } header: {
                Text("Tester le lecteur")
            } footer: {
                Text("Clips embarqués de 20 s : horodatage et mire mobile (l'image doit bouger), flash blanc en haut à droite synchronisé avec un bip chaque seconde (synchronisation audio/vidéo). Ouvrez Informations (▼) pendant la lecture pour voir les jalons de démarrage.")
            }

            Section {
                NavigationLink("Afficher les journaux") { LogsView() }
                TextField("http://192.168.1.10:8765/logs", text: $sendURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                Button("Envoyer les journaux à cette adresse") { send() }
                    .disabled(sendURL.isEmpty)
                if let sendResult { Text(sendResult).foregroundStyle(.secondary) }
            } header: {
                Text("Journaux")
            } footer: {
                Text("Les journaux sont expurgés (jetons, mots de passe, clés d'addons). L'envoi fait un POST texte vers l'adresse saisie, par exemple le récepteur fourni dans scripts/log-receiver.py sur votre NAS.")
            }

            Section("Stockage") {
                InfoRow(label: "Réglages et progression (persistant)", value: ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .file))
                Button("Vider les caches (images, réponses d'addons)") {
                    Task {
                        await ImageLoader.shared.clearMemory()
                        await app.addonClient.clearCache()
                        URLCache.shared.removeAllCachedResponses()
                    }
                }
            }

            Section("Version") {
                InfoRow(label: "Application", value: AppInfo.versionString)
                InfoRow(label: "Moteur de lecture", value: app.settings.playback.engine.label)
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear {
            footprint = (app.defaults as? UserDefaultsStore)?.approximateFootprint() ?? 0
        }
    }

    private func play(_ media: LocalTestMedia) {
        let meta = MetaItem(id: "lanterne:test:\(media.id)", type: ContentType.movie, name: "Test du lecteur")
        app.play(PlaybackContext(meta: meta, videoID: meta.id, video: nil, source: nil, localTest: media, startPosition: nil))
    }

    private func send() {
        guard let url = URL(string: sendURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            sendResult = "Adresse invalide."
            return
        }
        let text = LogSetup.fileSink?.contents() ?? LogStore.shared.exportText()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("# \(AppInfo.versionString)\n" + text).utf8)
        request.timeoutInterval = 20
        sendResult = "Envoi…"
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                sendResult = (200..<300).contains(status) ? "Journaux envoyés (\(text.utf8.count / 1024) Ko)." : "Réponse HTTP \(status)."
            } catch {
                sendResult = "Échec : \(error.localizedDescription)"
            }
        }
    }
}

struct LogsView: View {
    @State private var entries: [LogEntry] = []
    @State private var minimum: LogLevel = .info

    private var chunks: [[LogEntry]] {
        stride(from: 0, to: entries.count, by: 12).map { Array(entries[$0..<min($0 + 12, entries.count)]) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    ForEach([LogLevel.debug, .info, .warning, .error], id: \.self) { level in
                        Button(level.label) { minimum = level; reload() }
                            .buttonStyle(PillButtonStyle(prominent: minimum == level, selected: minimum == level))
                    }
                    Button("Actualiser") { reload() }.buttonStyle(PillButtonStyle())
                    Button("Effacer") { LogStore.shared.clear(); reload() }.buttonStyle(PillButtonStyle())
                }
                .focusSection()
                if entries.isEmpty {
                    Text("Aucune entrée.").foregroundStyle(Theme.textTertiary)
                }
                // Blocs focalisables : permettent de faire défiler à la télécommande.
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(chunk) { entry in
                                Text(entry.formatted)
                                    .font(.system(size: 18, design: .monospaced))
                                    .foregroundStyle(color(entry.level))
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .padding(Theme.horizontalMargin)
        }
        .onAppear { reload() }
    }

    private func reload() {
        entries = Array(LogStore.shared.snapshot(minimumLevel: minimum).suffix(600).reversed())
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: Theme.textTertiary
        case .info: Theme.textSecondary
        case .warning: Theme.accent
        case .error: Theme.danger
        }
    }
}
