import Foundation
import Synchronization
import Testing
@testable import LanterneCore

@Suite("Client addon")
struct AddonClientTests {
    let cinemeta = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!

    @Test func fetchesManifestAndCachesResources() async throws {
        let http = MockHTTPClient.routes([
            "/manifest.json": "cinemeta_manifest.json",
            "/catalog/movie/top.json": "catalog_movies.json",
        ])
        let client = AddonClient(http: http)
        let manifest = try await client.fetchManifest(cinemeta)
        let addon = AddonDescriptor(transportURL: cinemeta, manifest: manifest)
        let catalog = try #require(manifest.catalogs.first)
        let first = try await client.catalog(addon, catalog: catalog)
        let second = try await client.catalog(addon, catalog: catalog)
        #expect(first.count == 3 && second.count == 3)
        #expect(http.requestCount == 2, "le second catalogue vient du cache")
    }

    @Test func malformedResponseIsReported() async throws {
        let http = MockHTTPClient { req in HTTPResponse(status: 200, data: Data("<html>".utf8), url: req.url) }
        let client = AddonClient(http: http)
        await #expect(throws: AddonError.self) { _ = try await client.fetchManifest(cinemeta) }
    }

    @Test func httpErrorsAndOfflineAreMapped() async throws {
        let notFound = AddonClient(http: MockHTTPClient { req in HTTPResponse(status: 503, data: Data(), url: req.url) })
        do {
            _ = try await notFound.fetchManifest(cinemeta)
            Issue.record("erreur attendue")
        } catch let e as AddonError {
            #expect(e == .network(.httpStatus(503)))
        }
        let offline = AddonClient(http: MockHTTPClient { _ in throw NetworkError.offline })
        do {
            _ = try await offline.fetchManifest(cinemeta)
            Issue.record("erreur attendue")
        } catch let e as AddonError {
            #expect(e == .network(.offline))
        }
    }

