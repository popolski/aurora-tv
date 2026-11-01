import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var url: URL
    public var method: Method
    public var headers: [String: String]
    public var body: Data?
    /// Délai maximal total de la requête (et non seulement d'inactivité).
    public var timeout: TimeInterval
    /// Taille maximale acceptée pour le corps de la réponse.
    public var maxBytes: Int

    public init(url: URL, method: Method = .get, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 15, maxBytes: Int = 8 * 1024 * 1024) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
        self.timeout = timeout; self.maxBytes = maxBytes
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data
    public var url: URL
    public init(status: Int, headers: [String: String] = [:], data: Data, url: URL) {
        self.status = status; self.headers = headers; self.data = data; self.url = url
    }

    /// `Cache-Control: max-age=N` éventuel.
    public var maxAge: TimeInterval? {
        guard let cc = headers.first(where: { $0.key.lowercased() == "cache-control" })?.value else { return nil }
        for part in cc.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces).lowercased()
            if p.hasPrefix("max-age="), let v = TimeInterval(p.dropFirst("max-age=".count)) { return v }
        }
        return nil
    }
}

public enum NetworkError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case insecureURL
    case timeout
    case offline
    case tls
    case tooLarge(limit: Int)
    case httpStatus(Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Adresse invalide."
        case .insecureURL: "Adresse non sécurisée refusée."
        case .timeout: "Le serveur n'a pas répondu à temps."
        case .offline: "Pas de connexion réseau."
        case .tls: "Connexion sécurisée impossible (certificat ou TLS)."
        case .tooLarge(let limit): "Réponse trop volumineuse (limite \(limit / 1024) Ko)."
        case .httpStatus(let code): "Erreur du serveur (HTTP \(code))."
        case .transport(let message): "Erreur réseau : \(message)"
        }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Client HTTP basé sur URLSession : délai global, plafond de taille lu en
/// flux (la réponse n'est jamais chargée entièrement si elle dépasse la
/// limite), annulation coopérative.
public final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, configuration: URLSessionConfiguration = .default) {
        let config = configuration
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw NetworkError.invalidURL
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }

        return try await withDeadline(seconds: request.timeout) { [session, urlRequest] in
            do {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw NetworkError.transport("réponse non HTTP") }
                if http.expectedContentLength > Int64(request.maxBytes) {
                    bytes.task.cancel()
                    throw NetworkError.tooLarge(limit: request.maxBytes)
                }
                var data = Data()
                if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > request.maxBytes {
                        bytes.task.cancel()
                        throw NetworkError.tooLarge(limit: request.maxBytes)
                    }
                }
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
                }
                return HTTPResponse(status: http.statusCode, headers: headers, data: data, url: http.url ?? request.url)
            } catch let error as URLError {
                throw Self.map(error)
            }
        }
    }

    static func map(_ error: URLError) -> any Error {
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return NetworkError.timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return NetworkError.offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection:
            return NetworkError.tls
        case .badURL, .unsupportedURL: return NetworkError.invalidURL
        default: return NetworkError.transport(error.localizedDescription)
        }
    }
}

/// Exécute `operation` avec un délai global ; annule l'opération au-delà.
public func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1_000_000_000))
            throw NetworkError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
