import Foundation

public enum ContentType {
    public static let movie = "movie"
    public static let series = "series"
    public static let channel = "channel"
    public static let tv = "tv"
}

public enum PosterShape: String, Sendable, Hashable, Codable {
    case poster, square, landscape
}

/// Élément de catalogue ou fiche détaillée (`metas[]` / `meta`).
///
/// Une même structure sert aux deux : un aperçu de catalogue a simplement
/// `videos == []` et moins de champs renseignés. Les champs absents restent
/// `nil` : l'interface ne doit **jamais** inventer d'information.
public struct MetaItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var background: URL?
    public var logo: URL?
    public var description: String?
    public var releaseInfo: String?
    public var runtime: String?
    public var released: Date?
    public var posterShape: PosterShape
    /// Note IMDb telle qu'annoncée par l'addon (chaîne, non vérifiée).
    public var imdbRating: String?
    public var genres: [String]
    public var cast: [String]
    public var directors: [String]
    public var writers: [String]
    public var country: String?
    public var language: String?
    public var awards: String?
    public var website: URL?
    public var trailerYouTubeIDs: [String]
    public var defaultVideoID: String?
    public var videos: [MetaVideo]

    public init(
        id: String, type: String, name: String, poster: URL? = nil, background: URL? = nil, logo: URL? = nil,
        description: String? = nil, releaseInfo: String? = nil, runtime: String? = nil, released: Date? = nil,
        posterShape: PosterShape = .poster, imdbRating: String? = nil, genres: [String] = [], cast: [String] = [],
        directors: [String] = [], writers: [String] = [], country: String? = nil, language: String? = nil,
        awards: String? = nil, website: URL? = nil, trailerYouTubeIDs: [String] = [], defaultVideoID: String? = nil,
        videos: [MetaVideo] = []
    ) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.background = background
        self.logo = logo; self.description = description; self.releaseInfo = releaseInfo; self.runtime = runtime
        self.released = released; self.posterShape = posterShape; self.imdbRating = imdbRating; self.genres = genres
        self.cast = cast; self.directors = directors; self.writers = writers; self.country = country
        self.language = language; self.awards = awards; self.website = website
        self.trailerYouTubeIDs = trailerYouTubeIDs; self.defaultVideoID = defaultVideoID; self.videos = videos
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, runtime, released, posterShape
        case imdbRating, genres, genre, cast, director, writer, links, country, language, awards, website
        case trailers, trailerStreams, behaviorHints, videos, year
        // Clés d'encodage propres à Lanterne (cache local).
        case directors, writers, trailerYouTubeIDs, defaultVideoID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id), let type = c.lenientString(forKey: .type) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "meta sans id/type"))
        }
        self.id = id
        self.type = type
        self.name = c.lenientString(forKey: .name) ?? ""
        self.poster = c.lenientURL(forKey: .poster)
        self.background = c.lenientURL(forKey: .background)
        self.logo = c.lenientURL(forKey: .logo)
        self.description = c.lenientString(forKey: .description)
        self.releaseInfo = c.lenientString(forKey: .releaseInfo) ?? c.lenientString(forKey: .year)
        self.runtime = c.lenientString(forKey: .runtime)
        self.released = c.lenientDate(forKey: .released)
        self.posterShape = (try? c.decodeIfPresent(PosterShape.self, forKey: .posterShape)) ?? .poster
        var rating = c.lenientString(forKey: .imdbRating)
        self.country = c.lenientString(forKey: .country)
        self.language = c.lenientString(forKey: .language)
        self.awards = c.lenientString(forKey: .awards)
        self.website = c.lenientURL(forKey: .website)

        // Le protocole v3 récent passe genres/distribution/réalisateurs dans
        // `links` (catégories Genres, Cast, Directors, Writers) ; les addons plus
        // anciens utilisent des champs directs. On fusionne les deux sans doublon.
        let links = c.lossyArray(MetaLink.self, forKey: .links)
        func merged(_ direct: [String], category: String) -> [String] {
            var out: [String] = []
            for v in direct + links.filter({ $0.category.caseInsensitiveCompare(category) == .orderedSame }).map(\.name)
            where !v.isEmpty && !out.contains(v) {
                out.append(v)
            }
            return out
        }
        let directGenres = c.contains(.genres) ? c.lenientStrings(forKey: .genres) : c.lenientStrings(forKey: .genre)
        self.genres = merged(directGenres, category: "Genres")
        self.cast = merged(c.lenientStrings(forKey: .cast), category: "Cast")
        self.directors = merged(c.lenientStrings(forKey: .director) + c.lenientStrings(forKey: .directors), category: "Directors")
        self.writers = merged(c.lenientStrings(forKey: .writer) + c.lenientStrings(forKey: .writers), category: "Writers")
        if rating == nil, let imdbLink = links.first(where: { $0.category.lowercased() == "imdb" }) {
            // Cinemeta place la note dans le nom du lien IMDb (« 7.4 »).
            if Double(imdbLink.name) != nil { rating = imdbLink.name }
        }
        self.imdbRating = rating

        var trailerIDs = c.lenientStrings(forKey: .trailerYouTubeIDs)
        for t in c.lossyArray(LegacyTrailer.self, forKey: .trailers) where t.type.lowercased() == "trailer" {
            if !trailerIDs.contains(t.source) { trailerIDs.append(t.source) }
        }
        for s in c.lossyArray(StreamItem.self, forKey: .trailerStreams) {
            if case .youtube(let ytID) = s.source, !trailerIDs.contains(ytID) { trailerIDs.append(ytID) }
        }
        self.trailerYouTubeIDs = trailerIDs

        let hints = try? c.decodeIfPresent(MetaBehaviorHints.self, forKey: .behaviorHints)
        self.defaultVideoID = hints?.defaultVideoId ?? c.lenientString(forKey: .defaultVideoID)

        // Vidéos : déduplication par id puis tri saison/épisode/date (comme stremio-core).
        var seen = Set<String>()
        let videos = c.lossyArray(MetaVideo.self, forKey: .videos).filter { seen.insert($0.id).inserted }
        self.videos = videos.sorted(by: MetaVideo.canonicalOrder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(released.map(StremioDate.format), forKey: .released)
        try c.encode(posterShape, forKey: .posterShape)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encode(genres, forKey: .genres)
        try c.encode(cast, forKey: .cast)
        try c.encode(directors, forKey: .directors)
        try c.encode(writers, forKey: .writers)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(awards, forKey: .awards)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encode(trailerYouTubeIDs, forKey: .trailerYouTubeIDs)
        try c.encodeIfPresent(defaultVideoID, forKey: .defaultVideoID)
        try c.encode(videos, forKey: .videos)
    }

    public var isSeries: Bool { type == ContentType.series || videos.contains { $0.season != nil } }

    /// Saisons disponibles, la saison 0 (« bonus/spéciaux ») en dernier.
    public var seasons: [Int] {
        let all = Set(videos.compactMap(\.season))
        return all.sorted { a, b in
            if a == 0 { return false }
            if b == 0 { return true }
            return a < b
        }
    }

    public func episodes(inSeason season: Int) -> [MetaVideo] {
        videos.filter { $0.season == season }
    }

    /// Année affichable, extraite de `releaseInfo` (« 2019 », « 2011–2019 », « 2019- »).
    public var displayYear: String? {
        if let info = releaseInfo, !info.isEmpty { return info }
        if let released { return String(Calendar(identifier: .gregorian).component(.year, from: released)) }
        return nil
    }

    /// Fusionne un aperçu (catalogue) et une fiche détaillée : la fiche prime,
    /// l'aperçu comble les trous. Permet un affichage immédiat puis enrichi.
    public func merged(withDetail detail: MetaItem) -> MetaItem {
        var m = detail
        if m.name.isEmpty { m.name = name }
        m.poster = m.poster ?? poster
        m.background = m.background ?? background
        m.logo = m.logo ?? logo
        m.description = m.description ?? description
        m.releaseInfo = m.releaseInfo ?? releaseInfo
        m.runtime = m.runtime ?? runtime
        m.released = m.released ?? released
        m.imdbRating = m.imdbRating ?? imdbRating
        if m.genres.isEmpty { m.genres = genres }
        if m.cast.isEmpty { m.cast = cast }
        if m.directors.isEmpty { m.directors = directors }
        return m
    }
}

