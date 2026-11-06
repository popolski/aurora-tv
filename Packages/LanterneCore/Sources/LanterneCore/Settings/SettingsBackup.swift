import Foundation

/// Sauvegarde des réglages d'Aurora sur le service du NAS (`POST /backup`,
/// `GET /backup/latest.json`).
///
/// Seuls les réglages (`AppSettings`) sont sauvegardés : ni la session du compte
/// Stremio, ni les adresses d'addons (qui peuvent contenir des clés personnelles), ni
/// la bibliothèque — ceux-ci reviennent en se connectant au compte. Le service du NAS
/// n'ayant pas d'authentification, rien de secret ne doit y être déposé.
public struct SettingsBackup: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var app: String
    public var createdAt: Date
    /// Appareil d'origine (ex. « Apple TV », « iPad »).
    public var device: String
    public var settings: AppSettings

    public init(settings: AppSettings, device: String, createdAt: Date = Date()) {
        self.version = Self.currentVersion
        self.app = "Aurora"
        self.createdAt = createdAt
        self.device = device
        self.settings = settings
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public enum RestoreError: Error, Equatable {
        case notABackup
        case newerVersion(Int)
    }

    /// Sauvegarde lue sur le NAS : refusée si ce n'est pas une sauvegarde d'Aurora, ou si
    /// elle vient d'une version plus récente du format. Les réglages inconnus sont ignorés
    /// et les absents gardent leur valeur par défaut (décodage tolérant d'`AppSettings`).
    public static func decode(_ data: Data) throws -> SettingsBackup {
        guard let backup = try? decoder.decode(SettingsBackup.self, from: data), backup.app == "Aurora" else {
            throw RestoreError.notABackup
        }
        guard backup.version <= currentVersion else { throw RestoreError.newerVersion(backup.version) }
        return backup
    }

    /// Réglages à appliquer : ceux de la sauvegarde, en gardant l'adresse du NAS actuelle
    /// (celle qui vient de servir à la lire).
    public func restoring(onto current: AppSettings) -> AppSettings {
        var restored = settings
        restored.trailers.serverURL = current.trailers.serverURL
        return restored
    }
}

extension TrailerLink {
    /// `POST <serveur>/backup` : dépose une sauvegarde des réglages.
    public static func backupURL(server: URL) -> URL {
        server.appendingPathComponent("backup")
    }

    /// `GET <serveur>/backup/latest.json` : dernière sauvegarde déposée.
    public static func latestBackupURL(server: URL) -> URL {
        server.appendingPathComponent("backup").appendingPathComponent("latest.json")
    }
}
