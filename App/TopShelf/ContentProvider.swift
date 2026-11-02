import Foundation
import TVServices
import LanterneCore

/// Extension Top Shelf d'Aurora : carrousel des dernières sorties de films.
///
/// tvOS affiche l'image en plein écran, le titre, le résumé, puis lance lui-même
/// la bande-annonce (sans le son) après quelques secondes si `previewVideoURL`
/// est renseignée. La bande-annonce vient du service du NAS, dont l'adresse est
/// partagée par l'app via le groupe d'apps ; sans elle, le carrousel reste en images.
final class ContentProvider: TVTopShelfContentProvider {
    // `nonsending` : s'exécute sur le contexte de l'appelant, le contenu (non `Sendable`)
    // ne change donc pas de domaine de concurrence en étant renvoyé.
    nonisolated(nonsending) override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let shared = SharedContainer.defaults()
        let config = TopShelfConfig.load(from: shared)
        // tvOS abandonne une extension trop lente : 10 s pour les données (détails facultatifs),
        // puis 7 s pour composer les images avec le titre (sinon image d'origine).
        let metas = await TopShelfLoader.latestMovies(limit: 10, deadline: 10)
        let artwork = await TopShelfArtwork.images(for: metas, deadline: 7)
        let server = config?.server
        let items = metas.map { Self.item(for: $0, server: server, artwork: artwork[$0.id]) }
        // Compte rendu lisible par l'app (Réglages › Diagnostics) si le groupe est partagé.
        TopShelfStatus(groupID: SharedContainer.groupID(), serverKnown: server != nil, items: items.count,
                       trailers: items.filter { $0.previewVideoURL != nil }.count).save(to: shared)
        guard !items.isEmpty else { return nil }  // tvOS garde alors l'image statique
        if let server { TopShelfLoader.prefetchTrailers(metas, server: server) }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }

    private static func item(for meta: MetaItem, server: URL?, artwork: URL?) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: meta.id)
        item.title = meta.name
        item.contextTitle = meta.cinemaStatus() == .inTheaters ? "Au cinéma" : "Nouveauté"
        item.summary = meta.description
        let genres = meta.genres.prefix(2).map(Localize.genre)
        if !genres.isEmpty { item.genre = genres.joined(separator: " · ") }
        if let runtime = meta.runtimeSeconds { item.duration = runtime }
        if let released = meta.released { item.creationDate = released }
        // Image avec le titre incrusté si elle a pu être composée, sinon l'image d'origine.
        if let image = artwork ?? meta.background {
            item.setImageURL(image, for: .screenScale1x)
            item.setImageURL(image, for: .screenScale2x)
        }
        var attributes: [TVTopShelfNamedAttribute] = []
        if !meta.directors.isEmpty {
            attributes.append(TVTopShelfNamedAttribute(name: "Réalisation", values: Array(meta.directors.prefix(2))))
        }
        if !meta.cast.isEmpty {
            attributes.append(TVTopShelfNamedAttribute(name: "Avec", values: Array(meta.cast.prefix(3))))
        }
        item.namedAttributes = attributes
        if let server, let id = TrailerLink.firstValidID(in: meta) {
            // Extrait de 30 s : tvOS passe au film suivant à la fin de la vidéo.
            item.previewVideoURL = TrailerLink.previewURL(server: server, youTubeID: id)
        }
        if let url = DeepLink(action: .meta, type: meta.type, id: meta.id, name: meta.name).url {
            item.displayAction = TVTopShelfAction(url: url)
        }
        if let url = DeepLink(action: .play, type: meta.type, id: meta.id, name: meta.name).url {
            item.playAction = TVTopShelfAction(url: url)
        }
        return item
    }
}

/// Téléchargements du carrousel (Cinemeta, données publiques ; aucun secret).
enum TopShelfLoader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    static func latestMovies(limit: Int, deadline: TimeInterval) async -> [MetaItem] {
        let started = Date()
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        var pool: [MetaItem] = []
        for y in [year, year - 1] {
            guard let url = TopShelfFeed.catalogURL(year: y),
                  let data = await fetch(url), let metas = try? TopShelfFeed.decodeCatalog(data) else { continue }
            pool += metas
            if TopShelfFeed.latest(pool, limit: limit).count >= limit { break }
        }
        let picked = TopShelfFeed.latest(pool, limit: limit)
        let remaining = deadline - Date().timeIntervalSince(started)
        guard remaining > 1 else { return picked }
        // Fiches complètes (bandes-annonces, réalisation, distribution), en parallèle,
        // dans le temps restant ; sans réponse à temps, les données du catalogue suffisent.
        return (try? await withDeadline(seconds: remaining) { await details(for: picked) }) ?? picked
    }

    private static func details(for picked: [MetaItem]) async -> [MetaItem] {
        await withTaskGroup(of: (Int, MetaItem).self) { group in
            for (index, meta) in picked.enumerated() {
                group.addTask {
                    guard let url = TopShelfFeed.metaURL(id: meta.id), let data = await fetch(url),
                          let detail = try? TopShelfFeed.decodeMeta(data) else { return (index, meta) }
                    return (index, meta.merged(withDetail: detail))
                }
            }
            var out = picked
            for await (index, meta) in group { out[index] = meta }
            return out
        }
    }

    /// Demande au NAS de préparer les bandes-annonces (sans attendre la réponse).
    static func prefetchTrailers(_ metas: [MetaItem], server: URL) {
        let ids = metas.compactMap(TrailerLink.firstValidID(in:))
        guard !ids.isEmpty, let body = try? JSONEncoder().encode(["ids": ids]) else { return }
        var request = URLRequest(url: TrailerLink.prefetchURL(server: server), timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request).resume()
    }

    static func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 5_000_000 else { return nil }
        return data
    }
}
