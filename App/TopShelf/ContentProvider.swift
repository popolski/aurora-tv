import Foundation
import TVServices
import LanterneCore

/// Extension Top Shelf d'Aurora : carrousel des dernières sorties de films, ou, au choix
/// (Réglages › Bandes-annonces et carrousel), des titres en cours ou de Ma liste.
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
        let server = config?.server
        let group = SharedContainer.groupID()
        func report(_ phase: String, items: Int = 0, trailers: Int = 0, titled: Int = 0) {
            TopShelfStatus(groupID: group, serverKnown: server != nil, items: items, trailers: trailers,
                           phase: phase, titledImages: titled).save(to: shared)
            shared?.synchronize()
        }
        report("catalogue")
        // tvOS abandonne une extension trop lente : 10 s pour les données (détails facultatifs),
        // puis 7 s pour composer les images avec le titre (sinon image d'origine).
        let source = config?.source ?? .latest
        let entries = config?.entries ?? []
        let library = source != .latest && !entries.isEmpty
        let metas = library ? await TopShelfLoader.libraryTitles(entries, deadline: 10)
                            : await TopShelfLoader.latestMovies(limit: 10, deadline: 10)
        let entryByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        report("images", items: metas.count)
        // Images avec le titre incrusté, composées par le NAS (l'extension n'a pas assez de
        // mémoire pour le faire). Seulement si le service du NAS sait les produire.
        var titledServer: URL?
        if let server, await TopShelfLoader.serverMakesTitledImages(server) { titledServer = server }
        let items = metas.map { meta in
            Self.item(for: meta, server: server, titledImagesFrom: titledServer,
                      context: library ? Self.context(source, entry: entryByID[meta.id]) : nil)
        }
        // Compte rendu lisible par l'app (Réglages › Diagnostics) si le groupe est partagé.
        report("terminé", items: items.count, trailers: items.filter { $0.previewVideoURL != nil }.count,
               titled: titledServer == nil ? 0 : metas.filter { $0.background != nil }.count)
        guard !items.isEmpty else { return nil }  // tvOS garde alors l'image statique
        if let server { TopShelfLoader.prefetchTrailers(metas, server: server) }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }

    /// Sur-titre d'un titre de la bibliothèque : « Reprendre S02E03 · 24 min restantes », « Ma liste ».
    private static func context(_ source: TopShelfSource, entry: TopShelfEntry?) -> String {
        guard source == .continueWatching else { return "Ma liste" }
        var parts = ["Reprendre"]
        if let episode = entry?.episode { parts[0] += " \(episode)" }
        if let remaining = entry?.remaining, remaining >= 60 { parts.append("\(Int(remaining / 60)) min restantes") }
        return parts.joined(separator: " · ")
    }

    private static func item(for meta: MetaItem, server: URL?, titledImagesFrom titled: URL?,
                             context: String? = nil) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: meta.id)
        item.title = meta.name
        item.contextTitle = context ?? (meta.cinemaStatus() == .inTheaters ? "Au cinéma" : "Nouveauté")
        item.summary = meta.description
        let genres = meta.genres.prefix(2).map(Localize.genre)
        if !genres.isEmpty { item.genre = genres.joined(separator: " · ") }
        if let runtime = meta.runtimeSeconds { item.duration = runtime }
        if let released = meta.released { item.creationDate = released }
        // Image avec le titre incrusté (NAS) si possible, sinon l'image d'origine.
        if let image = titled.flatMap({ TrailerLink.topShelfImageURL(server: $0, meta: meta) }) ?? meta.background {
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
        if let server {
            // Extrait de 30 s (en français si possible) : tvOS passe au film suivant à la fin de la vidéo.
            item.previewVideoURL = TrailerLink.itemPreviewURL(server: server, meta: meta)
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

    /// Titres de la bibliothèque (« Continuer à regarder », « Ma liste ») : fiche Cinemeta de
    /// chacun, en parallèle ; sans réponse à temps, nom et affiche transmis par l'app.
    static func libraryTitles(_ entries: [TopShelfEntry], deadline: TimeInterval) async -> [MetaItem] {
        let fallback = entries.map { MetaItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, background: $0.poster) }
        return (try? await withDeadline(seconds: deadline) {
            await withTaskGroup(of: (Int, MetaItem).self) { group in
                for (index, entry) in entries.enumerated() {
                    group.addTask {
                        guard let url = TopShelfFeed.metaURL(id: entry.id, type: entry.type), let data = await fetch(url),
                              let detail = try? TopShelfFeed.decodeMeta(data) else { return (index, fallback[index]) }
                        var meta = detail
                        if meta.background == nil { meta.background = entry.poster }
                        return (index, meta)
                    }
                }
                var out = fallback
                for await (index, meta) in group { out[index] = meta }
                return out
            }
        }) ?? fallback
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

    /// Le service du NAS est-il à jour (images du carrousel) ? Réponse rapide exigée.
    static func serverMakesTitledImages(_ server: URL) async -> Bool {
        struct Health: Decodable { var topshelf: Bool? }
        var request = URLRequest(url: TrailerLink.healthURL(server: server), timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(Health.self, from: data) else { return false }
        return health.topshelf == true
    }

    /// Demande au NAS de préparer les bandes-annonces (sans attendre la réponse).
    static func prefetchTrailers(_ metas: [MetaItem], server: URL) {
        let items = metas.compactMap(TrailerLink.prefetchItem(for:))
        guard !items.isEmpty, let body = try? JSONEncoder().encode(["items": items]) else { return }
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
