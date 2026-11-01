import SwiftUI
import CoreImage.CIFilterBuiltins
import LanterneCore

struct AccountView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmLogout = false

    var body: some View {
        List {
            if let session = app.session {
                Section {
                    InfoRow(label: "Compte", value: session.user.email.isEmpty ? "Connecté" : session.user.email)
                    InfoRow(label: "Synchronisation", value: syncText)
                    Button("Synchroniser maintenant") { Task { await app.account.syncAll() } }
                        .disabled(app.syncState == .syncing)
                    Button("Se déconnecter", role: .destructive) { confirmLogout = true }
                } footer: {
                    Text("Addons et bibliothèque sont synchronisés avec votre compte. La progression locale est conservée hors connexion et envoyée dès que possible.")
                }
            } else {
                Section {
                    NavigationLink("Se connecter avec un code (recommandé)") { LinkLoginView() }
                        .accessibilityIdentifier("account.link")
                    NavigationLink("Se connecter avec e-mail et mot de passe") { EmailLoginView() }
                } footer: {
                    Text("Sans compte, Lanterne fonctionne avec les addons officiels (Cinemeta, OpenSubtitles) et une bibliothèque locale. La connexion utilise l'API non officielle de Stremio, susceptible d'évoluer.")
                }
            }
        }
        .navigationTitle("Compte Stremio")
        .confirmationDialog("Se déconnecter ?", isPresented: $confirmLogout) {
            Button("Se déconnecter et conserver les données locales") {
                Task { await app.account.logout(eraseLocalData: false) }
            }
            Button("Se déconnecter et effacer les données locales", role: .destructive) {
                Task { await app.account.logout(eraseLocalData: true) }
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private var syncText: String {
        switch app.syncState {
        case .idle: "—"
        case .syncing: "En cours…"
        case .succeeded(let date): "OK à \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message): "Échec : \(message)"
        }
    }
}

/// Connexion par code : l'utilisateur valide sur son téléphone/ordinateur.
struct LinkLoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var code: LinkCode?
    @State private var qr: UIImage?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 26) {
                Text("Connexion par code").font(.screenTitle)
                if let code {
                    Text("1. Sur votre téléphone ou ordinateur, ouvrez :").font(.meta).foregroundStyle(Theme.textSecondary)
                    Text(code.link).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("2. Connectez-vous à Stremio et validez le code :").font(.meta).foregroundStyle(Theme.textSecondary)
                    Text(code.code).font(.system(size: 72, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                    HStack(spacing: 14) {
                        ProgressView()
                        Text("En attente de validation…").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                } else if let error {
                    Text(error).font(.meta).foregroundStyle(Theme.danger)
                    Button("Réessayer") { attempt += 1 }.buttonStyle(PillButtonStyle(prominent: true))
                } else {
                    ProgressView()
                }
            }
            if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 24).fill(.white))
            }
        }
        .padding(Theme.horizontalMargin)
        .task(id: attempt) { await run() }
    }

    private func run() async {
        error = nil
        code = nil
        qr = nil
        do {
            let created = try await app.account.createLinkCode()
            code = created
            qr = Self.qrImage(created.link)
            let linked = try await app.account.waitForLink(created)
            if linked {
                dismiss()
            } else {
                error = "Le code a expiré. Générez-en un nouveau."
                code = nil
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Connexion impossible."
            code = nil
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct EmailLoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                TextField("Adresse e-mail", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                Button(busy ? "Connexion…" : "Se connecter") { login() }
                    .disabled(busy || email.isEmpty || password.isEmpty)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(Theme.danger)
                } else {
                    Text("Le mot de passe n'est jamais enregistré : seul le jeton de session renvoyé par Stremio est conservé, dans le trousseau.")
                }
            }
        }
        .navigationTitle("Connexion")
    }

    private func login() {
        busy = true
        error = nil
        let email = self.email.trimmingCharacters(in: .whitespaces)
        let password = self.password
        Task {
            do {
                try await app.account.login(email: email, password: password)
                self.password = ""
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Connexion impossible."
            }
            busy = false
        }
    }
}
