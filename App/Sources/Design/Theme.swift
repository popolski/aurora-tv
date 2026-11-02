import SwiftUI
import LanterneCore
import Observation

/// Identité visuelle « Aurore » : l'image d'abord. L'affiche du contenu mis en
/// avant teinte tout l'écran ; surfaces translucides, capsules, Manrope.
enum Theme {
    /// Fond de repli (nuit violacée) quand aucune image ne teinte l'écran.
    static let background = Color(red: 0.071, green: 0.035, blue: 0.110)
    static let backgroundDeep = Color(red: 0.045, green: 0.022, blue: 0.070)
    /// Surfaces « verre » : blanc translucide.
    static let surface = Color.white.opacity(0.10)
    static let surfaceRaised = Color.white.opacity(0.18)
    static let stroke = Color.white.opacity(0.26)
    /// Accent chaud (lueur d'aurore) pour les petits signaux : progression, badges.
    static let accent = Color(red: 1.0, green: 0.698, blue: 0.478)
    static let accentSoft = Color(red: 1.0, green: 0.698, blue: 0.478).opacity(0.2)
    /// Le focus est blanc : contraste maximal sur n'importe quelle image.
    static let focus = Color.white
    static let onFocus = Color(red: 0.165, green: 0.078, blue: 0.251)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.82)
    static let textTertiary = Color.white.opacity(0.6)
    static let danger = Color(red: 1.0, green: 0.48, blue: 0.45)
    static let success = Color(red: 0.55, green: 0.92, blue: 0.68)

    /// Marges latérales de sécurité (zone sûre des téléviseurs).
    static let horizontalMargin: CGFloat = 110
    static let rowSpacing: CGFloat = 40
    static let cornerRadius: CGFloat = 26

    enum Poster {
        static let width: CGFloat = 240
        static var height: CGFloat { width * 1.5 }
        static let landscapeWidth: CGFloat = 400
        static var landscapeHeight: CGFloat { landscapeWidth * 9 / 16 }
    }
}

extension Font {
    /// Manrope embarquée (licence OFL) ; repli sur la police système si absente.
    static func manrope(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let name: String
        switch weight {
        case .heavy, .black: name = "Manrope-ExtraBold"
        case .bold: name = "Manrope-Bold"
        case .semibold: name = "Manrope-SemiBold"
        default: name = "Manrope-Medium"
        }
        return .custom(name, size: size)
    }

    /// Typographie lisible à plusieurs mètres (tailles de base tvOS à 1080p).
    static let heroTitle = Font.manrope(104, .heavy)
    static let screenTitle = Font.manrope(56, .heavy)
    static let sectionTitle = Font.manrope(28, .heavy)
    static let cardTitle = Font.manrope(24, .heavy)
    static let bodyLarge = Font.manrope(27, .medium)
    static let meta = Font.manrope(23, .semibold)
    static let badge = Font.manrope(19, .bold)
}

// MARK: - Teinte ambiante

/// Couleur dominante de l'image mise en avant, partagée par tout l'écran.
@MainActor
@Observable
final class Ambient {
    var tint: Color = Color(red: 0.48, green: 0.18, blue: 0.42)

    func update(from image: UIImage) {
        guard let color = Self.averageColor(image) else { return }
        withAnimation(.easeInOut(duration: 0.8)) { tint = color }
    }

    /// Moyenne des pixels (image réduite à 1×1), saturée et assombrie pour
    /// rester lisible sous du texte blanc.
    nonisolated static func averageColor(_ image: UIImage) -> Color? {
        guard let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ui = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.35 + 0.12)), brightness: Double(min(0.62, max(0.28, b * 0.9))))
    }
}

/// Fond commun : dégradé teinté par la couleur ambiante.
struct AmbientBackground: View {
    @Environment(Ambient.self) private var ambient

    var body: some View {
        ZStack {
            Theme.backgroundDeep
            RadialGradient(colors: [ambient.tint.opacity(0.95), ambient.tint.opacity(0.35), Theme.backgroundDeep],
                           center: UnitPoint(x: 0.78, y: 0.18), startRadius: 40, endRadius: 1500)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Fond d'écran commun (teinte ambiante).
    func screenBackground() -> some View {
        background(AmbientBackground())
    }
}

// MARK: - Boutons

/// Capsule : principale (blanche) ou « verre ». Au focus : blanche, texte sombre, agrandie.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    /// Option sélectionnée (onglet, filtre) hors focus : capsule blanche discrète.
    var selected = false
    /// Version réduite (filtres, panneaux).
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, selected: selected, compact: compact)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let selected: Bool
        let compact: Bool
        @Environment(\.isFocused) private var isFocused

        private var filled: Bool { isFocused || prominent }

