import Foundation
#if os(tvOS)
import TVServices
#endif
import LanterneCore

/// Transmet à l'extension Top Shelf ce dont elle a besoin (adresse du service de
/// bandes-annonces) et lui demande de se rafraîchir.
enum TopShelfBridge {
    private static var last: String??

    static func publish(_ settings: AppSettings, force: Bool = false) {
        let server = settings.trailers.server?.absoluteString
        guard force || last != .some(server) else { return }
        last = .some(server)
        #if os(tvOS)
        TopShelfConfig(trailerServer: server).save(to: SharedContainer.defaults())
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}
