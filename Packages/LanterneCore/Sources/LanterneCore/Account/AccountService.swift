import Foundation

/// Compte Stremio : session, liaison par code, synchronisation addons/bibliothèque.
public actor AccountService {
    public enum SyncState: Sendable, Equatable {
        case idle
        case syncing
        case succeeded(Date)
        case failed(String)
    }

    private let api: StremioAPI
    private let secrets: any SecretStore
    private let library: LibraryStore
    private let registry: AddonRegistry
    public private(set) var session: StremioSession?
    public private(set) var syncState: SyncState = .idle
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let log = LogChannel("account")

    static let sessionKey = "stremio.session.v1"

    public init(api: StremioAPI, secrets: any SecretStore, library: LibraryStore, registry: AddonRegistry) {
        self.api = api
        self.secrets = secrets
        self.library = library
        self.registry = registry
        self.session = secrets.decodeSecret(StremioSession.self, forKey: Self.sessionKey)
    }

    public var isLoggedIn: Bool { session != nil }

    // MARK: Connexion

    public func login(email: String, password: String) async throws {
        let s = try await api.login(email: email, password: password)
        try await adopt(s)
    }

    public func createLinkCode() async throws -> LinkCode {
        try await api.createLinkCode()
    }

    /// Interroge le code jusqu'à validation, expiration (`timeout`) ou annulation.
    public func waitForLink(_ code: LinkCode, timeout: TimeInterval = 300, interval: TimeInterval = 3) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let key = try await api.readLinkCode(code.code) {
                let user = (try? await api.getUser(authKey: key)) ?? StremioUser(id: "", email: "")
                try await adopt(StremioSession(authKey: key, user: user))
                return true
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    private func adopt(_ s: StremioSession) async throws {
        guard secrets.encodeSecret(s, forKey: Self.sessionKey) else {
            throw StremioAPIError.unexpectedResponse("enregistrement du jeton dans le trousseau impossible")
        }
        session = s
        log.info("connecté (\(s.user.email.isEmpty ? "compte" : "e-mail masqué"))")
        notify()
        await syncAll()
    }

    /// Déconnexion. `eraseLocalData` efface aussi bibliothèque et addons locaux.
    public func logout(eraseLocalData: Bool) async {
        if let key = session?.authKey { await api.logout(authKey: key) }
        secrets.setSecret(nil, forKey: Self.sessionKey)
        session = nil
        syncState = .idle
        if eraseLocalData {
            await library.eraseAll()
            await registry.resetToDefaults()
            await registry.refreshManifests()
        }
        log.info("déconnecté (données locales \(eraseLocalData ? "effacées" : "conservées"))")
        notify()
    }

    // MARK: Synchronisation

    public func syncAll() async {
        guard let key = session?.authKey else { return }
        guard syncState != .syncing else { return }
        syncState = .syncing
        notify()
        do {
            let addons = try await api.addonCollection(authKey: key)
            if !addons.isEmpty { await registry.applyAccountCollection(addons) }
            try await syncLibrary(authKey: key)
            syncState = .succeeded(Date())
        } catch let e as StremioAPIError {
            syncState = .failed(e.errorDescription ?? "échec")
            log.warning("synchronisation : \(e)")
            if e.isSessionInvalid {
                secrets.setSecret(nil, forKey: Self.sessionKey)
                session = nil
            }
        } catch {
            syncState = .failed("\(error.localizedDescription)")
        }
        notify()
    }

    /// Envoie seulement les modifications locales (appelé après une lecture).
    public func pushLibraryChanges() async {
        guard let key = session?.authKey else { return }
        do {
            try await push(authKey: key)
        } catch {
            log.warning("envoi bibliothèque différé : \(error)")
        }
    }

    private func syncLibrary(authKey: String) async throws {
        // 1. Tirage incrémental : seulement les éléments plus récents côté serveur.
        let local = await library.mtimes()
        var pulled: [LibraryItem]
        do {
            let remote = try await api.libraryMeta(authKey: authKey)
            let newer = remote.filter { id, mtime in (local[id].map { mtime > $0 } ?? true) }.map(\.key)
            pulled = []
            for chunk in stride(from: 0, to: newer.count, by: 100).map({ Array(newer[$0..<min($0 + 100, newer.count)]) }) {
                pulled += try await api.libraryGet(authKey: authKey, ids: chunk)
            }
        } catch {
            log.info("datastoreMeta indisponible, tirage complet : \(error)")
            pulled = try await api.libraryGet(authKey: authKey)
        }
        let changed = await library.merge(remote: pulled)
        log.info("bibliothèque : \(pulled.count) reçus, \(changed) appliqués")
        // 2. Envoi des modifications locales.
        try await push(authKey: authKey)
    }

    private func push(authKey: String) async throws {
        let now = Date()
        let dirty = await library.dirtyItems().filter { $0.shouldSync(now: now) }
        guard !dirty.isEmpty else { return }
        for start in stride(from: 0, to: dirty.count, by: 50) {
            let chunk = Array(dirty[start..<min(start + 50, dirty.count)])
            try await api.libraryPut(authKey: authKey, items: chunk)
            await library.markClean(chunk.map(\.id))
        }
        log.info("bibliothèque : \(dirty.count) modifications envoyées")
    }

    // MARK: Observation

    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify() { for c in observers.values { c.yield() } }
}
