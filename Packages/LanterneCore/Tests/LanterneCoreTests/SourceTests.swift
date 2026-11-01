import Foundation
import Testing
@testable import LanterneCore

@Suite("Caractéristiques annoncées")
struct StreamTraitsTests {
    @Test func parsesRemux4KDolbyVision() {
        let t = StreamTraitsParser.parse(text: "Movie.2026.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.Atmos.7.1-GRP\n💾 58.2 GB 👤 120")
        #expect(t.resolution == .uhd2160)
        #expect(t.hdr == [.dolbyVision, .hdr10])
        #expect(t.videoCodec == .hevc)
        #expect(t.audioCodecs == [.trueHD])
        #expect(t.atmos)
        #expect(t.audioChannels == "7.1")
        #expect(t.sourceQuality == .remux)
        #expect(t.seeders == 120)
        #expect(t.sizeLabel != nil)
        #expect(abs(Double(t.sizeBytes ?? 0) - 58.2 * 1_073_741_824) < 1_000_000)
    }

    @Test func parsesFrenchMulti1080p() {
        let t = StreamTraitsParser.parse(text: "Movie.2026.MULTi.VFF.1080p.WEB-DL.x264.DDP5.1\n💾 3,4 Go")
        #expect(t.resolution == .fhd1080)
        #expect(t.isMultiAudio)
        #expect(t.audioLanguages.contains("fr"))
        #expect(t.frenchVariant == "VFF")
        #expect(t.videoCodec == .avc)
        #expect(t.audioCodecs == [.eac3])
        #expect(t.audioChannels == "5.1")
        #expect(t.sourceQuality == .webDL)
        #expect(abs(Double(t.sizeBytes ?? 0) - 3.4 * 1_073_741_824) < 1_000_000, "virgule décimale et unité « Go »")
    }

    @Test func vostfrIsNotFrenchAudio() {
        let t = StreamTraitsParser.parse(text: "Show S01E02 720p VOSTFR WEBRip x265 AAC")
        #expect(t.isVOSTFR)
        #expect(!t.hasFrench)
        #expect(t.resolution == .hd720)
        #expect(t.audioCodecs == [.aac])
        #expect(t.sourceQuality == .webRip)
    }

    @Test func avoidsCommonFalsePositives() {
        // « DVDRip » n'est pas Dolby Vision ; « en » (mot français) n'est pas l'anglais ;
        // « HDR10+ » n'implique pas HDR10 ; « .ts » n'est pas un CAM.
        let a = StreamTraitsParser.parse(text: "Film en version restaurée DVDRip XviD")
        #expect(!a.hdr.contains(.dolbyVision))
        #expect(!a.audioLanguages.contains("en"))
        #expect(a.resolution == .sd)
        #expect(a.videoCodec == .mpeg4)
        let b = StreamTraitsParser.parse(text: "Movie 2160p HDR10+ HEVC")
        #expect(b.hdr == [.hdr10Plus])
        let c = StreamTraitsParser.parse(text: "Live.channel.ts")
        #expect(c.sourceQuality != .cam)
        #expect(c.container == .mpegts)
    }

    @Test func flagsAndCachedMarkers() {
        let t = StreamTraitsParser.parse(text: "[RD+] Torrentio\n🇫🇷 🇬🇧 | 4K | DTS-HD MA")
        #expect(t.debridCached)
        #expect(t.audioLanguages == ["fr", "en"])
        #expect(t.audioCodecs == [.dtsHDMA])
        #expect(StreamTraitsParser.parse(text: "[RD download] Torrentio").debridCached == false)
    }

    @Test func structuredSizeWinsOverText() throws {
        let r = try Fixture.decode(StreamsResponse.self, "streams_mixed.json")
        let t = StreamTraitsParser.parse(r.streams[0])
        #expect(t.sizeBytes == 62_491_426_816)
        #expect(t.sizeFromHints)
        #expect(t.container == .mkv)
    }
}

@Suite("Lisibilité")
struct PlayabilityTests {
    @Test func classifiesSources() throws {
        let r = try Fixture.decode(StreamsResponse.self, "streams_mixed.json")
        func classify(_ i: Int, server: URL? = nil) -> Playability {
            let s = r.streams[i]
            return PlayabilityClassifier.classify(s, traits: StreamTraitsParser.parse(s), streamingServer: server)
        }
        let mkv = try #require(classify(0).playable)
        #expect(mkv.fit == .needsFFmpeg)
        #expect(mkv.headers["Referer"] == "https://example.com/")
        #expect(classify(1).playable?.fit == .native)
        #expect(!classify(2).isPlayable, "torrent sans serveur")
        #expect(classify(4).isPlayable == false, "YouTube")
        let server = URL(string: "http://192.168.1.20:11470")!
        guard case .viaStreamingServer(let p) = classify(2, server: server) else { Issue.record("serveur attendu"); return }
        #expect(p.url.absoluteString ==
            "http://192.168.1.20:11470/abcdef0123456789abcdef0123456789abcdef01/2?tr=tracker:udp://tracker.example.com:80&tr=dht:abcdef")
    }

    @Test func torrentWithoutFileIndexUsesMinusOne() {
        let url = PlayabilityClassifier.torrentURL(server: URL(string: "http://nas.local:11470/")!,
                                                   infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                                                   fileIndex: nil, announce: [], fileMustInclude: [])
        #expect(url?.absoluteString == "http://nas.local:11470/abcdef0123456789abcdef0123456789abcdef01/-1")
    }

    @Test func engineFitHeuristics() {
        var t = StreamTraits()
        t.container = .mp4
        t.audioCodecs = [.eac3]
        #expect(PlayabilityClassifier.fit(for: t) == .native)
        t.audioCodecs = [.dts]
        #expect(PlayabilityClassifier.fit(for: t) == .needsFFmpeg)
        t = StreamTraits()
        #expect(PlayabilityClassifier.fit(for: t) == .unknown)
        t.container = .hls
        #expect(PlayabilityClassifier.fit(for: t) == .native)
    }
}

