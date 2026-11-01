import Foundation

public enum AddonError: Error, Sendable, Equatable, LocalizedError {
    case network(NetworkError)
    case malformedResponse(String)
    case resourceNotSupported

    public var errorDescription: String? {
        switch self {
        case .network(let e): e.errorDescription
        case .malformedResponse: "Réponse de l'addon illisible."
        case .resourceNotSupported: "L'addon ne fournit pas cette ressource."
        }
    }
}

/// Cache mémoire LRU des réponses brutes d'addons, avec durée de vie.
public actor ResponseCache {
    private struct Entry {
        var data: Data
        var expiry: Date
        var lastAccess: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0
    private let maxBytes: Int

    public init(maxBytes: Int = 24 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    public func get(_ key: String, now: Date = Date()) -> Data? {
        guard var entry = entries[key] else { return nil }
        guard entry.expiry > now else {
            remove(key)
            return nil
        }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry.data
    }

    public func set(_ key: String, data: Data, ttl: TimeInterval, now: Date = Date()) {
        guard ttl > 0, data.count < maxBytes / 4 else { return }
        remove(key)
        clock &+= 1
        entries[key] = Entry(data: data, expiry: now.addingTimeInterval(ttl), lastAccess: clock)
        totalBytes += data.count
        evictIfNeeded()
    }

    public func removeAll() {
        entries.removeAll()
        totalBytes = 0
    }

    private func remove(_ key: String) {
        if let old = entries.removeValue(forKey: key) { totalBytes -= old.data.count }
    }

    private func evictIfNeeded() {
        guard totalBytes > maxBytes else { return }
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, _) in sorted {
            remove(key)
            if totalBytes <= maxBytes * 3 / 4 { break }
        }
    }
}

/// Client du protocole addon Stremio (transport HTTP).
///
/// Toutes les réponses sont traitées comme non fiables : taille plafonnée,
/// délai global, décodage tolérant, URL HTTPS exigées (HTTP accepté uniquement
/// pour les adresses de réseau local, ex. un addon auto-hébergé sur le NAS).
public struct AddonClient: Sendable {
    public struct TTL: Sendable {
        public var manifest: TimeInterval = 6 * 3600
        public var catalog: TimeInterval = 30 * 60
        public var meta: TimeInterval = 6 * 3600
        /// Courte : les liens de débridage expirent vite.
        public var stream: TimeInterval = 90
        public var subtitles: TimeInterval = 30 * 60
        public init() {}
    }

    private let http: any HTTPClient
    private let cache: ResponseCache
    private let ttl: TTL
    private let log = LogChannel("addons")
    public var requestTimeout: TimeInterval

    public init(http: any HTTPClient, cache: ResponseCache = ResponseCache(), ttl: TTL = TTL(), requestTimeout: TimeInterval = 15) {
        self.http = http; self.cache = cache; self.ttl = ttl; self.requestTimeout = requestTimeout
    }

    // MARK: Manifeste

    public func fetchManifest(_ transportURL: URL, useCache: Bool = true) async throws -> AddonManifest {
        try URLPolicy.validateRemote(transportURL)
        let data = try await fetch(transportURL, ttl: ttl.manifest, useCache: useCache, maxBytes: 1 * 1024 * 1024)
        do {
            return try JSONDecoder().decode(AddonManifest.self, from: data)
        } catch {
            throw AddonError.malformedResponse("manifeste : \(error)")
        }
    }

    public func descriptor(for input: String) async throws -> AddonDescriptor {
        let url = try AddonURLBuilder.normalizeManifestURL(input)
        let manifest = try await fetchManifest(url, useCache: false)
        return AddonDescriptor(transportURL: url, manifest: manifest)
    }

    // MARK: Ressources

    public func catalog(_ addon: AddonDescriptor, catalog: ManifestCatalog, extra: [ExtraValue] = []) async throws -> [MetaItem] {
        let request = ResourceRequest.catalog(type: catalog.type, id: catalog.id, extra: extra)
        let data = try await fetch(request, addon: addon, ttl: ttl.catalog, maxBytes: 6 * 1024 * 1024)
        do {
            return try JSONDecoder().decode(CatalogResponse.self, from: data).metas
        } catch {
            throw AddonError.malformedResponse("catalogue : \(error)")
        }
    }

    public func meta(_ addon: AddonDescriptor, type: String, id: String) async throws -> MetaItem? {
        guard addon.manifest.supports(resource: "meta", type: type, id: id) else { throw AddonError.resourceNotSupported }
        let data = try await fetch(.meta(type: type, id: id), addon: addon, ttl: ttl.meta, maxBytes: 8 * 1024 * 1024)
        do {
            return try JSONDecoder().decode(MetaResponse.self, from: data).meta
        } catch {
            throw AddonError.malformedResponse("meta : \(error)")
        }
    }

    public func streams(_ addon: AddonDescriptor, type: String, id: String) async throws -> [StreamItem] {
        guard addon.manifest.supports(resource: "stream", type: type, id: id) else { throw AddonError.resourceNotSupported }
        let data = try await fetch(.stream(type: type, id: id), addon: addon, ttl: ttl.stream, maxBytes: 4 * 1024 * 1024)
        do {
            return try JSONDecoder().decode(StreamsResponse.self, from: data).streams
        } catch {
            throw AddonError.malformedResponse("streams : \(error)")
        }
    }

    public func subtitles(_ addon: AddonDescriptor, type: String, id: String, extra: [ExtraValue] = []) async throws -> [SubtitleItem] {
        guard addon.manifest.supports(resource: "subtitles", type: type, id: id) else { throw AddonError.resourceNotSupported }
        let data = try await fetch(.subtitles(type: type, id: id, extra: extra), addon: addon, ttl: ttl.subtitles, maxBytes: 2 * 1024 * 1024)
        do {
            return try JSONDecoder().decode(SubtitlesResponse.self, from: data).subtitles.map {
                var s = $0
                s.addonName = addon.manifest.name
                return s
            }
        } catch {
            throw AddonError.malformedResponse("sous-titres : \(error)")
        }
    }

    public func clearCache() async { await cache.removeAll() }

    // MARK: Transport

    private func fetch(_ request: ResourceRequest, addon: AddonDescriptor, ttl: TimeInterval, maxBytes: Int) async throws -> Data {
        let url: URL
        do {
            url = try AddonURLBuilder.url(for: request, transportURL: addon.transportURL)
        } catch {
            throw AddonError.network(.invalidURL)
        }
        return try await fetch(url, ttl: ttl, useCache: true, maxBytes: maxBytes)
    }

    private func fetch(_ url: URL, ttl: TimeInterval, useCache: Bool, maxBytes: Int) async throws -> Data {
        try URLPolicy.validateRemote(url)
        let key = url.absoluteString
        if useCache, let cached = await cache.get(key) { return cached }
        let started = Date()
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, timeout: requestTimeout, maxBytes: maxBytes))
        } catch let error as NetworkError {
            log.warning("échec \(Redactor.redact(url: url)) : \(error)")
            throw AddonError.network(error)
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        guard (200..<300).contains(response.status) else {
            log.warning("HTTP \(response.status) \(Redactor.redact(url: url)) (\(elapsed) ms)")
            throw AddonError.network(.httpStatus(response.status))
        }
        log.debug("OK \(Redactor.redact(url: url)) \(response.data.count) o en \(elapsed) ms")
        // Respecte `Cache-Control: max-age` dans la limite de la durée par défaut ×4.
        let effectiveTTL = response.maxAge.map { min($0, ttl * 4) } ?? ttl
        await cache.set(key, data: response.data, ttl: effectiveTTL)
        return response.data
    }
}

/// Politique d'URL distantes (addons, API) : HTTPS obligatoire, sauf pour les
/// hôtes de réseau local (IP privées, `.local`) où HTTP est toléré.
public enum URLPolicy {
    public static func validateRemote(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            throw AddonError.network(.invalidURL)
        }
        if scheme == "https" { return }
        if scheme == "http", isLocalHost(host) { return }
        throw AddonError.network(.insecureURL)
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true  // CGNAT / Tailscale
        default: return false
        }
    }
}
