import SwiftUI
import LanterneCore

/// Carte paysage 16:9 (image de fond + logo ou titre incrusté), pour les rangées
/// de l'accueil. Signale son focus pour alimenter le bandeau dynamique.
struct BackdropCard: View {
    static let width: CGFloat = 400
    static var height: CGFloat { width * 9 / 16 }

    let title: String
    /// Image de fond (préférée) ; à défaut, `fallbackURL` (affiche) est recadrée.
    let imageURL: URL?
    var fallbackURL: URL?
    var logoURL: URL?
    var subtitle: String?
    var progress: Double?
    var route: Route?
    var action: (() -> Void)?
    var onFocus: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { artwork }.buttonStyle(.card)
            } else {
                Button { action?() } label: { artwork }.buttonStyle(.card)
            }
        }
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocus?() }
        }
        .accessibilityLabel(Text(title))
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: imageURL ?? fallbackURL, maxPixel: 800) {
                ZStack {
                    LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "film").font(.system(size: 44)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                if let logoURL {
                    RemoteImage(url: logoURL, maxPixel: 500, contentMode: .fit) {
                        Text(title).font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                    }
                    .frame(maxWidth: 230, maxHeight: 64, alignment: .bottomLeading)
                } else {
                    Text(title)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, progress == nil ? 16 : 26)

            if let progress, progress > 0 {
                ProgressBar(value: progress)
                    .frame(height: 6)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// Bandeau supérieur de l'accueil : image de fond plein écran du titre qui a le focus.
struct BillboardBackdrop: View {
    let meta: MetaItem?

    var body: some View {
        ZStack {
            Theme.background
            if let meta {
                Group {
                    if let background = meta.background {
                        RemoteImage(url: background, maxPixel: 1920) { Color.clear }
                    } else if let poster = meta.poster {
                        // Affiche seule : version floutée en fond, nette à droite.
                        ZStack(alignment: .trailing) {
                            RemoteImage(url: poster, maxPixel: 600) { Color.clear }.blur(radius: 40).opacity(0.6)
                            RemoteImage(url: poster, maxPixel: 900) { Color.clear }
                                .frame(width: 520, height: 780)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .padding(.trailing, 140)
                        }
                    }
                }
                .id(meta.id)
                .transition(.opacity)
            }
            // Dégradés : lisibilité du texte à gauche et des rangées en bas.
            LinearGradient(colors: [Theme.background.opacity(0.95), Theme.background.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.35),
                                   .init(color: Theme.background.opacity(0.85), location: 0.62),
                                   .init(color: Theme.background, location: 0.8)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.45), value: meta?.id)
        .ignoresSafeArea()
    }
}

/// Informations du bandeau (non focalisables) : logo ou titre, ligne d'infos, résumé.
struct BillboardInfo: View {
    let meta: MetaItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let meta {
                if let logo = meta.logo {
                    RemoteImage(url: logo, maxPixel: 900, contentMode: .fit) {
                        Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    }
                    .frame(maxWidth: 640, maxHeight: 170, alignment: .bottomLeading)
                } else {
                    Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .shadow(color: .black.opacity(0.5), radius: 8)
                }
                MetaLine(meta: meta)
                if let description = meta.description {
                    Text(description)
                        .font(.system(size: 27))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 980, alignment: .leading)
                }
            }
        }
        .id(meta?.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: meta?.id)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
}
