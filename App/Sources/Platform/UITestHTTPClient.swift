import Foundation
import LanterneCore

/// Réseau simulé pour les tests d'interface (`-uitest`) : réponses fixes,
/// déterministes, sans dépendre des serveurs Stremio.
nonisolated final class UITestHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 50_000_000)
        let url = request.url
        let path = url.path
        let body: String
        switch true {
        case path.hasSuffix("/manifest.json"):
            body = Self.manifest(host: url.host ?? "test")
        case path.hasPrefix("/catalog/"):
            let items = (1...12).map { i in
                #"{"id":"tt90000\#(String(format: "%02d", i))","type":"movie","name":"Film de test \#(i)","releaseInfo":"2026","description":"Description \#(i)"}"#
            }.joined(separator: ",")
            body = #"{"metas":[\#(items)]}"#
        case path.hasPrefix("/meta/"):
            let id = (url.deletingPathExtension().lastPathComponent)
            body = #"{"meta":{"id":"\#(id)","type":"movie","name":"Film de test","releaseInfo":"2026","runtime":"95 min","description":"Fiche de test.","genres":["Drame"],"cast":["Acteur A","Actrice B"]}}"#
        case path.hasPrefix("/stream/"):
            body = #"{"streams":[{"name":"Test\n1080p","description":"Test.1080p.WEB-DL.x264.AAC.VFF\n💾 1.2 GB","url":"https://127.0.0.1:9/indisponible.mp4"}]}"#
        case path.hasPrefix("/subtitles/"):
            body = #"{"subtitles":[]}"#
        default:
            return HTTPResponse(status: 404, data: Data(), url: url)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], data: Data(body.utf8), url: url)
    }

    static func manifest(host: String) -> String {
        if host.contains("opensubtitles") {
            return #"{"id":"test.subs","version":"1.0.0","name":"Sous-titres de test","types":["movie","series"],"resources":["subtitles"],"idPrefixes":["tt"],"catalogs":[]}"#
        }
        return #"{"id":"test.meta","version":"1.0.0","name":"Addon de test","types":["movie","series"],"idPrefixes":["tt"],"resources":["catalog","meta","stream"],"catalogs":[{"type":"movie","id":"top","name":"Populaires","extra":[{"name":"search"},{"name":"skip"}]},{"type":"movie","id":"new","name":"Nouveautés"}]}"#
    }
}
