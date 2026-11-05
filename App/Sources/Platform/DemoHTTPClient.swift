import Foundation
import LanterneCore

/// Réseau de démonstration (`-uitest -demo`) : films et séries **inventés**, avec des
/// images générées (docs/demo-assets, servies depuis le dépôt GitHub). Sert aux captures
/// d'écran de la documentation ; aucun contenu réel, aucun compte.
nonisolated final class DemoHTTPClient: HTTPClient {
    static let assets = "https://raw.githubusercontent.com/popolski/aurora-tv/main/docs/demo-assets/"

    struct Title {
        let id: String, name: String, type: String, year: Int, runtime: String, rating: String
        let genres: [String], cast: [String], director: String, description: String
        /// Sortie (jours depuis aujourd'hui, négatif = passé) : « Au cinéma » si récente.
        let releasedDaysAgo: Int
    }

    static let movies: [Title] = [
        .init(id: "tt9900001", name: "La Dernière Aurore", type: "movie", year: 2026, runtime: "2h12min", rating: "8.1",
              genres: ["Science-Fiction", "Drama"], cast: ["Léa Martin", "Hugo Bernard", "Inès Robert"], director: "Claire Lefèvre",
              description: "Quand le soleil cesse de se lever sur une station polaire, une ingénieure part à la recherche de la dernière aurore pour sauver ceux qui l'attendent.",
              releasedDaysAgo: 18),
        .init(id: "tt9900002", name: "Marée Basse", type: "movie", year: 2025, runtime: "1h48min", rating: "7.4",
              genres: ["Thriller", "Mystery"], cast: ["Paul Girard", "Camille Faure"], director: "Antoine Roux",
              description: "Sur une île coupée du continent à chaque marée, un garde-côte découvre que les disparitions suivent le rythme de l'océan.",
              releasedDaysAgo: 210),
        .init(id: "tt9900003", name: "Le Phare des Brumes", type: "movie", year: 2025, runtime: "1h56min", rating: "7.9",
              genres: ["Drama", "Mystery"], cast: ["Jeanne Morel", "Louis Fournier"], director: "Sophie Mercier",
              description: "Une gardienne de phare reçoit chaque nuit des signaux d'un bateau que personne d'autre ne voit.",
              releasedDaysAgo: 320),
        .init(id: "tt9900004", name: "Neuf Lunes", type: "movie", year: 2026, runtime: "1h39min", rating: "6.8",
              genres: ["Comedy", "Romance"], cast: ["Chloé Blanc", "Nathan Garnier"], director: "Julien Chevalier",
              description: "Neuf mois, neuf pleines lunes et un couple qui tente de tout réussir avant l'arrivée du bébé.",
              releasedDaysAgo: 40),
        .init(id: "tt9900005", name: "Sable Rouge", type: "movie", year: 2024, runtime: "2h05min", rating: "7.1",
              genres: ["Adventure", "Action"], cast: ["Mehdi Laurent", "Alice Perrin"], director: "Thomas Moreau",
              description: "Une convoyeuse traverse le désert avec une cargaison dont elle ignore tout, poursuivie par ceux qui la connaissent trop bien.",
              releasedDaysAgo: 600),
        .init(id: "tt9900006", name: "Minuit Pile", type: "movie", year: 2025, runtime: "1h52min", rating: "7.7",
              genres: ["Crime", "Thriller"], cast: ["Victor Lambert", "Sarah Dumas"], director: "Élise Bonnet",
              description: "Une nuit, une ville, douze heures pour retrouver un témoin avant que l'horloge de la gare ne sonne minuit.",
              releasedDaysAgo: 150),
        .init(id: "tt9900007", name: "Vertige Bleu", type: "movie", year: 2026, runtime: "1h44min", rating: "7.2",
              genres: ["Drama"], cast: ["Lucie Henry", "Raphaël Masson"], director: "Margaux Roy",
              description: "Une plongeuse en apnée prépare le record de sa vie, au bord d'une falaise et de ses propres limites.",
              releasedDaysAgo: 9),
        .init(id: "tt9900008", name: "Le Bal des Lucioles", type: "movie", year: 2025, runtime: "1h31min", rating: "8.0",
              genres: ["Animation", "Family"], cast: ["Zoé Lemoine", "Gabriel Noël"], director: "Mathis Caron",
              description: "Dans une forêt où la nuit ne tombe plus, deux enfants organisent le bal qui rendra leur lumière aux lucioles.",
              releasedDaysAgo: 260),
        .init(id: "tt9900009", name: "Orbite Basse", type: "movie", year: 2026, runtime: "2h01min", rating: "7.6",
              genres: ["Science-Fiction", "Thriller"], cast: ["Adam Fontaine", "Manon Rey"], director: "Lucas Barbier",
              description: "Seule à bord d'une station en perdition, une astronaute a quatre-vingt-dix minutes, le temps d'une orbite, pour rentrer.",
              releasedDaysAgo: 70),
        .init(id: "tt9900010", name: "Les Saisons d'Ana", type: "movie", year: 2024, runtime: "1h57min", rating: "7.8",
              genres: ["Drama"], cast: ["Ana Vidal", "Pierre Colin"], director: "Nina Gauthier",
              description: "Un an dans la vie d'Ana, de l'hiver où tout se brise au printemps où tout recommence.",
              releasedDaysAgo: 500),
    ]

    static let series: [Title] = [
        .init(id: "tt9910001", name: "Les Cartographes", type: "series", year: 2025, runtime: "52min", rating: "8.4",
              genres: ["Adventure", "Drama"], cast: ["Émile Rousseau", "Jade Marchand", "Noah Dupuis"], director: "Clara Vincent",
              description: "Une équipe de cartographes part dessiner les contours d'une vallée qui n'apparaît sur aucune carte, et qui semble changer chaque nuit.",
              releasedDaysAgo: 400),
        .init(id: "tt9910002", name: "Ligne 7", type: "series", year: 2026, runtime: "45min", rating: "7.9",
              genres: ["Crime", "Thriller"], cast: ["Yanis Mathieu", "Louise Brun"], director: "Hélène Picard",
              description: "Sur la dernière rame de la ligne 7, une contrôleuse croise chaque soir les mêmes passagers, et un secret qui voyage avec eux.",
              releasedDaysAgo: 60),
    ]

    static var all: [Title] { movies + series }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 30_000_000)
        let url = request.url
        let path = url.path
        let body: String
        if url.host?.contains("wikidata") == true {
            body = Self.reviews()
        } else if path.hasSuffix("/manifest.json") {
            body = Self.manifest(host: url.host ?? "")
        } else if path.hasPrefix("/catalog/") {
            body = Self.catalog(path: path)
        } else if path.hasPrefix("/meta/") {
            let id = url.deletingPathExtension().lastPathComponent
            body = Self.all.first { $0.id == id }.map { #"{"meta":\#(Self.metaJSON($0, full: true))}"# } ?? #"{"meta":null}"#
        } else if path.hasPrefix("/stream/") {
            body = Self.streams()
        } else if path.hasPrefix("/subtitles/") {
            body = #"{"subtitles":[]}"#
        } else {
            return HTTPResponse(status: 404, data: Data(), url: url)
        }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], data: Data(body.utf8), url: url)
    }

    static func manifest(host: String) -> String {
        if host.contains("opensubtitles") {
            return #"{"id":"demo.subs","version":"1.0.0","name":"Sous-titres","types":["movie","series"],"resources":["subtitles"],"idPrefixes":["tt"],"catalogs":[]}"#
        }
        let genres = #"["Drama","Science-Fiction","Thriller","Mystery","Comedy","Adventure","Animation"]"#
        return #"""
        {"id":"com.linvo.cinemeta","version":"3.0.0","name":"Cinemeta","types":["movie","series"],"idPrefixes":["tt"],
         "resources":["catalog","meta","stream"],
         "catalogs":[
          {"type":"movie","id":"top","name":"Popular","extra":[{"name":"genre","options":\#(genres)},{"name":"search"},{"name":"skip"}]},
          {"type":"movie","id":"year","name":"New","extra":[{"name":"genre","options":["2026","2025","2024"],"isRequired":true}]},
          {"type":"movie","id":"imdbRating","name":"Featured","extra":[{"name":"genre","options":\#(genres)}]},
          {"type":"series","id":"top","name":"Popular","extra":[{"name":"genre","options":\#(genres)},{"name":"search"}]},
          {"type":"series","id":"imdbRating","name":"Featured"}
         ]}
        """#
    }

    static func catalog(path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)  // catalog, type, id, [extra].json
        guard parts.count >= 3 else { return #"{"metas":[]}"# }
        let type = parts[1]
        let id = parts[2].replacingOccurrences(of: ".json", with: "")
        let extra = parts.count >= 4 ? (parts[3].removingPercentEncoding ?? parts[3]).replacingOccurrences(of: ".json", with: "") : ""
        var items = type == "series" ? series : movies
        if extra.hasPrefix("skip=") { return #"{"metas":[]}"# }
        if extra.hasPrefix("search=") {
            let query = String(extra.dropFirst("search=".count)).lowercased()
            items = all.filter { $0.name.lowercased().contains(query) }
        } else if extra.hasPrefix("genre="), id == "year" {
            let year = Int(extra.dropFirst("genre=".count)) ?? 0
            items = items.filter { $0.year == year }
        } else if extra.hasPrefix("genre=") {
            let genre = String(extra.dropFirst("genre=".count))
            items = items.filter { $0.genres.contains(genre) }
        }
        if id == "imdbRating" { items.sort { $0.rating > $1.rating } }
        return #"{"metas":[\#(items.map { metaJSON($0, full: false) }.joined(separator: ","))]}"#
    }

    static func metaJSON(_ t: Title, full: Bool) -> String {
        let released = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(t.releasedDaysAgo) * 86_400))
        var fields = [
            #""id":"\#(t.id)","type":"\#(t.type)","name":"\#(t.name)""#,
            #""poster":"\#(assets)\#(t.id)-poster.jpg","background":"\#(assets)\#(t.id)-bg.jpg","logo":"\#(assets)\#(t.id)-logo.png""#,
            #""releaseInfo":"\#(t.year)","released":"\#(released)","runtime":"\#(t.runtime)","imdbRating":"\#(t.rating)""#,
            #""genres":[\#(t.genres.map { "\"\($0)\"" }.joined(separator: ","))]"#,
            #""description":"\#(t.description)""#,
        ]
        if full {
            fields.append(#""cast":[\#(t.cast.map { "\"\($0)\"" }.joined(separator: ","))],"director":["\#(t.director)"]"#)
            if t.type == "series" { fields.append(#""videos":[\#(episodes(t).joined(separator: ","))]"#) }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Épisodes : une saison complète, puis une saison en cours de diffusion (épisodes de la semaine).
    static func episodes(_ t: Title) -> [String] {
        let titles = ["La vallée", "Le col", "Les relevés", "La carte muette", "Le fleuve", "L'autre versant", "Le retour", "Le point zéro"]
        let seasons: [(Int, Int, [Int])] = t.id == "tt9910001"
            ? [(1, 6, [-420, -413, -406, -399, -392, -385]), (2, 6, [-26, -19, -12, -5, 1, 8])]
            : [(1, 8, [-60, -53, -46, -39, -32, -25, -4, 3])]
        var out: [String] = []
        for (season, count, days) in seasons {
            for e in 1...count {
                let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(days[e - 1]) * 86_400))
                let thumb = "\(assets)\(t.id)-s\(min(season, 2))e\(min(e, 8)).jpg"
                out.append(#"{"id":"\#(t.id):\#(season):\#(e)","title":"\#(titles[(e - 1) % titles.count])","season":\#(season),"episode":\#(e),"released":"\#(date)","thumbnail":"\#(thumb)","overview":"Épisode \#(e) de la saison \#(season)."}"#)
            }
        }
        return out
    }

    static func streams() -> String {
        let rows = [
            ("Démo 4K\\nDV HDR", "Film.2026.2160p.WEB-DL.DV.HDR10.HEVC.Atmos.MULTi.VFF\\n💾 18.4 GB 👤 214"),
            ("Démo 1080p", "Film.2026.1080p.BluRay.x264.DTS.TRUEFRENCH\\n💾 9.8 GB 👤 96"),
            ("Démo 1080p", "Film.2026.1080p.WEB-DL.H264.AAC.VOSTFR\\n💾 3.1 GB 👤 58"),
            ("Démo 4K", "Film.2026.2160p.REMUX.HEVC.HDR10.TrueHD.ENG\\n💾 54.2 GB 👤 31"),
            ("Démo 720p", "Film.2026.720p.WEB.x264.AAC.FRENCH\\n💾 1.4 GB 👤 12"),
        ]
        let items = rows.enumerated().map { i, row in
            #"{"name":"\#(row.0)","description":"\#(row.1)","url":"https://demo.invalid/source\#(i).mkv"}"#
        }
        return #"{"streams":[\#(items.joined(separator: ","))]}"#
    }

    static func reviews() -> String {
        #"{"head":{},"results":{"bindings":[{"site":{"value":"http://www.wikidata.org/entity/Q105584"},"score":{"value":"91%"},"methodLabel":{"value":"Tomatometer score"}},{"site":{"value":"http://www.wikidata.org/entity/Q150248"},"score":{"value":"82/100"},"methodLabel":{"value":"Metascore"}}]}}"#
    }

    /// Bibliothèque de démonstration : deux titres en cours, une liste, une série en diffusion.
    static func seed(_ library: LibraryStore) async {
        func ref(_ t: Title) -> LibraryMetaRef {
            LibraryMetaRef(id: t.id, type: t.type, name: t.name, poster: URL(string: "\(assets)\(t.id)-poster.jpg"))
        }
        let film = movies[0], cartographes = series[0], ligne7 = series[1]
        await library.recordProgress(ref(film), videoID: film.id, position: 3100, duration: 7920, played: 60)
        await library.recordProgress(ref(cartographes), videoID: "\(cartographes.id):2:3", position: 1100, duration: 3120, played: 60)
        for t in [movies[2], movies[5], movies[8], ligne7, cartographes] { await library.addToLibrary(ref(t)) }
    }
}
