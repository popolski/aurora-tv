import Foundation

/// Addons installés et leur ordre.
///
/// - Les URL de transport (pouvant contenir des clés de services tiers) sont
///   conservées dans le trousseau.
/// - Les manifestes sont mis en cache (purgeable) et re-téléchargés si absents.
/// - Connecté à un compte, la collection du compte fait foi ; les ajouts
///   locaux restent locaux (l'écriture `addonCollectionSet` n'est pas utilisée,
///   pour ne jamais altérer le compte par erreur).
public actor AddonRegistry {
    public enum Origin: String, Sendable, Codable { case defaults, account, local }

    public struct Entry: Sendable, Codable, Hashable {
        public var transportURL: URL
        public var origin: Origin
        public var enabled: Bool
    }

    public static let defaultAddonURLs: [URL] = [
        // Addons officiels Stremio : métadonnées (Cinemeta) et sous-titres (OpenSubtitles v3).
        URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
        URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!,
    ]

    private var entries: [Entry] = []
    private var manifests: [URL: AddonManifest] = [:]
    private var failures: [URL: String] = [:]
    private let secrets: any SecretStore
    private let cache: any KeyValueStore
    private let client: AddonClient
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let log = LogChannel("registry")

    static let entriesKey = "addons.entries.v1"
    static let manifestsKey = "addons.manifests.v1"

    public init(secrets: any SecretStore, cache: any KeyValueStore, client: AddonClient) {
        self.secrets = secrets
        self.cache = cache
        self.client = client
        if let saved = secrets.decodeSecret([Entry].self, forKey: Self.entriesKey) {
            self.entries = saved
        } else {
            self.entries = Self.defaultAddonURLs.map { Entry(transportURL: $0, origin: .defaults, enabled: true) }
        }
        if let cached = cache.decode([String: AddonManifest].self, forKey: Self.manifestsKey) {
            for (k, v) in cached { if let u = URL(string: k) { manifests[u] = v } }
        }
    }

    /// Addons servis par l'appareil lui-même (`127.0.0.1`, `localhost`) : dans un
    /// compte Stremio, ce sont ceux de l'app Stremio sur ordinateur (« Local Files »
    /// sur `127.0.0.1:11470`), injoignables depuis l'Apple TV. Conservés dans la
    /// collection du compte, mais jamais interrogés.
    public static func isDeviceLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    public static let deviceLocalNote = "Addon de l'app Stremio sur ordinateur (127.0.0.1) : ignoré sur l'Apple TV"

    /// Addons actifs dont le manifeste est disponible, dans l'ordre.
    public func activeDescriptors(hideAdult: Bool = true) -> [AddonDescriptor] {
        entries.compactMap { e in
            guard e.enabled, !Self.isDeviceLocal(e.transportURL), let m = manifests[e.transportURL] else { return nil }
            if hideAdult && m.behaviorHints.adult { return nil }
            return AddonDescriptor(transportURL: e.transportURL, manifest: m,
                                   flags: AddonFlags(official: e.origin == .defaults, protected: false))
        }
    }

    public struct Status: Sendable, Hashable, Identifiable {
        public var entry: Entry
        public var manifest: AddonManifest?
        public var failure: String?
        public var id: String { entry.transportURL.absoluteString }
        /// Addon conservé mais jamais interrogé sur cet appareil (voir `isDeviceLocal`).
        public var ignoredNote: String? { AddonRegistry.isDeviceLocal(entry.transportURL) ? AddonRegistry.deviceLocalNote : nil }
    }

    public func statuses() -> [Status] {
        entries.map { e in
            Status(entry: e, manifest: manifests[e.transportURL],
                   failure: Self.isDeviceLocal(e.transportURL) ? nil : failures[e.transportURL])
        }
    }

    /// Télécharge les manifestes manquants (ou tous si `force`).
    public func refreshManifests(force: Bool = false) async {
        let targets = entries.map(\.transportURL).filter { (force || manifests[$0] == nil) && !Self.isDeviceLocal($0) }
        guard !targets.isEmpty else { return }
        let client = self.client
        let results = await withTaskGroup(of: (URL, Result<AddonManifest, Error>).self) { group in
            for url in targets {
                group.addTask {
                    do { return (url, .success(try await client.fetchManifest(url, useCache: !force))) }
                    catch { return (url, .failure(error)) }
                }
            }
            var out: [(URL, Result<AddonManifest, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (url, result) in results {
            switch result {
            case .success(let m):
                manifests[url] = m
                failures[url] = nil
            case .failure(let e):
                failures[url] = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                log.warning("manifeste indisponible \(Redactor.redact(url: url)) : \(e)")
            }
        }
        persist()
        notify()
    }

    /// Ajoute un addon à partir d'une URL saisie (valide le manifeste d'abord).
    @discardableResult
    public func install(_ input: String) async throws -> AddonDescriptor {
        let descriptor = try await client.descriptor(for: input)
        if let i = entries.firstIndex(where: { $0.transportURL == descriptor.transportURL }) {
            entries[i].enabled = true
        } else {
            entries.append(Entry(transportURL: descriptor.transportURL, origin: .local, enabled: true))
        }
        manifests[descriptor.transportURL] = descriptor.manifest
        failures[descriptor.transportURL] = nil
        persist()
        notify()
        log.info("addon installé : \(descriptor.manifest.name)")
        return descriptor
    }

    public func remove(_ url: URL) {
        entries.removeAll { $0.transportURL == url }
        manifests[url] = nil
        failures[url] = nil
        persist()
        notify()
    }

    public func setEnabled(_ url: URL, _ enabled: Bool) {
        guard let i = entries.firstIndex(where: { $0.transportURL == url }) else { return }
        entries[i].enabled = enabled
        persist()
        notify()
    }

    public func move(_ url: URL, by offset: Int) {
        guard let i = entries.firstIndex(where: { $0.transportURL == url }) else { return }
        let j = max(0, min(entries.count - 1, i + offset))
        guard i != j else { return }
        let e = entries.remove(at: i)
        entries.insert(e, at: j)
        persist()
        notify()
    }

    /// Remplace les addons « compte » par la collection du compte, en
    /// conservant les ajouts locaux à la suite.
    public func applyAccountCollection(_ descriptors: [AddonDescriptor]) {
        let locals = entries.filter { $0.origin == .local && !descriptors.map(\.transportURL).contains($0.transportURL) }
        let previous = Dictionary(entries.map { ($0.transportURL, $0.enabled) }, uniquingKeysWith: { a, _ in a })
        entries = descriptors.map { Entry(transportURL: $0.transportURL, origin: .account, enabled: previous[$0.transportURL] ?? true) } + locals
        for d in descriptors { manifests[d.transportURL] = d.manifest; failures[d.transportURL] = nil }
        persist()
        notify()
        log.info("collection du compte appliquée : \(descriptors.count) addons, \(locals.count) locaux")
    }

    /// Retour aux addons par défaut (déconnexion).
    public func resetToDefaults() {
        entries = Self.defaultAddonURLs.map { Entry(transportURL: $0, origin: .defaults, enabled: true) }
        manifests = manifests.filter { Self.defaultAddonURLs.contains($0.key) }
        failures.removeAll()
        persist()
        notify()
    }

    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify() { for c in observers.values { c.yield() } }

    private func persist() {
        secrets.encodeSecret(entries, forKey: Self.entriesKey)
        var dict: [String: AddonManifest] = [:]
        for (k, v) in manifests { dict[k.absoluteString] = v }
        cache.encode(dict, forKey: Self.manifestsKey)
    }
}
