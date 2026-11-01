import SwiftUI
import LanterneCore

/// Carte paysage 16:9 (image de fond + logo ou titre incrusté), coins arrondis,
/// anneau blanc au focus. Signale son focus pour alimenter le bandeau.
struct BackdropCard: View {
    static let width: CGFloat = 380
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
                NavigationLink(value: route) { artwork }.buttonStyle(GlassCardButtonStyle())
            } else {
                Button { action?() } label: { artwork }.buttonStyle(GlassCardButtonStyle())
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
            RemoteImage(url: imageURL ?? fallbackURL, maxPixel: 760) {
                ZStack {
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "film").font(.system(size: 40)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: Self.width, height: Self.height)
            .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                if let logoURL {
                    RemoteImage(url: logoURL, maxPixel: 500, contentMode: .fit) {
                        Text(title).font(.manrope(26, .heavy)).foregroundStyle(.white).lineLimit(2)
                    }
                    .frame(maxWidth: 220, maxHeight: 60, alignment: .bottomLeading)
                } else {
                    Text(title)
                        .font(.manrope(26, .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
                if let subtitle {
                    Text(subtitle).font(.manrope(18, .bold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, progress == nil ? 18 : 30)

            if let progress, progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule().fill(Color.white).frame(width: max(6, geo.size.width * min(progress, 1)))
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// Fond plein écran de l'accueil : image du titre mis en avant ; sa couleur
/// dominante teinte toute l'interface (« Aurore »).
struct BillboardBackdrop: View {
    @Environment(Ambient.self) private var ambient
    let meta: MetaItem?

    var body: some View {
        ZStack {
            if let meta {
                Group {
                    if let background = meta.background {
                        RemoteImage(url: background, maxPixel: 1920, placeholder: { Color.clear },
                                    onLoaded: { ambient.update(from: $0) })
                    } else if let poster = meta.poster {
                        // Affiche seule : version floutée en fond, nette à droite.
                        ZStack(alignment: .trailing) {
                            RemoteImage(url: poster, maxPixel: 600, placeholder: { Color.clear },
                                        onLoaded: { ambient.update(from: $0) })
                                .blur(radius: 50).opacity(0.7)
                            RemoteImage(url: poster, maxPixel: 900) { Color.clear }
                                .frame(width: 500, height: 750)
                                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                                .padding(.trailing, 150)
                        }
                    }
                }
                .id(meta.id)
                .transition(.opacity)
            }
            // Voile teinté : lisibilité du texte à gauche et des rangées en bas.
            LinearGradient(colors: [Theme.backgroundDeep.opacity(0.85), ambient.tint.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.4),
                                   .init(color: Theme.backgroundDeep.opacity(0.75), location: 0.7),
                                   .init(color: Theme.backgroundDeep.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.5), value: meta?.id)
        .ignoresSafeArea()
    }
}

/// Informations du bandeau (non focalisables) : logo ou titre, puces, résumé.
struct BillboardInfo: View {
    let meta: MetaItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let meta {
                if let logo = meta.logo {
                    RemoteImage(url: logo, maxPixel: 900, contentMode: .fit) {
                        Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    }
                    .frame(maxWidth: 640, maxHeight: 170, alignment: .bottomLeading)
                } else {
                    Text(meta.name).font(.heroTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.4), radius: 10)
                }
                MetaChips(meta: meta)
                if let description = meta.description {
                    Text(description)
                        .font(.bodyLarge)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .id(meta?.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: meta?.id)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
}

/// Puces d'information : type · année · genres · durée · note. Seulement ce qui existe.
struct MetaChips: View {
    let meta: MetaItem

    private var items: [String] {
        var out: [String] = [meta.type == ContentType.series ? "Série" : (meta.type == ContentType.movie ? "Film" : ContentTypeLabel.label(for: meta.type))]
        if let year = meta.displayYear { out.append(year) }
        out += meta.genres.prefix(2).map(Localize.genre)
        if let runtime = meta.runtime { out.append(runtime) }
        if let rating = meta.imdbRating { out.append("IMDb \(rating)") }
        return out
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
        .foregroundStyle(Theme.textPrimary)
    }
}
