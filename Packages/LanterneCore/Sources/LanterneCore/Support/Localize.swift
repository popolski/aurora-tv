import Foundation

/// Traduction à l'affichage des libellés anglais courants renvoyés par les
/// addons (Cinemeta notamment). Les valeurs d'origine restent utilisées dans
/// les requêtes (filtres de genre, etc.).
public enum Localize {
    private static let genres: [String: String] = [
        "action": "Action", "adventure": "Aventure", "animation": "Animation", "biography": "Biographie",
        "comedy": "Comédie", "crime": "Policier", "documentary": "Documentaire", "drama": "Drame",
        "family": "Famille", "fantasy": "Fantastique", "film-noir": "Film noir", "history": "Histoire",
        "horror": "Horreur", "music": "Musique", "musical": "Comédie musicale", "mystery": "Mystère",
        "romance": "Romance", "sci-fi": "Science-fiction", "science fiction": "Science-fiction",
        "short": "Court métrage", "sport": "Sport", "thriller": "Thriller", "war": "Guerre",
        "western": "Western", "reality-tv": "Téléréalité", "talk-show": "Talk-show",
        "game-show": "Jeu télévisé", "news": "Actualités", "anime": "Animé", "kids": "Enfants",
    ]

    public static func genre(_ raw: String) -> String {
        genres[raw.lowercased()] ?? raw
    }

    /// « Popular » + type « movie » → « Films populaires ».
    public static func catalogTitle(name: String, type: String) -> String {
        let typeLabel = ContentTypeLabel.label(for: type)
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "popular", "top": return "\(typeLabel) populaires"
        case "featured": return "\(typeLabel) à la une"
        case "new", "new releases", "latest": return "Nouveautés · \(typeLabel)"
        case "trending": return "\(typeLabel) tendance"
        case "top rated", "imdb rating", "rating": return "\(typeLabel) les mieux notés"
        case "last videos", "calendar-videos": return "Derniers épisodes"
        default: return name
        }
    }
}
