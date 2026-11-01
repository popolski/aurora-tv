import Foundation

/// Erreur renvoyée par l'API Stremio (`{"error": {"message", "code"}}`).
public enum StremioAPIError: Error, Sendable, Equatable, LocalizedError {
    case api(code: Int, message: String)
    case network(NetworkError)
    case unexpectedResponse(String)
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .api(_, let message):
            // Messages serveur en anglais ; on traduit les plus courants.
            let lower = message.lowercased()
            if lower.contains("wrong") && lower.contains("password") { return "Mot de passe incorrect." }
            if lower.contains("user not found") || lower.contains("no user") { return "Compte introuvable." }
            if lower.contains("session") { return "Session expirée : reconnectez-vous." }
            return "Stremio : \(message)"
        case .network(let e): return e.errorDescription
        case .unexpectedResponse: return "Réponse inattendue du serveur Stremio."
        case .notAuthenticated: return "Non connecté."
        }
    }

    /// La session n'est plus valide (jeton révoqué/expiré).
    public var isSessionInvalid: Bool {
        if case .api(_, let message) = self { return message.lowercased().contains("session") }
        return false
    }
}

/// Utilisateur Stremio (sous-ensemble utile).
public struct StremioUser: Sendable, Hashable, Codable {
    public var id: String
    public var email: String
    public var avatar: String?

    enum CodingKeys: String, CodingKey { case id = "_id", email, avatar }

    public init(id: String, email: String, avatar: String? = nil) { self.id = id; self.email = email; self.avatar = avatar }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(forKey: .id) ?? ""
        email = c.lenientString(forKey: .email) ?? ""
        avatar = c.lenientString(forKey: .avatar)
    }
}

/// Session authentifiée. Le jeton est stocké dans le trousseau, jamais journalisé.
public struct StremioSession: Sendable, Hashable, Codable {
    public var authKey: String
    public var user: StremioUser
    public init(authKey: String, user: StremioUser) { self.authKey = authKey; self.user = user }
}

/// Code de liaison (connexion depuis un autre appareil, comme les applications TV officielles).
public struct LinkCode: Sendable, Hashable, Codable {
    public var code: String
    public var link: String
    public var qrcode: String
}

/// Client de l'API de compte Stremio.
///
/// ⚠️ API **non officielle et non documentée**. Les formats proviennent du
/// code source de `stremio-core` (client Rust officiel, branche `development`) :
/// - `POST https://api.strem.io/api/<méthode>`, corps JSON ;
/// - réponse `{"result": …}` ou `{"error": {"message", "code"}}` ;
/// - liaison : `GET https://link.stremio.com/api/v2/create|read`.
/// Stremio peut modifier ces points d'accès sans préavis.
public struct StremioAPI: Sendable {
    public var baseURL: URL
    public var linkBaseURL: URL
    private let http: any HTTPClient
    private let log = LogChannel("stremio-api")

    public init(http: any HTTPClient,
                baseURL: URL = URL(string: "https://api.strem.io")!,
                linkBaseURL: URL = URL(string: "https://link.stremio.com")!) {
        self.http = http; self.baseURL = baseURL; self.linkBaseURL = linkBaseURL
    }

    // MARK: Authentification

    public func login(email: String, password: String) async throws -> StremioSession {
        let body: [String: JSONValue] = [
            "type": .string("Login"), "email": .string(email), "password": .string(password), "facebook": .bool(false),
        ]
        return try await authResult(method: "login", body: body)
    }

    public func loginWithToken(_ token: String) async throws -> StremioSession {
        try await authResult(method: "loginWithToken", body: ["type": .string("LoginWithToken"), "token": .string(token)])
    }

    public func logout(authKey: String) async {
        _ = try? await call(method: "logout", body: ["type": .string("Logout"), "authKey": .string(authKey)])
    }

    public func getUser(authKey: String) async throws -> StremioUser {
        let result = try await call(method: "getUser", body: ["type": .string("GetUser"), "authKey": .string(authKey)])
        return try decode(StremioUser.self, from: result)
    }

    /// Crée un code de liaison à afficher (code + QR vers stremio.com).
    public func createLinkCode() async throws -> LinkCode {
        let url = try linkURL("create", query: [URLQueryItem(name: "type", value: "Create")])
        let result = try await getResult(url)
        return try decode(LinkCode.self, from: result)
    }

    /// Interroge le code : renvoie le jeton une fois la liaison validée par
    /// l'utilisateur, `nil` tant qu'elle ne l'est pas.
    public func readLinkCode(_ code: String) async throws -> String? {
        let url = try linkURL("read", query: [URLQueryItem(name: "type", value: "Read"), URLQueryItem(name: "code", value: code)])
        do {
            let result = try await getResult(url)
            return result["authKey"]?.stringValue
        } catch StremioAPIError.api {
            // Le serveur répond par une erreur tant que le code n'est pas validé
            // (sémantique exacte non documentée).
            return nil
        }
    }

