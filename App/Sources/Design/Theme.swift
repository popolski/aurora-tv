import SwiftUI

/// Identité visuelle de Lanterne : nuit profonde, lumière ambrée.
enum Theme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.067)
    static let surface = Color(red: 0.082, green: 0.098, blue: 0.137)
    static let surfaceRaised = Color(red: 0.12, green: 0.14, blue: 0.19)
    static let accent = Color(red: 0.949, green: 0.702, blue: 0.357)
    static let accentSoft = Color(red: 0.949, green: 0.702, blue: 0.357).opacity(0.18)
    static let textPrimary = Color(white: 0.96)
    static let textSecondary = Color(white: 0.70)
    static let textTertiary = Color(white: 0.50)
    static let danger = Color(red: 0.94, green: 0.42, blue: 0.38)
    static let success = Color(red: 0.45, green: 0.80, blue: 0.55)

    /// Marges latérales de sécurité (zone sûre des téléviseurs).
    static let horizontalMargin: CGFloat = 80
    static let rowSpacing: CGFloat = 48
    static let cornerRadius: CGFloat = 14

    enum Poster {
        static let width: CGFloat = 240
        static var height: CGFloat { width * 1.5 }
        static let landscapeWidth: CGFloat = 400
        static var landscapeHeight: CGFloat { landscapeWidth * 9 / 16 }
    }
}

extension Font {
    /// Typographie lisible à plusieurs mètres (tailles de base tvOS à 1080p).
    static let heroTitle = Font.system(size: 76, weight: .heavy, design: .default)
    static let screenTitle = Font.system(size: 52, weight: .bold)
    static let sectionTitle = Font.system(size: 34, weight: .semibold)
    static let cardTitle = Font.system(size: 24, weight: .semibold)
    static let bodyLarge = Font.system(size: 29, weight: .regular)
    static let meta = Font.system(size: 24, weight: .medium)
    static let badge = Font.system(size: 19, weight: .bold)
}

/// Bouton « pilule » : texte + icône, mise en avant ambrée au focus.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 27, weight: .semibold))
                .padding(.horizontal, 34)
                .padding(.vertical, 18)
                .foregroundStyle(isFocused ? Color.black : Theme.textPrimary)
                .background(
                    Capsule().fill(isFocused ? Theme.accent : (prominent ? Theme.surfaceRaised : Theme.surface.opacity(0.85)))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(isFocused ? 0 : 0.08), lineWidth: 1))
                .scaleEffect(isFocused ? 1.06 : (configuration.isPressed ? 0.97 : 1))
                .shadow(color: isFocused ? Theme.accent.opacity(0.35) : .clear, radius: 18, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Ligne de liste (réglages, sources) : fond discret, surbrillance au focus.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(isFocused ? Theme.surfaceRaised : Theme.surface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(isFocused ? Theme.accent : Color.clear, lineWidth: 3)
                )
                .scaleEffect(isFocused ? 1.015 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Petite étiquette (4K, HDR, VF…). `announced` = information déclarée par
/// l'addon (non vérifiée), affichée en contour ; détectée = pleine.
struct Badge: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var announced = true

    var body: some View {
        Text(text)
            .font(.badge)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(announced ? tint : Color.black)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(announced ? Color.clear : tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.opacity(announced ? 0.7 : 0), lineWidth: 1.5)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).font(.sectionTitle).foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle).font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.horizontalMargin)
        .accessibilityAddTraits(.isHeader)
    }
}

/// État vide ou d'erreur, centré.
struct MessageView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(.sectionTitle).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.meta).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 1100)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PillButtonStyle(prominent: true))
                    .padding(.top, 10)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity)
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
                    LinearGradient(colors: [.clear, Color.white.opacity(0.06), .clear], startPoint: .leading, endPoint: .trailing)
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

extension View {
    /// Fond d'écran commun.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
