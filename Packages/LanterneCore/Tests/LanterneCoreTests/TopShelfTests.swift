import Foundation
import Testing
@testable import LanterneCore

@Suite("Top Shelf")
struct TopShelfTests {
    @Test func readsAppGroupFromProvision() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array><string>group.io.github.popolski.lanterne.ABCDE12345</string></array>
        </dict></dict></plist>
        """
        // Le profil réel est un plist entouré d'une signature binaire.
        var data = Data([0x30, 0x82, 0x01, 0x00, 0xFF])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xA0, 0x82]))
        #expect(SharedContainer.groupID(fromProvision: data) == "group.io.github.popolski.lanterne.ABCDE12345")
        #expect(SharedContainer.groupID(fromProvision: Data("pas un profil".utf8)) == nil)
    }

    @Test func configRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.topshelf.\(UUID().uuidString)"))
        TopShelfConfig(trailerServer: "http://192.168.1.20:8787").save(to: defaults)
        let loaded = TopShelfConfig.load(from: defaults)
        #expect(loaded?.server?.host == "192.168.1.20")
        #expect(TopShelfConfig(trailerServer: "javascript:alert(1)").server == nil)
    }

    @Test func catalogURL() {
        #expect(TopShelfFeed.catalogURL(year: 2026)?.absoluteString
                == "https://v3-cinemeta.strem.io/catalog/movie/year/genre=2026.json")
        #expect(TopShelfFeed.metaURL(id: "tt0111161")?.absoluteString
                == "https://v3-cinemeta.strem.io/meta/movie/tt0111161.json")
        #expect(TopShelfFeed.metaURL(id: "../x") == nil)
    }

    @Test func latestKeepsReleasedMoviesWithBackdrops() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bg = URL(string: "https://example.org/bg.jpg")
        let metas = [
            MetaItem(id: "tt1", type: "movie", name: "Ancien", background: bg, released: now.addingTimeInterval(-100 * 86_400)),
            MetaItem(id: "tt2", type: "movie", name: "Récent", background: bg, released: now.addingTimeInterval(-5 * 86_400)),
            MetaItem(id: "tt3", type: "movie", name: "À venir", background: bg, released: now.addingTimeInterval(5 * 86_400)),
            MetaItem(id: "tt4", type: "movie", name: "Sans image", released: now.addingTimeInterval(-1 * 86_400)),
            MetaItem(id: "tt2", type: "movie", name: "Doublon", background: bg, released: now),
        ]
        #expect(TopShelfFeed.latest(metas, now: now).map(\.id) == ["tt2", "tt1"])
    }

    @Test func deepLinksRoundTripAndRejectGarbage() throws {
        let link = DeepLink(action: .play, type: "movie", id: "tt0111161", name: "Les Évadés")
        let url = try #require(link.url)
        #expect(url.absoluteString.hasPrefix("aurora://play/movie/tt0111161"))
        #expect(DeepLink(url: url) == link)
        for bad in ["https://play/movie/tt1", "aurora://delete/movie/tt1", "aurora://meta/channel/tt1",
                    "aurora://meta/movie/..%2F..", "aurora://meta/movie/..", "aurora://meta/movie", "aurora://meta/movie/tt1/extra"] {
            #expect(DeepLink(url: URL(string: bad)!) == nil, "\(bad)")
        }
    }

    @Test func parsesRuntimes() {
        func seconds(_ s: String) -> TimeInterval? { MetaItem(id: "x", type: "movie", name: "x", runtime: s).runtimeSeconds }
        #expect(seconds("148 min") == 148 * 60)
        #expect(seconds("2h 28min") == 2 * 3600 + 28 * 60)
        #expect(seconds("1 h 05") == 3600 + 5 * 60)
        #expect(seconds("2h") == 7200)
        #expect(seconds("N/A") == nil)
    }
}