@Suite("Tri des sources")
struct SourceRankerTests {
    let addon = makeAddon(id: "a", host: "a.example.com", resources: [.init(name: "stream")])

    func source(_ text: String, index: Int, url: String? = nil, addonIndex: Int = 0) -> RankedSource {
        let stream = StreamItem(source: .url(URL(string: url ?? "https://example.com/\(index).mkv")!), name: "A", description: text)
        return SourceRanker.analyze(stream, addon: addon, addonIndex: addonIndex, indexInAddon: index, streamingServer: nil)
    }

    var sample: [RankedSource] {
        [
            source("Movie 1080p WEB-DL VOSTFR x264", index: 0),
            source("Movie 2160p REMUX DV HEVC MULTi VFF 60 GB", index: 1),
            source("Movie 720p VFF WEBRip 1.2 GB", index: 2),
            source("Movie 1080p BluRay VFF x265 8 GB", index: 3),
            source("Movie HDCAM VFF", index: 4),
            source("Movie 2160p WEB-DL HDR ENG 20 GB", index: 5),
        ]
    }

    @Test func qualityModeWithFrenchPreference() {
        var p = SourcePreferences()
        p.sortMode = .quality
        p.language = .vf
        p.preferCompatible = false
        let ranked = SourceRanker(preferences: p).rank(sample)
        #expect(ranked.map(\.indexInAddon) == [1, 3, 2, 0, 5], "VF d'abord, CAM masqué")
    }

    @Test func prefer1080pMode() {
        var p = SourcePreferences()
        p.sortMode = .prefer1080p
        p.language = .none
        p.preferCompatible = false
        let ranked = SourceRanker(preferences: p).rank(sample)
        #expect(ranked.prefix(2).map(\.indexInAddon) == [3, 0], "1080p BluRay avant 1080p WEB-DL")
        #expect(ranked[2].indexInAddon == 2, "puis 720p")
    }

    @Test func smallestMode() {
        var p = SourcePreferences()
        p.sortMode = .smallest
        p.language = .none
        p.preferCompatible = false
        let ranked = SourceRanker(preferences: p).rank(sample)
        #expect(ranked.first?.indexInAddon == 2)
        #expect(ranked.last?.traits.sizeBytes == nil, "taille inconnue en dernier")
    }

    @Test func previouslyUsedFirstAndCamVisibleWhenAllowed() {
        var p = SourcePreferences()
        p.hideCam = false
        let all = sample
        let ranked = SourceRanker(preferences: p, previouslyUsedFingerprint: all[4].stream.fingerprint).rank(all)
        #expect(ranked.first?.indexInAddon == 4)
        #expect(ranked.count == 6)
    }

    @Test func unplayableAlwaysLastAndAutoPickSkipsIt() {
        let yt = SourceRanker.analyze(StreamItem(source: .youtube("x"), name: "YT", description: "2160p REMUX VFF"),
                                      addon: addon, addonIndex: 0, indexInAddon: 9, streamingServer: nil)
        let ranker = SourceRanker(preferences: SourcePreferences())
        let ranked = ranker.rank(sample + [yt])
        #expect(ranked.last?.indexInAddon == 9)
        #expect(ranker.best(sample + [yt])?.indexInAddon == 1)
    }

    @Test func addonOrderMode() {
        var p = SourcePreferences()
        p.sortMode = .addonOrder
        let b = SourceRanker.analyze(StreamItem(source: .url(URL(string: "https://e.com/x.mp4")!), description: "2160p REMUX"),
                                     addon: addon, addonIndex: 1, indexInAddon: 0, streamingServer: nil)
        let a = source("480p", index: 7, addonIndex: 0)
        #expect(SourceRanker(preferences: p).rank([b, a]).map(\.indexInAddon) == [7, 0])
    }

    @Test func titleAndSubtitleSplitDescription() {
        let s = source("Ligne 1\nLigne 2\n\nLigne 3", index: 0)
        #expect(s.title == "Ligne 1")
        #expect(s.subtitle == "Ligne 2 · Ligne 3")
    }
}
