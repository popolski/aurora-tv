import Foundation

/// Résultat d'une requête adressée à un addon précis.
public struct AddonOutcome<Value: Sendable>: Sendable {
    public let addon: AddonDescriptor
    public let result: Result<Value, AddonError>
    public let duration: TimeInterval

    public var value: Value? { try? result.get() }
    public var error: AddonError? {
        if case .failure(let e) = result { return e }
        return nil
    }
}

/// Catalogue d'un addon, adressable de façon stable.
public struct CatalogRef: Sendable, Hashable, Identifiable {
    public let addon: AddonDescriptor
    public let catalog: ManifestCatalog

    public var id: String { "\(addon.manifest.id)|\(catalog.type)|\(catalog.id)" }

    public init(addon: AddonDescriptor, catalog: ManifestCatalog) {
        self.addon = addon; self.catalog = catalog
    }

    /// Titre affichable : « Populaires · Films » si le nom ne précise pas le type.
    public var title: String {
        let base = catalog.name ?? catalog.id
        return base
    }

    public var typeLabel: String { ContentTypeLabel.label(for: catalog.type) }
}

public enum ContentTypeLabel {
    public static func label(for type: String) -> String {
        switch type {
        case ContentType.movie: "Films"
        case ContentType.series: "Séries"
        case ContentType.channel: "Chaînes"
        case ContentType.tv: "TV"
        case "anime": "Animés"
        default: type.capitalized
        }
    }
}

/// Orchestration multi-addons : interrogations concurrentes, délais
/// individuels, tolérance aux addons indisponibles, annulation propagée.
public struct AddonAggregator: Sendable {
    public let client: AddonClient
    /// Délai par addon pour les flux : un addon lent ne bloque pas les autres.
    public var streamTimeout: TimeInterval = 20

    public init(client: AddonClient) { self.client = client }

    // MARK: Catalogues

    /// Catalogues utilisables sans extra obligatoire, dans l'ordre des addons.
    public func browsableCatalogs(_ addons: [AddonDescriptor], types: Set<String>? = nil) -> [CatalogRef] {
        var refs: [CatalogRef] = []
        for addon in addons where !addon.manifest.behaviorHints.configurationRequired {
            for catalog in addon.manifest.catalogs where catalog.isBrowsableWithoutExtra {
                if let types, !types.contains(catalog.type) { continue }
                refs.append(CatalogRef(addon: addon, catalog: catalog))
            }
        }
        return refs
    }

    /// Catalogues de recherche (extra `search`).
    public func searchCatalogs(_ addons: [AddonDescriptor]) -> [CatalogRef] {
        addons.flatMap { addon in
            addon.manifest.catalogs.filter(\.supportsSearch).map { CatalogRef(addon: addon, catalog: $0) }
        }
    }

    public func page(_ ref: CatalogRef, genre: String? = nil, skip: Int = 0) async throws -> [MetaItem] {
        var extra: [ExtraValue] = []
        if let genre { extra.append(.init(name: ExtraName.genre, value: genre)) }
        if skip > 0 { extra.append(.init(name: ExtraName.skip, value: String(skip))) }
        guard ref.catalog.accepts(extra) else { throw AddonError.resourceNotSupported }
        return try await client.catalog(ref.addon, catalog: ref.catalog, extra: extra)
    }

    /// Recherche sur tous les catalogues compatibles ; résultats au fil de l'eau.
    public func search(_ query: String, addons: [AddonDescriptor]) -> AsyncStream<(CatalogRef, Result<[MetaItem], AddonError>)> {
        let refs = searchCatalogs(addons)
        let client = self.client
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (CatalogRef, Result<[MetaItem], AddonError>).self) { group in
                    for ref in refs {
                        group.addTask {
                            do {
                                let metas = try await client.catalog(ref.addon, catalog: ref.catalog,
                                                                     extra: [.init(name: ExtraName.search, value: trimmed)])
                                return (ref, .success(metas))
                            } catch let e as AddonError {
                                return (ref, .failure(e))
                            } catch {
                                return (ref, .failure(.network(.transport("annulé"))))
                            }
                        }
                    }
                    for await item in group {
                        if Task.isCancelled { break }
                        continuation.yield(item)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Métadonnées

    /// Fiche détaillée : premier addon (dans l'ordre d'installation) déclarant
    /// la ressource `meta` pour ce type et ce préfixe d'identifiant.
    public func meta(type: String, id: String, addons: [AddonDescriptor]) async throws -> MetaItem? {
        let candidates = addons.filter { $0.manifest.supports(resource: "meta", type: type, id: id) }
        var lastError: AddonError?
        for addon in candidates {
            try Task.checkCancellation()
            do {
                if let meta = try await client.meta(addon, type: type, id: id) { return meta }
            } catch let e as AddonError {
                lastError = e
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    // MARK: Flux

    /// Flux de tous les addons compatibles, émis dès que chaque addon répond.
    public func streams(type: String, id: String, addons: [AddonDescriptor]) -> AsyncStream<AddonOutcome<[StreamItem]>> {
        let candidates = addons.filter { $0.manifest.supports(resource: "stream", type: type, id: id) }
        let client = self.client
        let timeout = streamTimeout
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: AddonOutcome<[StreamItem]>.self) { group in
                    for addon in candidates {
                        group.addTask {
                            let start = Date()
                            let result: Result<[StreamItem], AddonError>
                            do {
                                let streams = try await withDeadline(seconds: timeout) {
                                    try await client.streams(addon, type: type, id: id)
                                }
                                result = .success(streams)
                            } catch let e as AddonError {
                                result = .failure(e)
                            } catch let e as NetworkError {
                                result = .failure(.network(e))
                            } catch {
                                result = .failure(.network(.transport("annulé")))
                            }
                            return AddonOutcome(addon: addon, result: result, duration: Date().timeIntervalSince(start))
                        }
                    }
                    for await outcome in group {
                        if Task.isCancelled { break }
                        continuation.yield(outcome)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func streamAddonCount(type: String, id: String, addons: [AddonDescriptor]) -> Int {
        addons.filter { $0.manifest.supports(resource: "stream", type: type, id: id) }.count
    }

    // MARK: Sous-titres

    /// Sous-titres externes de tous les addons compatibles. Les extras
    /// `videoHash`, `videoSize` et `filename` suivent le protocole Stremio.
    public func subtitles(type: String, id: String, hints: StreamBehaviorHints?, addons: [AddonDescriptor]) async -> [SubtitleItem] {
        var extra: [ExtraValue] = []
        if let hash = hints?.videoHash { extra.append(.init(name: "videoHash", value: hash)) }
        if let size = hints?.videoSize { extra.append(.init(name: "videoSize", value: String(size))) }
        if let name = hints?.filename { extra.append(.init(name: "filename", value: name)) }
        let candidates = addons.filter { $0.manifest.supports(resource: "subtitles", type: type, id: id) }
        let client = self.client
        let finalExtra = extra
        return await withTaskGroup(of: [SubtitleItem].self) { group in
            for addon in candidates {
                group.addTask {
                    (try? await withDeadline(seconds: 12) {
                        try await client.subtitles(addon, type: type, id: id, extra: finalExtra)
                    }) ?? []
                }
            }
            var all: [SubtitleItem] = []
            var seen = Set<String>()
            for await batch in group {
                for s in batch where seen.insert(s.url.absoluteString).inserted { all.append(s) }
            }
            return all
        }
    }
}
