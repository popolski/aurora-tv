import Foundation
import Testing
@testable import LanterneCore

@Suite("Expurgation des journaux")
struct RedactorTests {
    @Test func masksSecretsInText() {
        let s = Redactor.redact(#"{"authKey":"abcdef123456","email":"x"} password=hunter2 Authorization: Bearer tok.en-123"#)
        #expect(!s.contains("abcdef123456"))
        #expect(!s.contains("hunter2"))
        #expect(!s.contains("tok.en-123"))
        #expect(s.contains("\"email\":\"x\""))
    }

    @Test func masksConfiguredAddonURLs() {
        let s = Redactor.redact("GET https://addon.example.com/eyJkZWJyaWQiOiJzZWNyZXQifQ/stream/movie/tt1.json?token=zz")
        #expect(s == "GET https://addon.example.com/\(Redactor.mask)/stream/movie/tt1.json?token=\(Redactor.mask)")
        let plain = Redactor.redact(url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!)
        #expect(plain == "https://v3-cinemeta.strem.io/manifest.json")
    }

    @Test func logStoreNeverKeepsRawSecrets() {
        let store = LogStore(capacity: 20)
        store.log(.info, "test", "authKey=SECRET123 https://a.example.com/k3yk3yk3yk3yk3yk3y99/manifest.json")
        let line = store.exportText()
        #expect(!line.contains("SECRET123"))
        #expect(!line.contains("k3yk3yk3yk3yk3yk3y99"))
        for i in 0..<50 { store.log(.debug, "t", "\(i)") }
        #expect(store.snapshot().count == 20, "tampon circulaire borné")
    }
}

@Suite("Langues et pistes")
struct TrackSelectionTests {
    let tracks: [TrackDescriptor] = [
        .init(id: 1, kind: .audio, language: "eng", codec: "eac3", channels: 6, isDefault: true),
        .init(id: 2, kind: .audio, language: "fre", codec: "ac3", channels: 6),
        .init(id: 3, kind: .audio, language: "fre", title: "Commentaires", codec: "aac", channels: 2),
        .init(id: 10, kind: .subtitle, language: "fre", isForced: true),
        .init(id: 11, kind: .subtitle, language: "fre", title: "SDH", isHearingImpaired: true),
        .init(id: 12, kind: .subtitle, language: "fr"),
        .init(id: 13, kind: .subtitle, language: "eng"),
    ]

    @Test func normalizesLanguageCodes() {
        #expect(LanguageCode.normalize("fre") == "fr")
        #expect(LanguageCode.normalize("fr-CA") == "fr")
        #expect(LanguageCode.normalize("French") == "fr")
        #expect(LanguageCode.normalize("und") == nil)
        #expect(LanguageCode.normalize("") == nil)
    }

    @Test func prefersFrenchAudioWithMostChannels() {
        let selector = TrackSelector(preferences: LanguagePreferences())
        #expect(selector.audio(tracks)?.id == 2)
    }

    @Test func frenchAudioOnlyEnablesForcedSubtitles() {
        let selector = TrackSelector(preferences: LanguagePreferences())
        let audio = selector.audio(tracks)
        #expect(selector.subtitle(tracks, selectedAudio: audio)?.id == 10)
    }

    @Test func originalAudioEnablesFullFrenchSubtitles() {
        var prefs = LanguagePreferences()
        prefs.preferredAudio = "en"
        let selector = TrackSelector(preferences: prefs)
        let audio = selector.audio(tracks)
        #expect(audio?.id == 1)
        #expect(selector.subtitle(tracks, selectedAudio: audio)?.id == 12, "non-SDH préféré")
    }

    @Test func offModeDisablesSubtitles() {
        var prefs = LanguagePreferences()
        prefs.subtitleMode = .off
        prefs.preferredAudio = "en"
        let selector = TrackSelector(preferences: prefs)
        #expect(selector.subtitle(tracks, selectedAudio: selector.audio(tracks)) == nil)
    }

    @Test func displayNames() {
        #expect(tracks[1].displayName == "Français · AC3 5.1")
        #expect(tracks[3].displayName == "Français · Forcés")
    }
}

@Suite("Jalons de lecture")
struct MilestoneTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func audioProgressWithoutFrameIsNotPlayable() {
        var m = PlaybackMilestoneTracker()
        m.mark(.sourceOpened, at: t0)
        m.mark(.decodingStarted, at: t0.addingTimeInterval(1))
        for i in 0..<20 {
            m.observe(position: Double(i), isPlaying: true, at: t0.addingTimeInterval(Double(i)))
        }
        #expect(m.highest == .decodingStarted, "l'horloge avance (audio) mais aucune image : pas « lisible »")
        #expect(!m.isConfirmedPlayable)
    }

    @Test func frameThenProgressReachesStable() {
        var m = PlaybackMilestoneTracker()
        m.mark(.sourceOpened, at: t0)
        m.mark(.firstFramePresented, at: t0.addingTimeInterval(2))
        #expect(m.reached[.dataReceived] != nil, "jalons inférieurs implicites")
        for i in 0...12 {
            m.observe(position: Double(i), isPlaying: true, at: t0.addingTimeInterval(2 + Double(i)))
        }
        #expect(m.highest == .stable)
        #expect(m.isConfirmedPlayable)
        #expect(m.latency(of: .firstFramePresented) == 2)
    }

    @Test func frozenClockCountsAsStall() {
        var m = PlaybackMilestoneTracker()
        m.mark(.firstFramePresented, at: t0)
        m.observe(position: 0, isPlaying: true, at: t0)
        m.observe(position: 1, isPlaying: true, at: t0.addingTimeInterval(1))
        m.observe(position: 1, isPlaying: true, at: t0.addingTimeInterval(2))
        #expect(m.stallCount == 1)
        #expect(m.highest == .playing)
    }
}

@Suite("Réglages")
struct SettingsTests {
    @Test func defaultsMatchFrenchUser() {
        let s = AppSettings()
        #expect(s.languages.preferredAudio == "fr")
        #expect(s.languages.secondaryAudio == "en")
        #expect(s.languages.preferredSubtitle == "fr")
        #expect(s.sources.autoPlay == false, "sélection automatique désactivée par défaut")
    }

    @Test func toleratesMissingAndUnknownValues() throws {
        // Réglages d'une « ancienne version » : champs manquants, valeur d'énumération inconnue.
        let json = #"{"sources":{"sortMode":"inventé","hideCam":false},"languages":{"preferredAudio":"en"},"futur":1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.sources.sortMode == .quality)
        #expect(s.sources.hideCam == false)
        #expect(s.languages.preferredAudio == "en")
        #expect(s.languages.preferredSubtitle == "fr")
        #expect(s.playback.engine == .automatic)
    }

    @Test func streamingServerValidation() {
        var p = PlaybackPreferences()
        p.streamingServerURL = "  http://192.168.1.20:11470 "
        #expect(p.streamingServer?.port == 11470)
        p.streamingServerURL = "nas:11470"
        #expect(p.streamingServer == nil)
    }
}
