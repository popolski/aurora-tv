import Foundation

/// Calendrier des séries suivies : épisodes de la semaine, nouveaux épisodes.
public enum EpisodeCalendar {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var series: MetaItem
        public var video: MetaVideo
        public var released: Date
        public var id: String { video.id }
    }

    /// Épisodes (hors bonus) sortis depuis hier ou à paraître dans les 7 jours, par date.
    public static func thisWeek(series: [MetaItem], now: Date = Date()) -> [Entry] {
        let from = now.addingTimeInterval(-36 * 3600)
        let to = now.addingTimeInterval(7 * 86_400)
        var out: [Entry] = []
        for meta in series where meta.type == ContentType.series {
            for video in meta.videos {
                guard let released = video.released, (video.season ?? 1) > 0,
                      released >= from, released <= to else { continue }
                out.append(Entry(series: meta, video: video, released: released))
            }
        }
        return out.sorted { ($0.released, $0.series.name) < ($1.released, $1.series.name) }
    }

    /// Un épisode est sorti depuis moins de `window` et après le dernier visionnage de la série.
    public static func hasNewEpisode(series meta: MetaItem, item: LibraryItem?, now: Date = Date(),
                                     window: TimeInterval = 7 * 86_400) -> Bool {
        guard meta.type == ContentType.series else { return false }
        let latest = meta.videos
            .filter { ($0.season ?? 1) > 0 }
            .compactMap(\.released)
            .filter { $0 <= now }
            .max()
        guard let latest, now.timeIntervalSince(latest) <= window else { return false }
        guard let lastWatched = item?.state.lastWatched else { return true }
        return latest > lastWatched
    }

    /// « Aujourd'hui », « Demain », « Hier » ou le jour de la semaine (« jeudi »).
    public static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let delta = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        switch delta {
        case 0: return "Aujourd'hui"
        case 1: return "Demain"
        case -1: return "Hier"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
    }
}