        var body: some View {
            configuration.label
                .font(.manrope(compact ? 20 : 25, .heavy))
                .lineLimit(1)
                .padding(.horizontal, compact ? 20 : 36)
                .padding(.vertical, compact ? 12 : 20)
                .foregroundStyle(filled ? Theme.onFocus : Theme.textPrimary)
                .background(
                    Capsule().fill(filled ? Theme.focus : (selected ? Theme.surfaceRaised : Theme.surface))
                )
                .overlay(Capsule().strokeBorder(filled ? Color.clear : (selected ? Color.white.opacity(0.7) : Theme.stroke), lineWidth: selected ? 2 : 1))
                .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.96 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 24, y: 12)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
    }
}

/// Bouton rond à icône (ajout à la liste, recherche…).
struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 80, height: 80)
                .foregroundStyle(isFocused ? Theme.onFocus : Theme.textPrimary)
                .background(Circle().fill(isFocused ? Theme.focus : Theme.surface))
                .overlay(Circle().strokeBorder(isFocused ? Color.clear : Theme.stroke, lineWidth: 1))
                .scaleEffect(isFocused ? 1.1 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 20, y: 10)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFocused)
        }
    }
}

/// Conservé pour compatibilité : même rendu que la capsule.
typealias ActionButtonStyle = PillButtonStyle

/// Ligne de liste (sources, journaux) : verre, blanche au focus.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Theme.textPrimary)
                // Le contenu des lignes (sources) garde ses couleurs : le focus
                // éclaircit le verre et ajoute un anneau blanc plutôt qu'un fond plein.
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.26) : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(isFocused ? Theme.focus : Color.white.opacity(0.14), lineWidth: isFocused ? 4 : 1)
                )
                .scaleEffect(isFocused ? 1.015 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 8)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Carte image focalisable : coins arrondis, anneau blanc et élévation au focus.
struct GlassCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.cornerRadius

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.focus, lineWidth: isFocused ? 5 : 0)
                )
                .scaleEffect(isFocused ? 1.07 : (configuration.isPressed ? 0.97 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0.25), radius: isFocused ? 30 : 10, y: isFocused ? 18 : 6)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isFocused)
        }
    }
}

// MARK: - Éléments

/// Petite étiquette (4K, HDR, VF…). `announced` = information déclarée par
/// l'addon (non vérifiée), en contour ; détectée = pleine.
struct Badge: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var announced = true

    var body: some View {
        Text(text)
            .font(.badge)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(announced ? tint : Theme.onFocus)
            .background(Capsule().fill(announced ? Color.white.opacity(0.08) : tint))
            .overlay(Capsule().strokeBorder(tint.opacity(announced ? 0.6 : 0), lineWidth: 1.5))
    }
}

/// Puce d'information translucide (genre, saison, note…).
struct Chip: View {
    let text: String
    var systemImage: String?
    /// Teinte discrète (contour et texte) pour une information à signaler.
    var tint: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 17, weight: .bold)) }
            Text(text)
        }
        .font(.manrope(20, .bold))
        .lineLimit(1)
        .foregroundStyle(tint ?? Theme.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(tint == nil ? 0.16 : 0.08)))
        .overlay(Capsule().strokeBorder((tint ?? Color.white).opacity(tint == nil ? 0.22 : 0.55), lineWidth: 1))
    }
}

/// Note IMDb discrète sur une miniature : « IMDb » sur fond jaune, puis la note.
struct RatingBadge: View {
    let rating: String

    /// Note affichable : « 7.4 » → « 7,4 » ; ignore les valeurs vides ou nulles.
    static func display(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), let value = Double(raw), value > 0, value <= 10 else { return nil }
        return value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR")))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("IMDb")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.96, green: 0.77, blue: 0.09)))
            Text(rating)
                .font(.manrope(17, .heavy))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.backgroundDeep.opacity(0.72)))
        .accessibilityLabel(Text("Note IMDb \(rating)"))
    }
}

/// Petite pastille « au cinéma » (icône seule) posée sur une miniature.
struct CinemaBadge: View {
    var body: some View {
        Image(systemName: "popcorn.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.backgroundDeep.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
            .accessibilityLabel(Text("Au cinéma"))
    }
}

extension MetaItem {
    /// Probablement encore à l'affiche (estimation, voir `cinemaStatus`).
    var isInCinema: Bool { cinemaStatus() == .inTheaters }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.sectionTitle).foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle).font(.manrope(19, .semibold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .accessibilityAddTraits(.isHeader)
    }
}

/// État vide ou d'erreur, centré, sur un panneau de verre.
struct MessageView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(Theme.textPrimary)
            Text(title).font(.manrope(36, .heavy)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.meta).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 1000)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PillButtonStyle(prominent: true))
                    .padding(.top, 10)
            }
        }
        .padding(56)
        .background(GlassPanel(cornerRadius: 36))
        .frame(maxWidth: .infinity)
    }
}

/// Panneau de verre (fond translucide + bord clair).
struct GlassPanel: View {
    var cornerRadius: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.backgroundDeep.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// Bloc de chargement animé (« squelette »).
struct ShimmerBlock: View {
    var cornerRadius: CGFloat = Theme.cornerRadius
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.4)
                }
                .clipped()
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}