    @Test func refusesCleartextInternetAddons() async {
        let client = AddonClient(http: MockHTTPClient { req in HTTPResponse(status: 200, data: Data(), url: req.url) })
        await #expect(throws: AddonError.network(.insecureURL)) {
            _ = try await client.fetchManifest(URL(string: "http://addon.example.com/manifest.json")!)
        }
        #expect(URLPolicy.isLocalHost("192.168.1.20"))
        #expect(URLPolicy.isLocalHost("nas.local"))
        #expect(URLPolicy.isLocalHost("172.20.0.5"))
        #expect(!URLPolicy.isLocalHost("172.32.0.5"))
        #expect(!URLPolicy.isLocalHost("example.com"))
    }

    @Test func unsupportedResourceIsNotRequested() async throws {
        let http = MockHTTPClient { req in HTTPResponse(status: 200, data: Data("{}".utf8), url: req.url) }
        let client = AddonClient(http: http)
        let addon = makeAddon(id: "meta-only", host: "a.example.com", resources: [.init(name: "meta")])
        await #expect(throws: AddonError.resourceNotSupported) { _ = try await client.streams(addon, type: "movie", id: "tt1") }
        #expect(http.requestCount == 0)
    }

    @Test func deadlineCancelsSlowOperations() async {
        let start = Date()
        await #expect(throws: NetworkError.timeout) {
            _ = try await withDeadline(seconds: 0.2) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("Agrégation multi-addons")
struct AggregatorTests {
    let fast = makeAddon(id: "fast", host: "fast.example.com", resources: [.init(name: "stream"), .init(name: "meta")])
    let slow = makeAddon(id: "slow", host: "slow.example.com", resources: [.init(name: "stream")])
    let broken = makeAddon(id: "broken", host: "broken.example.com", resources: [.init(name: "stream"), .init(name: "meta")])
    let other = makeAddon(id: "kitsu", host: "kitsu.example.com", resources: [.init(name: "stream", types: ["anime"], idPrefixes: ["kitsu:"])])

    func http() -> MockHTTPClient {
        MockHTTPClient { req in
            let host = req.url.host ?? ""
            switch host {
            case "fast.example.com":
                if req.url.path.hasPrefix("/meta/") {
                    return MockHTTPClient.json(try Fixture.data("meta_series.json"), url: req.url)
                }
                return MockHTTPClient.json(try Fixture.data("streams_mixed.json"), url: req.url)
            case "slow.example.com":
                try await Task.sleep(nanoseconds: 3_000_000_000)
                return MockHTTPClient.json(try Fixture.data("streams_mixed.json"), url: req.url)
            case "broken.example.com":
                return HTTPResponse(status: 200, data: Data("not json".utf8), url: req.url)
            default:
                return HTTPResponse(status: 404, data: Data(), url: req.url)
            }
        }
    }

    @Test func streamsArriveProgressivelyAndSlowAddonTimesOut() async {
        let mock = http()
        var aggregator = AddonAggregator(client: AddonClient(http: mock))
        aggregator.streamTimeout = 0.5
        var outcomes: [String: Bool] = [:]
        var order: [String] = []
        for await outcome in aggregator.streams(type: "movie", id: "tt1", addons: [slow, fast, broken, other]) {
            outcomes[outcome.addon.manifest.id] = outcome.value != nil
            order.append(outcome.addon.manifest.id)
        }
        #expect(outcomes == ["fast": true, "slow": false, "broken": false], "addon kitsu non interrogé (préfixe)")
        #expect(order.last == "slow", "l'addon lent arrive en dernier, après expiration")
        #expect(!mock.requests.contains { $0.url.host == "kitsu.example.com" })
    }

    @Test func cancellingStopsTheStream() async {
        let aggregator = AddonAggregator(client: AddonClient(http: http()))
        let task = Task {
            var count = 0
            for await _ in aggregator.streams(type: "movie", id: "tt1", addons: [slow]) { count += 1 }
            return count
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let start = Date()
        _ = await task.value
        #expect(Date().timeIntervalSince(start) < 2, "l'annulation n'attend pas l'addon lent")
    }

    @Test func metaFallsBackToNextAddon() async throws {
        let aggregator = AddonAggregator(client: AddonClient(http: http()))
        let meta = try await aggregator.meta(type: "series", id: "tt0944947", addons: [broken, fast])
        #expect(meta?.name == "Game of Thrones")
    }

    @Test func browsableAndSearchCatalogs() throws {
        let manifest = try Fixture.decode(AddonManifest.self, "cinemeta_manifest.json")
        let addon = AddonDescriptor(transportURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!, manifest: manifest)
        let aggregator = AddonAggregator(client: AddonClient(http: http()))
        #expect(aggregator.browsableCatalogs([addon]).map(\.catalog.id) == ["top", "top"])
        #expect(aggregator.browsableCatalogs([addon], types: ["series"]).count == 1)
        #expect(aggregator.searchCatalogs([addon]).count == 2)
    }
}

@Suite("API Stremio (simulée)")
struct StremioAPITests {
    @Test func loginSendsCoreCompatibleBody() async throws {
        let http = MockHTTPClient { req in
            #expect(req.url.absoluteString == "https://api.strem.io/api/login")
            let body = try JSONDecoder().decode(JSONValue.self, from: req.body ?? Data())
            #expect(body["type"] == .string("Login"))
            #expect(body["email"] == .string("a@example.com"))
            let reply = #"{"result":{"authKey":"secret-key","user":{"_id":"u1","email":"a@example.com"}}}"#
            return MockHTTPClient.json(Data(reply.utf8), url: req.url)
        }
        let session = try await StremioAPI(http: http).login(email: "a@example.com", password: "pw")
        #expect(session.authKey == "secret-key")
        #expect(session.user.id == "u1")
    }

    @Test func apiErrorIsTranslated() async {
        let http = MockHTTPClient { req in MockHTTPClient.json(try Fixture.data("api_error.json"), url: req.url) }
        do {
            _ = try await StremioAPI(http: http).login(email: "a", password: "b")
            Issue.record("erreur attendue")
        } catch let e as StremioAPIError {
            #expect(e == .api(code: 2, message: "Wrong password"))
            #expect(e.errorDescription == "Mot de passe incorrect.")
        } catch {
            Issue.record("type d'erreur inattendu \(error)")
        }
    }

    @Test func linkCodeFlow() async throws {
        let attempts = Counter()
        let http = MockHTTPClient { req in
            let url = req.url.absoluteString
            if url.hasPrefix("https://link.stremio.com/api/v2/create") {
                #expect(url.contains("type=Create"))
                return MockHTTPClient.json(try Fixture.data("link_create.json"), url: req.url)
            }
            if url.hasPrefix("https://link.stremio.com/api/v2/read") {
                #expect(url.contains("code=ABC123"))
                if attempts.increment() < 2 {
                    return MockHTTPClient.json(Data(#"{"error":{"message":"Not linked","code":1}}"#.utf8), url: req.url)
                }
                return MockHTTPClient.json(Data(#"{"result":{"authKey":"linked-key"}}"#.utf8), url: req.url)
            }
            return HTTPResponse(status: 404, data: Data(), url: req.url)
        }
        let api = StremioAPI(http: http)
        let code = try await api.createLinkCode()
        #expect(code.code == "ABC123")
        #expect(try await api.readLinkCode(code.code) == nil)
        #expect(try await api.readLinkCode(code.code) == "linked-key")
    }

    @Test func addonCollectionSkipsInvalidDescriptors() async throws {
        let http = MockHTTPClient { req in MockHTTPClient.json(try Fixture.data("addon_collection.json"), url: req.url) }
        let addons = try await StremioAPI(http: http).addonCollection(authKey: "k")
        #expect(addons.map(\.manifest.id) == ["com.linvo.cinemeta", "org.example.streams", "org.stremio.local"])
        #expect(addons[0].flags.official)
    }

    @Test func datastoreRequestsUseLibraryCollection() async throws {
        let http = MockHTTPClient { req in
            let body = try JSONDecoder().decode(JSONValue.self, from: req.body ?? Data())
            #expect(body["collection"] == .string("libraryItem"))
            if req.url.lastPathComponent == "datastoreGet" {
                #expect(body["all"] == .bool(true))
                return MockHTTPClient.json(try Fixture.data("library_items.json"), url: req.url)
            }
            #expect(req.url.lastPathComponent == "datastorePut")
            guard case .array(let changes)? = body["changes"] else { Issue.record("changes"); throw NetworkError.invalidURL }
            #expect(changes.count == 2)
            return MockHTTPClient.json(Data(#"{"result":{"success":true}}"#.utf8), url: req.url)
        }
        let api = StremioAPI(http: http)
        let items = try await api.libraryGet(authKey: "k")
        #expect(items.count == 2)
        try await api.libraryPut(authKey: "k", items: items)
    }

    @Test func accountSyncMergesAndPushes() async throws {
        let pushed = Counter()
        let http = MockHTTPClient { req in
            switch req.url.lastPathComponent {
            case "addonCollectionGet": return MockHTTPClient.json(try Fixture.data("addon_collection.json"), url: req.url)
            case "datastoreMeta":
                return MockHTTPClient.json(Data(#"{"result":[["tt0944947",1793391300000],["tt0111161",1788249600000]]}"#.utf8), url: req.url)
            case "datastoreGet": return MockHTTPClient.json(try Fixture.data("library_items.json"), url: req.url)
            case "datastorePut":
                pushed.add(1)
                return MockHTTPClient.json(Data(#"{"result":{"success":true}}"#.utf8), url: req.url)
            default: return HTTPResponse(status: 404, data: Data(), url: req.url)
            }
        }
        let secrets = InMemorySecretStore()
        secrets.encodeSecret(StremioSession(authKey: "k", user: .init(id: "u", email: "e")), forKey: AccountService.sessionKey)
        let library = LibraryStore(file: InMemoryStore(), mirror: InMemoryStore(), saveDelay: 10)
        let registry = AddonRegistry(secrets: secrets, cache: InMemoryStore(), client: AddonClient(http: http))
        await library.addToLibrary(LibraryMetaRef(id: "tt9999999", type: "movie", name: "Local"))
        let account = AccountService(api: StremioAPI(http: http), secrets: secrets, library: library, registry: registry)
        await account.syncAll()
        let state = await account.syncState
        guard case .succeeded = state else { Issue.record("sync: \(String(describing: state))"); return }
        #expect(await library.item("tt0944947")?.isInLibrary == true)
        #expect(await library.dirtyItems().isEmpty)
        #expect(pushed.value == 1)
        // « Local Files » (127.0.0.1:11470) reste dans la collection mais n'est jamais interrogé.
        #expect(await registry.activeDescriptors().map(\.manifest.id) == ["com.linvo.cinemeta", "org.example.streams"])
        let local = await registry.statuses().first { $0.manifest?.id == "org.stremio.local" }
        #expect(local?.ignoredNote != nil && local?.failure == nil)
    }

    @Test func deviceLocalAddonsAreRecognized() {
        #expect(AddonRegistry.isDeviceLocal(URL(string: "http://127.0.0.1:11470/local-addon/manifest.json")!))
        #expect(AddonRegistry.isDeviceLocal(URL(string: "http://localhost:7000/manifest.json")!))
        #expect(!AddonRegistry.isDeviceLocal(URL(string: "http://192.168.1.120:7777/c/manifest.json")!))
        #expect(!AddonRegistry.isDeviceLocal(URL(string: "https://nas.example.me/c/manifest.json")!))
    }
}

/// Compteur thread-safe pour les gestionnaires simulés.
final class Counter: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    func increment() -> Int { state.withLock { $0 += 1; return $0 } }
    func add(_ n: Int) { state.withLock { $0 += n } }
}
