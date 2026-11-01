import Foundation

/// État de visionnage d'un élément (`state` d'un `libraryItem` Stremio).
/// Toutes les durées sont en **millisecondes**, comme dans l'API.
public struct WatchState: Sendable, Hashable, Codable {
    public var lastWatched: Date?
    public var timeWatched: Int64 = 0
    public var timeOffset: Int64 = 0
    public var overallTimeWatched: Int64 = 0
    public var timesWatched: Int = 0
    public var flaggedWatched: Int = 0
    public var duration: Int64 = 0
    /// Vidéo (épisode) en cours : identifiant de type `tt0944947:1:2`.
    public var videoID: String?
    /// Champ « épisodes vus » sérialisé (voir `WatchedBitField`), conservé tel quel.
    public var watched: String?
    public var noNotif: Bool = false

    public init() {}

    public var progress: Double {
        guard timeOffset > 0, duration > 0 else { return 0 }
        return min(1, Double(timeOffset) / Double(duration))
    }
}

/// Élément de bibliothèque, compatible avec la collection `libraryItem` de Stremio.
///
/// Sémantique Stremio :
/// - dans la bibliothèque : `removed == false && temp == false` ;
/// - historique seul (« Continuer » sans ajout) : `temp == true`, `removed == true` ;
/// - « Continuer à regarder » : `(!removed || temp) && timeOffset > 0`.
public struct LibraryItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var posterShape: PosterShape
    public var removed: Bool
    public var temp: Bool
    public var ctime: Date?
    public var mtime: Date
    public var state: WatchState
    public var defaultVideoID: String?
    /// Objet JSON d'origine reçu du serveur : les champs inconnus sont
    /// réémis à l'identique lors d'un envoi, pour ne rien détruire.
    public var raw: [String: JSONValue]?

    public init(id: String, type: String, name: String, poster: URL? = nil, posterShape: PosterShape = .poster,
                removed: Bool = true, temp: Bool = true, ctime: Date? = Date(), mtime: Date = Date(),
                state: WatchState = .init(), defaultVideoID: String? = nil, raw: [String: JSONValue]? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.posterShape = posterShape
        self.removed = removed; self.temp = temp; self.ctime = ctime; self.mtime = mtime; self.state = state
        self.defaultVideoID = defaultVideoID; self.raw = raw
    }

    public init(meta: MetaItem, now: Date = Date()) {
        self.init(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, posterShape: meta.posterShape,
                  removed: true, temp: true, ctime: now, mtime: now, defaultVideoID: meta.defaultVideoID)
    }

    public var isInLibrary: Bool { !removed && !temp }
    public var isInContinueWatching: Bool { type != "other" && (!removed || temp) && state.timeOffset > 0 }
    public var isWatched: Bool { state.timesWatched > 0 }

    /// Doit être synchronisé (règle `should_sync` de stremio-core).
    public func shouldSync(now: Date = Date()) -> Bool {
        let yearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        return type != "other" && (!removed || mtime > yearAgo)
    }

    // MARK: Format API Stremio

    /// Décodage depuis l'objet `libraryItem` de l'API (champs `_id`, `_mtime`…).
    public init(stremioJSON object: [String: JSONValue]) throws {
        guard let id = object["_id"]?.stringValue, !id.isEmpty,
              let type = object["type"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "libraryItem invalide"))
        }
        self.id = id
        self.type = type
        self.name = object["name"]?.stringValue ?? ""
        self.poster = object["poster"]?.stringValue.flatMap { s in
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return u
        }
        self.posterShape = object["posterShape"]?.stringValue.flatMap(PosterShape.init(rawValue:)) ?? .poster
        self.removed = object["removed"]?.boolValue ?? false
        self.temp = object["temp"]?.boolValue ?? false
        self.ctime = object["_ctime"]?.stringValue.flatMap(StremioDate.parse)
        self.mtime = Self.date(object["_mtime"]) ?? Date(timeIntervalSince1970: 0)
        var s = WatchState()
        if case .object(let st)? = object["state"] {
            s.lastWatched = Self.date(st["lastWatched"])
            s.timeWatched = Self.ms(st["timeWatched"])
            s.timeOffset = Self.ms(st["timeOffset"])
            s.overallTimeWatched = Self.ms(st["overallTimeWatched"])
            s.timesWatched = Int(Self.ms(st["timesWatched"]))
            s.flaggedWatched = Int(Self.ms(st["flaggedWatched"]))
            s.duration = Self.ms(st["duration"])
            s.videoID = st["video_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            s.watched = st["watched"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            s.noNotif = st["noNotif"]?.boolValue ?? false
        }
        self.state = s
        if case .object(let hints)? = object["behaviorHints"] {
            self.defaultVideoID = hints["defaultVideoId"]?.stringValue
        }
        self.raw = object
    }

    /// Objet à envoyer à `datastorePut` : l'objet d'origine, champs connus mis à jour.
    public func stremioJSON() -> [String: JSONValue] {
        var o = raw ?? [:]
        o["_id"] = .string(id)
        o["type"] = .string(type)
        o["name"] = .string(name)
        o["poster"] = poster.map { .string($0.absoluteString) } ?? .string("")
        o["posterShape"] = .string(posterShape.rawValue)
        o["removed"] = .bool(removed)
        o["temp"] = .bool(temp)
        o["_ctime"] = ctime.map { .string(StremioDate.format($0)) } ?? .null
        o["_mtime"] = .string(StremioDate.format(mtime))
        var st: [String: JSONValue] = [:]
        if case .object(let original)? = raw?["state"] { st = original }
        st["lastWatched"] = state.lastWatched.map { .string(StremioDate.format($0)) } ?? .null
        st["timeWatched"] = .number(Double(state.timeWatched))
        st["timeOffset"] = .number(Double(state.timeOffset))
        st["overallTimeWatched"] = .number(Double(state.overallTimeWatched))
        st["timesWatched"] = .number(Double(state.timesWatched))
        st["flaggedWatched"] = .number(Double(state.flaggedWatched))
        st["duration"] = .number(Double(state.duration))
        st["video_id"] = state.videoID.map { .string($0) } ?? .null
        st["watched"] = state.watched.map { .string($0) } ?? .null
        st["noNotif"] = .bool(state.noNotif)
        o["state"] = .object(st)
        if o["behaviorHints"] == nil {
            var hints: [String: JSONValue] = [:]
            if let d = defaultVideoID { hints["defaultVideoId"] = .string(d) }
            o["behaviorHints"] = .object(hints)
        }
        return o
    }

    private static func ms(_ v: JSONValue?) -> Int64 {
        guard let d = v?.doubleValue, d.isFinite, d >= 0 else { return 0 }
        return Int64(min(d, 9.0e15))
    }

    private static func date(_ v: JSONValue?) -> Date? {
        switch v {
        case .string(let s)?: return StremioDate.parse(s)
        case .number(let n)?: return Date(timeIntervalSince1970: n / 1000)
        default: return nil
        }
    }
}
