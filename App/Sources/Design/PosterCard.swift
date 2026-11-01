import SwiftUI
import LanterneCore

/// Affiche focalisable (style « carte » natif tvOS : élévation et parallaxe).
struct PosterCard: View {
    let title: String
    let imageURL: URL?
    var subtitle: String?
    var shape: PosterShape = .poster
    var progress: Double?
    var badge: String?
    var width: CGFloat = Theme.Poster.width
    /// Navigation vers une destination (prioritaire sur `action`).
    var route: Route?
    var action: (() -> Void)?

    @FocusState private var focused: Bool

    private var size: CGSize {
        switch shape {
        case .poster: CGSize(width: width, height: width * 1.5)
        case .square: CGSize(width: width * 1.1, height: width * 1.1)
        case .landscape: CGSize(width: width * 1.6, height: width * 0.9)
        }
    }

    @ViewBuilder private var focusable: some View {
        if let route {
            NavigationLink(value: route) { artwork }.buttonStyle(.card)
        } else {
            Button { action?() } label: { artwork }.buttonStyle(.card)
        }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: imageURL, maxPixel: Int(size.height * 2)) {
                PosterPlaceholder(title: title)
            }
            .frame(width: size.width, height: size.height)
            .clipped()

            if let badge {
                Badge(text: badge, tint: Theme.accent, announced: false)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if let progress, progress > 0 {
                ProgressBar(value: progress)
                    .frame(height: 6)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            focusable
                .focused($focused)
                .accessibilityLabel(Text(title))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(focused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 21)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            .frame(width: size.width, alignment: .leading)
            .offset(y: focused ? 12 : 0)
            .animation(.easeOut(duration: 0.2), value: focused)
        }
    }
}

struct PosterPlaceholder: View {
    let title: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.surfaceRaised, Theme.surface], startPoint: .top, endPoint: .bottom)
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.55))
                Capsule().fill(Theme.accent).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
    }
}

/// Rangée horizontale de cartes avec en-tête, chargement et erreurs.
struct ShelfRow<Item: Identifiable, Card: View>: View {
    let title: String
    var subtitle: String?
    let items: [Item]
    var isLoading = false
    var error: String?
    var cardHeight: CGFloat = Theme.Poster.height + 90
    var onReachEnd: (() -> Void)?
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: title, subtitle: subtitle)
            if let error, items.isEmpty {
                Text(error).font(.meta).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.horizontalMargin)
            } else if isLoading && items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 40) {
                        ForEach(0..<7, id: \.self) { _ in
                            ShimmerBlock().frame(width: Theme.Poster.width, height: Theme.Poster.height)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalMargin)
                }
                .scrollDisabled(true)
                .frame(height: cardHeight)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(items) { item in
                            card(item)
                                .onAppear {
                                    if item.id == items.last?.id { onReachEnd?() }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.horizontalMargin)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                .frame(height: cardHeight + 40)
            }
        }
        .focusSection()
    }
}
