import Foundation
#if os(tvOS)
import TVServices
#endif
import LanterneCore

/// Transmet à l'extension Top Shelf ce dont elle a besoin (adresse du service de
/// bandes-annonces) et lui demande de se rafraîchir.
enum TopShelfBridge {
    private static var last: TopShelfConfig?

    static func publish(_ settings: AppSettings, entries: [TopShelfEntry], force: Bool = false) {
        let config = TopShelfConfig(trailerServer: settings.trailers.server?.absoluteString,
                                    source: settings.topShelfSource, entries: entries)
        guard force || !config.sameContent(as: last) else { return }
        last = config
        #if os(tvOS)
        config.save(to: SharedContainer.defaults())
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}
