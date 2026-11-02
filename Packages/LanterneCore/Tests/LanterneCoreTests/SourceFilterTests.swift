import Foundation
import Testing
@testable import LanterneCore

@Suite("Filtres de sources")
struct SourceFilterTests {
    let addonA = makeAddon(id: "a", host: "a.example", resources: [ManifestResource(name: "stream")])
    let addonB = makeAddon(id: "b", host: "b.example", resources: [ManifestResource(name: "stream")])

    func source(_ text: String, index: Int, addon: AddonDescriptor) -> RankedSource {
        let stream = StreamItem(source: .url(URL(string: "https://example.com/\(addon.manifest.id)\(index).mkv")!), name: "A", description: text)
        return SourceRanker.analyze(stream, addon: addon, addonIndex: 0, indexInAddon: index, streamingServer: nil)
    }

    var sample: [RankedSource] {
        [
            source("Movie 1080p WEB-DL VOSTFR x264", index: 0, addon: addonA),
            source("Movie 2160p REMUX DV HEVC MULTi VFF", index: 1, addon: addonA),
            source("Movie 2160p WEB-DL HDR10 ENG", index: 2, addon: addonB),
            source("Movie 720p", index: 3, addon: addonB),
        ]
    }

    @Test func noFilterKeepsEverything() {
        #expect(SourceFilter().apply(sample).count == 4)
    }

    @Test func resolutionAndLanguageCounts() {
        let filter = SourceFilter()
        let resolutions = filter.resolutionOptions(sample)
        #expect(resolutions.map(\.key) == ["4K", "1080p", "720p"])
        #expect(resolutions.first?.count == 2)
        let languages = filter.languageOptions(sample)
        #expect(languages.first { $0.key == "fr" }?.count == 1)
        #expect(languages.first { $0.key == "vostfr" }?.count == 1)
        #expect(languages.contains { $0.key == SourceFilter.unknownKey })
    }

    @Test func combinedFiltersAndFacets() {
        var filter = SourceFilter()
        filter.resolutions = ["4K"]
        #expect(filter.apply(sample).count == 2)
        // Les compteurs de langue tiennent compte du filtre de qualité.
        #expect(filter.languageOptions(sample).first { $0.key == "vostfr" } == nil)
        filter.hdrOnly = true
        #expect(filter.apply(sample).count == 2)
        filter.addons = ["b"]
        #expect(filter.apply(sample).map(\.addonID) == ["b"])
        #expect(filter.addonOptions(sample).map(\.key) == ["a", "b"])
    }
}
