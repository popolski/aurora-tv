import SwiftUI

/// Apple TV ou iPad : la même interface sert aux deux. Ces cales gardent le comportement
/// propre à la télécommande sur tvOS (sections de focus, bouton Menu, focus par défaut)
/// et n'ont pas d'effet sur iPad, où tout passe par le toucher.
enum Platform {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif
}

extension View {
    /// Section de focus (tvOS) : déplacement prévisible entre rangées.
    @ViewBuilder func focusGroup() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Bouton Menu / Retour de la télécommande (tvOS).
    @ViewBuilder func onBackCommand(perform action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    /// Élément qui reçoit le focus par défaut dans une portée (tvOS).
    @ViewBuilder func defaultFocusPreferred(_ prefers: Bool = true, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        prefersDefaultFocus(prefers, in: namespace)
        #else
        self
        #endif
    }

    /// Portée de focus (tvOS).
    @ViewBuilder func focusScopeOnTV(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        focusScope(namespace)
        #else
        self
        #endif
    }

    /// Interface conçue pour un écran de 1920 points (téléviseur) : sur iPad, elle est
    /// réduite à la largeur disponible (mêmes proportions, toucher compris).
    func tvCanvas() -> some View { modifier(TVCanvas()) }
}

/// Canevas de 1920 points de large, réduit à la taille de l'écran sur iPad.
struct TVCanvas: ViewModifier {
    static let designWidth: CGFloat = 1920

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        GeometryReader { geo in
            let scale = max(0.4, min(1, geo.size.width / Self.designWidth))
            content
                // Texte système (réglages, listes) à la taille qu'il aurait sur le téléviseur.
                .dynamicTypeSize(.accessibility1)
                .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        #endif
    }
}
