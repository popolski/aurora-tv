import Foundation
import Testing
@testable import LanterneCore

@Suite("Calendrier des épisodes")
struct EpisodeCalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func series(_ id: String, episodes: [(Int, Int, TimeInterval)]) -> MetaItem {
        MetaItem(id: id, type: "series", name: id,
                 videos: episodes.map { MetaVideo(id: "\(id):\($0.0):\($0.1)", title: "E\($0.1)",
                                                  released: now.addingTimeInterval($0.2), season: $0.0, episode: $0.1) })
    }

    @Test func thisWeekKeepsRecentAndUpcoming() {
        let a = series("tt1", episodes: [(1, 1, -30 * 86_400), (1, 2, -3600), (1, 3, 3 * 86_400), (1, 4, 10 * 86_400), (0, 1, 3600)])
        let entries = EpisodeCalendar.thisWeek(series: [a], now: now)
        #expect(entries.map(\.id) == ["tt1:1:2", "tt1:1:3"])
    }

    @Test func newEpisodeDependsOnLastWatched() {
        let a = series("tt1", episodes: [(1, 1, -20 * 86_400), (1, 2, -2 * 86_400)])
        var item = LibraryItem(id: "tt1", type: "series", name: "tt1")
        #expect(EpisodeCalendar.hasNewEpisode(series: a, item: item, now: now))
        item.state.lastWatched = now.addingTimeInterval(-86_400)
        #expect(!EpisodeCalendar.hasNewEpisode(series: a, item: item, now: now))
        item.state.lastWatched = now.addingTimeInterval(-5 * 86_400)
        #expect(EpisodeCalendar.hasNewEpisode(series: a, item: item, now: now))
        let old = series("tt2", episodes: [(1, 1, -30 * 86_400)])
        #expect(!EpisodeCalendar.hasNewEpisode(series: old, item: nil, now: now))
    }

    @Test func dayLabels() {
        #expect(EpisodeCalendar.dayLabel(for: now, now: now, calendar: utc) == "Aujourd'hui")
        #expect(EpisodeCalendar.dayLabel(for: now.addingTimeInterval(86_400), now: now, calendar: utc) == "Demain")
        #expect(EpisodeCalendar.dayLabel(for: now.addingTimeInterval(-86_400), now: now, calendar: utc) == "Hier")
        // 1 800 000 000 s = vendredi 15 janvier 2027 (UTC) ; +3 jours = lundi.
        #expect(EpisodeCalendar.dayLabel(for: now.addingTimeInterval(3 * 86_400), now: now, calendar: utc) == "lundi")
    }
}
