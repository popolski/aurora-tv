import Foundation
import Testing
@testable import LanterneCore

@Suite("Minuteur, « toujours là ? », synchronisation des sous-titres")
struct BedtimeControlsTests {
    @Test func sleepTimerLabelsAndDeadline() {
        #expect(SleepTimerChoice.endOfItem.label(isSeries: true) == "Fin de l'épisode")
        #expect(SleepTimerChoice.endOfItem.label(isSeries: false) == "Fin du film")
        #expect(SleepTimerChoice.minutes(45).label(isSeries: false) == "45 min")
        #expect(SleepTimerChoice.minutes(60).label(isSeries: false) == "1 h")
        #expect(SleepTimerChoice.minutes(90).label(isSeries: false) == "1 h 30")
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(SleepTimerChoice.minutes(30).deadline(from: start) == Date(timeIntervalSince1970: 2_800))
        #expect(SleepTimerChoice.endOfItem.deadline(from: start) == nil)
    }

    @Test func sleepTimerStatus() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(SleepTimerChoice.status(nil, deadline: nil, now: now, isSeries: true) == nil)
        #expect(SleepTimerChoice.status(.endOfItem, deadline: nil, now: now, isSeries: true) == "Arrêt à la fin de l'épisode")
        #expect(SleepTimerChoice.status(.minutes(30), deadline: now.addingTimeInterval(22 * 60 + 5), now: now, isSeries: false)
                == "Arrêt dans 23 min")
        #expect(SleepTimerChoice.status(.minutes(15), deadline: now.addingTimeInterval(20), now: now, isSeries: false)
                == "Arrêt dans 1 min")
    }

    @Test func endOfItemUsesCreditsWhenKnown() {
        // Générique connu : arrêt dès son début.
        #expect(SleepTimerChoice.endOfItemReached(position: 2500, duration: 2700, creditsStart: 2490))
        #expect(!SleepTimerChoice.endOfItemReached(position: 2400, duration: 2700, creditsStart: 2490))
        // Minutage aberrant (début de fichier) ignoré : dernières secondes seulement.
        #expect(!SleepTimerChoice.endOfItemReached(position: 100, duration: 2700, creditsStart: 50))
        #expect(SleepTimerChoice.endOfItemReached(position: 2685, duration: 2700, creditsStart: nil))
        #expect(!SleepTimerChoice.endOfItemReached(position: 60, duration: 90, creditsStart: nil))
    }

    @Test func stillWatchingAsksAfterLimit() {
        var counter = StillWatchingCounter(limit: 2)
        #expect(counter.allowAutoAdvance())
        #expect(counter.allowAutoAdvance())
        #expect(!counter.allowAutoAdvance())
        #expect(!counter.allowAutoAdvance())
        counter.userInteracted()
        #expect(counter.allowAutoAdvance())

        var never = StillWatchingCounter(limit: 0)
        for _ in 0..<20 { #expect(never.allowAutoAdvance()) }
    }

    @Test func stillWatchingPreferenceIsTolerant() throws {
        let old = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(#"{"skipInterval":15}"#.utf8))
        #expect(old.stillWatchingAfter == 3)
        let off = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(#"{"stillWatchingAfter":0}"#.utf8))
        #expect(off.stillWatchingAfter == 0)
        let bad = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(#"{"stillWatchingAfter":-4}"#.utf8))
        #expect(bad.stillWatchingAfter == 0)
    }

    @Test func syncDelayShowsChosenLineNow() {
        let line = SubtitleSyncLine(id: 1, start: 100, text: "Bonjour")
        // Réplique entendue à 103 s : elle doit apparaître 3 s plus tard.
        #expect(SubtitleSync.delay(for: line, heardAt: 103) == 3)
        // Sous-titres en retard : décalage négatif.
        #expect(SubtitleSync.delay(for: line, heardAt: 95.5) == -4.5)
        #expect(SubtitleSync.delay(for: line, heardAt: 200) == 30)
    }

    @Test func syncCandidatesAreCleanedAndBounded() {
        let lines = [
            SubtitleSyncLine(id: 3, start: 130, text: "Plus tard"),
            SubtitleSyncLine(id: 1, start: 90, text: "  Première\nligne  "),
            SubtitleSyncLine(id: 2, start: 90, text: "Première ligne"),
            SubtitleSyncLine(id: 4, start: 95, text: "Bonjour\\Nà tous"),
            SubtitleSyncLine(id: 5, start: 50, text: "Trop ancienne"),
            SubtitleSyncLine(id: 6, start: 98, text: "   "),
        ]
        let result = SubtitleSync.candidates(lines, now: 100)
        #expect(result.map(\.id) == [1, 4, 3])
        #expect(result.map(\.text) == ["Première ligne", "Bonjour à tous", "Plus tard"])
        #expect(SubtitleSync.current(in: result, now: 100, delay: 0)?.id == 4)
        #expect(SubtitleSync.current(in: result, now: 100, delay: 8)?.id == 1)
        #expect(SubtitleSync.current(in: result, now: 80, delay: 0)?.id == 1)
    }
}
