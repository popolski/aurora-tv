import Foundation
import Synchronization
@testable import LanterneCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    enum FixtureError: Error { case missing(String) }
}

/// Client HTTP simulé : chaque requête est traitée par `handler`.
final class MockHTTPClient: HTTPClient {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let handler: Handler
    private let log = Mutex<[HTTPRequest]>([])

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [HTTPRequest] { log.withLock { $0 } }
    var requestCount: Int { log.withLock { $0.count } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        return try await handler(request)
    }

    static func json(_ data: Data, status: Int = 200, url: URL) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: data, url: url)
    }

    /// Route par suffixe de chemin → fixture.
    static func routes(_ table: [String: String], delay: TimeInterval = 0) -> MockHTTPClient {
        MockHTTPClient { request in
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let path = request.url.absoluteString
            for (suffix, fixture) in table where path.hasSuffix(suffix) || path.contains(suffix) {
                return json(try Fixture.data(fixture), url: request.url)
            }
            return HTTPResponse(status: 404, data: Data(), url: request.url)
        }
    }
}

func makeManifest(id: String, name: String? = nil, resources: [ManifestResource], types: [String] = ["movie", "series"],
                  idPrefixes: [String]? = ["tt"], catalogs: [ManifestCatalog] = []) -> AddonManifest {
    AddonManifest(id: id, version: "1.0.0", name: name ?? id, types: types, resources: resources,
                  idPrefixes: idPrefixes, catalogs: catalogs)
}

func makeAddon(id: String, host: String, resources: [ManifestResource], catalogs: [ManifestCatalog] = []) -> AddonDescriptor {
    AddonDescriptor(transportURL: URL(string: "https://\(host)/manifest.json")!,
                    manifest: makeManifest(id: id, resources: resources, catalogs: catalogs))
}

func date(_ iso: String) -> Date { StremioDate.parse(iso)! }
