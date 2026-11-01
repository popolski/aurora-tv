import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Stockage clé-valeur d'octets.
///
/// **Contrainte tvOS** : seul `UserDefaults` est un stockage local
/// persistant garanti (Apple le limite à environ 500 Ko par application) ; les
/// fichiers, y compris dans `Library/Caches`, peuvent être purgés par le système
/// quand l'espace manque. Lanterne garde donc l'essentiel (réglages,
/// progression récente) dans `UserDefaults`, les données volumineuses en cache
/// fichier reconstructible, et les secrets dans le trousseau.
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

extension KeyValueStore {
    public func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value else { set(nil, forKey: key); return }
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}

public final class UserDefaultsStore: KeyValueStore {
    nonisolated(unsafe) private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "lanterne.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: prefix + key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }

    /// Taille approximative occupée par Lanterne dans UserDefaults.
    public func approximateFootprint() -> Int {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(prefix) }
            .reduce(0) { total, pair in total + ((pair.value as? Data)?.count ?? 64) }
    }
}

/// Stockage fichier (cache purgeable) : un fichier par clé.
public final class FileStore: KeyValueStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Répertoire `Library/Caches/<sous-dossier>` de l'application.
    public static func caches(subdirectory: String) -> FileStore {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileStore(directory: base.appendingPathComponent(subdirectory, isDirectory: true))
    }

    private func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }

    public func data(forKey key: String) -> Data? { try? Data(contentsOf: url(key)) }

    public func set(_ data: Data?, forKey key: String) {
        let target = url(key)
        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: target)
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// Stockage mémoire (tests, aperçus).
public final class InMemoryStore: KeyValueStore {
    private let storage = Mutex<[String: Data]>([:])
    public init() {}
    public func data(forKey key: String) -> Data? { storage.withLock { $0[key] } }
    public func set(_ data: Data?, forKey key: String) { storage.withLock { $0[key] = data } }
}

/// Stockage de secrets (jeton de session, URL d'addons configurés).
public protocol SecretStore: Sendable {
    func secret(forKey key: String) -> Data?
    @discardableResult func setSecret(_ data: Data?, forKey key: String) -> Bool
}

extension SecretStore {
    public func decodeSecret<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = secret(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    public func encodeSecret<T: Encodable>(_ value: T?, forKey key: String) -> Bool {
        guard let value else { return setSecret(nil, forKey: key) }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return setSecret(data, forKey: key)
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: Data]>([:])
    public init() {}
    public func secret(forKey key: String) -> Data? { storage.withLock { $0[key] } }
    @discardableResult public func setSecret(_ data: Data?, forKey key: String) -> Bool {
        storage.withLock { $0[key] = data }
        return true
    }
}

#if canImport(Security)
/// Trousseau (Keychain) : données chiffrées, conservées lors des mises à jour
/// de l'application tant que l'identifiant d'équipe de signature ne change pas.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String) { self.service = service }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func secret(forKey key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { LogChannel("keychain").warning("lecture \(key) : statut \(status)") }
            return nil
        }
        return result as? Data
    }

    @discardableResult
    public func setSecret(_ data: Data?, forKey key: String) -> Bool {
        let query = baseQuery(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { LogChannel("keychain").error("écriture \(key) : statut \(status)") }
        return status == errSecSuccess
    }
}
#endif