    // MARK: Addons

    public func addonCollection(authKey: String) async throws -> [AddonDescriptor] {
        let result = try await call(method: "addonCollectionGet",
                                    body: ["type": .string("AddonCollectionGet"), "authKey": .string(authKey), "update": .bool(true)])
        guard case .array(let raw)? = result["addons"] else { throw StremioAPIError.unexpectedResponse("addons absent") }
        // Décodage individuel : un addon invalide n'empêche pas les autres.
        return raw.compactMap { value in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(AddonDescriptor.self, from: data)
        }
    }

    // MARK: Bibliothèque (datastore)

    /// `datastoreMeta` : liste `[id, mtime(ms)]` pour une synchronisation incrémentale.
    public func libraryMeta(authKey: String) async throws -> [String: Date] {
        let result = try await call(method: "datastoreMeta",
                                    body: ["authKey": .string(authKey), "collection": .string("libraryItem")])
        guard case .array(let pairs) = result else { throw StremioAPIError.unexpectedResponse("datastoreMeta") }
        var out: [String: Date] = [:]
        for pair in pairs {
            guard case .array(let p) = pair, p.count >= 2, let id = p[0].stringValue, let ms = p[1].doubleValue else { continue }
            out[id] = Date(timeIntervalSince1970: ms / 1000)
        }
        return out
    }

    public func libraryGet(authKey: String, ids: [String]? = nil) async throws -> [LibraryItem] {
        var body: [String: JSONValue] = ["authKey": .string(authKey), "collection": .string("libraryItem")]
        if let ids {
            body["ids"] = .array(ids.map { .string($0) })
            body["all"] = .bool(false)
        } else {
            body["ids"] = .array([])
            body["all"] = .bool(true)
        }
        let result = try await call(method: "datastoreGet", body: body, maxBytes: 24 * 1024 * 1024, timeout: 60)
        guard case .array(let raw) = result else { throw StremioAPIError.unexpectedResponse("datastoreGet") }
        return raw.compactMap { value in
            guard case .object(let o) = value else { return nil }
            return try? LibraryItem(stremioJSON: o)
        }
    }

    public func libraryPut(authKey: String, items: [LibraryItem]) async throws {
        guard !items.isEmpty else { return }
        let body: [String: JSONValue] = [
            "authKey": .string(authKey), "collection": .string("libraryItem"),
            "changes": .array(items.map { .object($0.stremioJSON()) }),
        ]
        _ = try await call(method: "datastorePut", body: body, timeout: 30)
    }

    // MARK: Transport

    private func authResult(method: String, body: [String: JSONValue]) async throws -> StremioSession {
        let result = try await call(method: method, body: body)
        guard let key = result["authKey"]?.stringValue, !key.isEmpty else {
            throw StremioAPIError.unexpectedResponse("authKey absent")
        }
        let user = (result["user"]).flatMap { try? decode(StremioUser.self, from: $0) } ?? StremioUser(id: "", email: "")
        return StremioSession(authKey: key, user: user)
    }

    func call(method: String, body: [String: JSONValue], maxBytes: Int = 4 * 1024 * 1024, timeout: TimeInterval = 20) async throws -> JSONValue {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent(method)
        let data = try JSONEncoder().encode(JSONValue.object(body))
        let request = HTTPRequest(url: url, method: .post, headers: ["Content-Type": "application/json"], body: data,
                                  timeout: timeout, maxBytes: maxBytes)
        return try await send(request, label: method)
    }

    private func getResult(_ url: URL) async throws -> JSONValue {
        try await send(HTTPRequest(url: url, timeout: 15, maxBytes: 256 * 1024), label: url.lastPathComponent)
    }

    private func send(_ request: HTTPRequest, label: String) async throws -> JSONValue {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let e as NetworkError {
            log.warning("\(label) : \(e)")
            throw StremioAPIError.network(e)
        }
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.data)
        if let error = json?["error"], error != .null {
            let message = error["message"]?.stringValue ?? error.stringValue ?? "erreur inconnue"
            let code = Int(error["code"]?.doubleValue ?? 0)
            log.info("\(label) : erreur API \(code)")
            throw StremioAPIError.api(code: code, message: message)
        }
        guard (200..<300).contains(response.status) else { throw StremioAPIError.network(.httpStatus(response.status)) }
        guard let result = json?["result"] else { throw StremioAPIError.unexpectedResponse("result absent") }
        log.debug("\(label) : OK (\(response.data.count) o)")
        return result
    }

    private func linkURL(_ action: String, query: [URLQueryItem]) throws -> URL {
        var comps = URLComponents(url: linkBaseURL.appendingPathComponent("api/v2/\(action)"), resolvingAgainstBaseURL: false)
        comps?.queryItems = query
        guard let url = comps?.url else { throw StremioAPIError.unexpectedResponse("URL de liaison") }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw StremioAPIError.unexpectedResponse("\(T.self)")
        }
    }
}
