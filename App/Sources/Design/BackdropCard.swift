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
    /// Film d'origine en écriture non latine : un logo sans texte reconnu est écarté.
    var nonLatinOrigin = false
    var subtitle: String?
    var progress: Double?
    /// Film probablement encore à l'affiche : pastille discrète en haut à droite.
    var inCinema = false
    /// Note IMDb (« 7.4 ») : pastille en haut à gauche.
    var rating: String?
    /// Étiquette en haut à droite (« Nouvel épisode »).
    var badge: String?
    var route: Route?
    var action: (() -> Void)?
    var onFocus: (() -> Void)?

    @FocusState private var focused: Bool
    /// Le logo est-il lisible (vérifié par la reconnaissance de texte) ? Optimiste au départ.
    @State private var logoReadable = true

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
        .task(id: logoURL) {
            guard let logoURL else { return }
            let readable = await LogoCheck.shared.isReadable(logoURL, nonLatinOrigin: nonLatinOrigin)
            if readable != logoReadable { logoReadable = readable }
        }
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
                if let logoURL, logoReadable {
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

            if let badge {
                Badge(text: badge, tint: Theme.accent, announced: false)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else if inCinema {
                CinemaBadge()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let note = RatingBadge.display(rating) {
                RatingBadge(rating: note)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

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
    var trailerURL: URL?
    var onTrailerPlaying: (Bool) -> Void = { _ in }

    var body: some View {
        ZStack {
            // Même vue d'image d'un titre à l'autre : fondu enchaîné, sans trou ni saut.
            CrossfadeImage(url: meta?.background ?? meta?.poster, maxPixel: 1920, duration: 0.6,
                           onLoaded: { ambient.update(from: $0) })
                .blur(radius: meta?.background == nil ? 40 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            TrailerBackdrop(url: trailerURL, onPlayingChange: onTrailerPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            // Voile teinté : lisibilité du texte à gauche et des rangées en bas.
            LinearGradient(colors: [Theme.backgroundDeep.opacity(0.85), ambient.tint.opacity(0.35), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.4),
                                   .init(color: Theme.backgroundDeep.opacity(0.75), location: 0.7),
                                   .init(color: Theme.backgroundDeep.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

/// Informations du bandeau (non focalisables) : logo ou titre, puces, résumé.
struct BillboardInfo: View {
    let meta: MetaItem?
    /// Bande-annonce en cours : le résumé s'efface pour laisser voir l'image.
    var dimmed = false
    @State private var unreadableLogos: Set<URL> = []

    /// Logo affiché : aucun s'il a été jugé illisible (écriture d'origine).
    private var logo: URL? {
        guard let url = meta?.displayLogo, !unreadableLogos.contains(url) else { return nil }
        return url
    }

    /// Gabarit fixe (logo/titre, puces, résumé sur 3 lignes réservées) : le bloc
    /// ne change jamais de hauteur d'un titre à l'autre, donc rien ne saute.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Nature du titre, discrète, au-dessus du logo.
            Text(kindLabel)
                .font(.manrope(17, .heavy))
                .tracking(3)
                .foregroundStyle(Theme.accent)
                .opacity(meta == nil ? 0 : 1)
            ZStack(alignment: .bottomLeading) {
                if logo == nil, let name = meta?.name {
                    Text(name)
                        .font(.heroTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.4), radius: 10)
                        .transition(.opacity)
                }
                CrossfadeImage(url: logo, maxPixel: 900, contentMode: .fit, alignment: .bottomLeading, duration: 0.35)
            }
            .frame(width: 760, height: 170, alignment: .bottomLeading)

            ZStack(alignment: .leading) {
                if let meta { MetaChips(meta: meta) }
            }
            .frame(height: 46, alignment: .leading)

            Text(meta?.description ?? " ")
                .font(.bodyLarge)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3, reservesSpace: true)
                .frame(width: 920, alignment: .topLeading)
                .contentTransition(.opacity)
                .opacity(dimmed ? 0 : 1)
                .animation(.easeInOut(duration: 0.8), value: dimmed)
        }
        .animation(.easeInOut(duration: 0.35), value: meta?.id)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .task(id: meta?.displayLogo) {
            guard let meta, let url = meta.displayLogo else { return }
            let readable = await LogoCheck.shared.isReadable(url, nonLatinOrigin: meta.nonLatinOrigin)
            if !readable { unreadableLogos.insert(url) }
        }
    }
}

extension BillboardInfo {
    var kindLabel: String {
        switch meta?.type {
        case ContentType.series: "SÉRIE"
        case ContentType.movie: "FILM"
        default: " "
        }
    }
}

/// Position dans le défilement du bandeau : un trait par titre, le titre affiché plus long et plein.
struct RotationDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 0.95 : 0.3))
                    .frame(width: i == index ? 34 : 16, height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }
}

/// Puces d'information : type · année · genres · durée · note. Seulement ce qui existe.
struct MetaChips: View {
    let meta: MetaItem
    /// Genres dans la ligne (sur la fiche, ils ont leur propre groupe « Genres »).
    var showGenres = true

    private var items: [String] {
        var out: [String] = [meta.type == ContentType.series ? "Série" : (meta.type == ContentType.movie ? "Film" : ContentTypeLabel.label(for: meta.type))]
        if let year = meta.displayYear { out.append(year) }
        if showGenres { out += meta.genres.prefix(2).map(Localize.genre) }
        if let runtime = meta.runtime { out.append(runtime) }
        return out
    }

    /// « Au cinéma » (estimation d'après la date de sortie) ou date de sortie en salle à venir.
    private var cinema: String? {
        switch meta.cinemaStatus() {
        case .inTheaters: return "Au cinéma"
        case .upcoming(let date): return "Au cinéma le \(date.formatted(.dateTime.day().month(.abbreviated)))"
        case nil: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { Chip(text: $0) }
            if let note = RatingBadge.display(meta.imdbRating) { ImdbScoreBox(rating: note) }
            if let cinema { Chip(text: cinema, systemImage: "popcorn", tint: Theme.accent) }
        }
        .foregroundStyle(Theme.textPrimary)
    }
}

/// Note IMDb encadrée : « 7,4 » puis le logo IMDb (jaune).
struct ImdbScoreBox: View {
    let rating: String

    var body: some View {
        HStack(spacing: 8) {
            Text(rating).font(.manrope(22, .heavy)).foregroundStyle(.white).monospacedDigit()
            Text("IMDb")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.96, green: 0.77, blue: 0.09)))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.96, green: 0.77, blue: 0.09).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 0.96, green: 0.77, blue: 0.09).opacity(0.7), lineWidth: 1.5))
        .accessibilityLabel(Text("Note IMDb \(rating)"))
    }
}

/// Intitulé discret (« GENRES ») au-dessus d'une rangée de puces.
struct LabeledChips: View {
    let label: String
    let values: [String]
    var limit = 3
    /// Rend chaque valeur cliquable (ex. filmographie d'un acteur).
    var route: ((String) -> Route?)?

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(label.uppercased())
                    .font(.manrope(15, .heavy))
                    .tracking(1.6)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 8) {
                    ForEach(Array(values.prefix(limit)), id: \.self) { value in
                        if let destination = route?(value) {
                            NavigationLink(value: destination) { Text(value).lineLimit(1) }
                                .buttonStyle(ChipButtonStyle())
                        } else {
                            Text(value)
                                .font(.manrope(18, .bold))
                                .lineLimit(1)
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                        }
                    }
                }
                .focusGroup()
            }
        }
    }
}

/// Puce focalisable : même aspect que les puces d'information, blanche au focus.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.manrope(18, .bold))
                .foregroundStyle(isFocused ? Theme.onFocus : Theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(isFocused ? 0 : 0.2), lineWidth: 1))
                .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 10, y: 4)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}
