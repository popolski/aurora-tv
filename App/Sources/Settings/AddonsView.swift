import SwiftUI
import LanterneCore

struct AddonsView: View {
    @Environment(AppModel.self) private var app
    @State private var newURL = ""
    @State private var installing = false
    @State private var message: String?
    @State private var pendingRemoval: URL?

    var body: some View {
        List {
            Section {
                TextField("https://…/manifest.json", text: $newURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit { install() }
                Button(installing ? "Vérification du manifeste…" : "Installer l'addon") { install() }
                    .disabled(installing || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Ajouter un addon")
            } footer: {
                if let message { Text(message) } else {
                    Text("Collez l'adresse du manifeste (y compris les addons configurés). L'adresse est conservée dans le trousseau car elle peut contenir des clés personnelles.")
                }
            }

            Section {
                ForEach(app.addonStatuses) { status in
                    AddonRow(status: status,
                             onToggle: { Task { await app.registry.setEnabled(status.entry.transportURL, !status.entry.enabled) } },
                             onUp: { Task { await app.registry.move(status.entry.transportURL, by: -1) } },
                             onDown: { Task { await app.registry.move(status.entry.transportURL, by: 1) } },
                             onRemove: { pendingRemoval = status.entry.transportURL })
                }
                Button("Actualiser les manifestes") {
                    Task {
                        await app.addonClient.clearCache()
                        await app.registry.refreshManifests(force: true)
                    }
                }
            } header: {
                Text("Addons installés")
            } footer: {
                Text(app.session == nil
                     ? "L'ordre détermine la priorité pour les fiches et l'ordre des sources."
                     : "Connecté : la liste suit votre compte Stremio à chaque synchronisation. Les addons ajoutés ici restent locaux à cette Apple TV.")
            }
        }
        .navigationTitle("Addons")
        .confirmationDialog("Retirer cet addon ?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Retirer", role: .destructive) {
                if let url = pendingRemoval { Task { await app.registry.remove(url) } }
                pendingRemoval = nil
            }
            Button("Annuler", role: .cancel) { pendingRemoval = nil }
        }
    }

    private func install() {
        let input = newURL
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty, !installing else { return }
        installing = true
        message = nil
        Task {
            do {
                let descriptor = try await app.registry.install(input)
                message = "« \(descriptor.manifest.name) » installé."
                newURL = ""
            } catch let error as AddonURLError {
                message = switch error {
                case .unsupportedScheme: "Seules les adresses http(s) et stremio:// sont acceptées."
                default: "Adresse invalide."
                }
            } catch {
                message = "Échec : \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            installing = false
        }
    }
}

private struct AddonRow: View {
    let status: AddonRegistry.Status
    let onToggle: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onRemove: () -> Void

    private var originLabel: String {
        switch status.entry.origin {
        case .defaults: "Par défaut"
        case .account: "Compte"
        case .local: "Local"
        }
    }

    var body: some View {
        HStack(spacing: 18) {
            Button(action: onToggle) {
                HStack(spacing: 18) {
                    Image(systemName: status.entry.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(status.entry.enabled ? Theme.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.manifest?.name ?? status.entry.transportURL.host ?? "Addon")
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let note = status.ignoredNote {
                            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if let failure = status.failure {
                            Text(failure).font(.caption).foregroundStyle(Theme.danger).lineLimit(1)
                        }
                    }
                }
            }
            Button(action: onUp) { Image(systemName: "chevron.up") }
            Button(action: onDown) { Image(systemName: "chevron.down") }
            Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
        }
    }

    private var detail: String {
        var parts = [originLabel, status.entry.transportURL.host ?? "?"]
        if let m = status.manifest {
            parts.append("v\(m.version)")
            let resources = m.resources.map(\.name).filter { $0 != "addon_catalog" }
            if !resources.isEmpty { parts.append(resources.joined(separator: ", ")) }
        }
        return parts.joined(separator: " · ")
    }
}