public struct MetaLink: Sendable, Hashable, Codable {
    public var name: String
    public var category: String
    public var url: String?

    enum CodingKeys: String, CodingKey { case name, category, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.lenientString(forKey: .name), let category = c.lenientString(forKey: .category) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "lien invalide"))
        }
        self.name = name
        self.category = category
        self.url = c.lenientString(forKey: .url)
    }
}

struct LegacyTrailer: Decodable {
    var source: String
    var type: String
}

struct MetaBehaviorHints: Decodable {
    var defaultVideoId: String?
}

/// Vidéo d'une fiche (épisode pour une série, vidéo unique pour une chaîne).
public struct MetaVideo: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var released: Date?
    public var overview: String?
    public var thumbnail: URL?
    public var season: Int?
    public var episode: Int?
    /// Flux embarqués directement dans la fiche (rare ; ex. chaînes).
    public var streams: [StreamItem]

    public init(id: String, title: String = "", released: Date? = nil, overview: String? = nil, thumbnail: URL? = nil,
                season: Int? = nil, episode: Int? = nil, streams: [StreamItem] = []) {
        self.id = id; self.title = title; self.released = released; self.overview = overview
        self.thumbnail = thumbnail; self.season = season; self.episode = episode; self.streams = streams
    }

    enum CodingKeys: String, CodingKey {
        case id, title, name, released, firstAired, overview, description, thumbnail, season, episode, number, streams, stream
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(forKey: .id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "vidéo sans id"))
        }
        self.id = id
        self.title = c.lenientString(forKey: .title) ?? c.lenientString(forKey: .name) ?? ""
        self.released = c.lenientDate(forKey: .released) ?? c.lenientDate(forKey: .firstAired)
        self.overview = c.lenientString(forKey: .overview) ?? c.lenientString(forKey: .description)
        self.thumbnail = c.lenientURL(forKey: .thumbnail)
        let season = c.lenientInt(forKey: .season)
        self.season = season
        // Le champ historique `number` désigne l'épisode.
        self.episode = season == nil ? nil : (c.lenientInt(forKey: .episode) ?? c.lenientInt(forKey: .number))
        if c.contains(.streams) {
            self.streams = c.lossyArray(StreamItem.self, forKey: .streams)
        } else if let single = try? c.decodeIfPresent(StreamItem.self, forKey: .stream) {
            self.streams = [single]
        } else {
            self.streams = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(released.map(StremioDate.format), forKey: .released)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        if !streams.isEmpty { try c.encode(streams, forKey: .streams) }
    }

    /// Ordre canonique : saison, puis épisode, puis date de sortie, puis id.
    public static func canonicalOrder(_ a: MetaVideo, _ b: MetaVideo) -> Bool {
        switch (a.season, b.season) {
        case let (sa?, sb?) where sa != sb:
            // Spéciaux (saison 0) après les saisons régulières.
            if sa == 0 { return false }
            if sb == 0 { return true }
            return sa < sb
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if let ea = a.episode, let eb = b.episode, ea != eb { return ea < eb }
        if let ra = a.released, let rb = b.released, ra != rb { return ra < rb }
        return a.id < b.id
    }

    /// « S02E05 » si l'information existe.
    public var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    public func isReleased(asOf now: Date = Date()) -> Bool {
        guard let released else { return true }
        return released <= now
    }
}
