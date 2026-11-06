import SwiftUI
import LanterneCore

/// Réglages › Sauvegarde : copie des réglages d'Aurora sur le service du NAS, et
/// restauration (après une réinstallation, ou d'un appareil à l'autre).
struct BackupSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false
    @State private var message: String?
    @State private var latest: SettingsBackup?
    @State private var pendingRestore: SettingsBackup?

    var body: some View {
        List {
            Section {
                Button(busy ? "Envoi en cours…" : "Sauvegarder les réglages sur le NAS") { Task { await save() } }
                    .disabled(busy || app.settings.trailers.server == nil)
                Button("Restaurer la dernière sauvegarde…") { Task { await prepareRestore() } }
                    .disabled(busy || app.settings.trailers.server == nil)
                if let latest {
                    InfoRow(label: "Dernière sauvegarde",
                            value: "\(latest.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(latest.device)")
                        .focusable()
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Text("Service du NAS : \(app.settings.trailers.server?.absoluteString ?? "non configuré")")
            } footer: {
                Text(app.settings.trailers.server == nil
                     ? "Indiquez d'abord l'adresse du service du NAS dans Réglages › Bandes-annonces : la sauvegarde y est déposée."
                     : "Sont sauvegardés : lecteur, langues et sous-titres, sources, accueil, bandes-annonces et carrousel. Ne le sont pas : le compte Stremio, les addons et la bibliothèque, qui reviennent en se connectant au compte. Les 10 dernières sauvegardes sont gardées sur le NAS.")
            }
        }
        .navigationTitle("Sauvegarde")
        .task { await refreshLatest() }
        .confirmationDialog(restoreTitle, isPresented: Binding(get: { pendingRestore != nil },
                                                               set: { if !$0 { pendingRestore = nil } })) {
            Button("Restaurer", role: .destructive) {
                if let backup = pendingRestore { restore(backup) }
                pendingRestore = nil
            }
            Button("Annuler", role: .cancel) { pendingRestore = nil }
        }
    }

    private var restoreTitle: String {
        guard let backup = pendingRestore else { return "" }
        return "Remplacer les réglages actuels par ceux du \(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) (\(backup.device)) ?"
    }

    private func save() async {
        guard let server = app.settings.trailers.server else { return }
        busy = true
        defer { busy = false }
        do {
            let backup = SettingsBackup(settings: app.settings, device: Platform.isTV ? "Apple TV" : "iPad")
            var request = URLRequest(url: TrailerLink.backupURL(server: server), timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try backup.encoded()
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 201:
                message = "Réglages sauvegardés sur le NAS."
                latest = backup
            case 404:
                message = "Le service du NAS est une ancienne version : mettez à jour le dossier trailer-server et reconstruisez."
            case let code:
                message = "Le NAS a refusé la sauvegarde (code \(code.map(String.init) ?? "?"))."
            }
        } catch {
            message = "NAS injoignable : \(error.localizedDescription)"
        }
    }

    private func fetchLatest() async throws -> SettingsBackup? {
        guard let server = app.settings.trailers.server else { return nil }
        let request = URLRequest(url: TrailerLink.latestBackupURL(server: server), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try SettingsBackup.decode(data)
    }

    private func refreshLatest() async {
        latest = try? await fetchLatest()
    }

    private func prepareRestore() async {
        busy = true
        defer { busy = false }
        do {
            guard let backup = try await fetchLatest() else {
                message = "Aucune sauvegarde sur le NAS."
                return
            }
            latest = backup
            pendingRestore = backup
        } catch SettingsBackup.RestoreError.newerVersion {
            message = "Cette sauvegarde vient d'une version plus récente d'Aurora : mettez d'abord l'app à jour."
        } catch SettingsBackup.RestoreError.notABackup {
            message = "Le fichier trouvé sur le NAS n'est pas une sauvegarde d'Aurora."
        } catch {
            message = "NAS injoignable : \(error.localizedDescription)"
        }
    }

    private func restore(_ backup: SettingsBackup) {
        app.settings = backup.restoring(onto: app.settings)
        message = "Réglages restaurés."
    }
}
