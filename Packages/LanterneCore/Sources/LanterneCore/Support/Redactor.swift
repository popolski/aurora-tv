import Foundation

/// Expurgation des données sensibles avant journalisation.
///
/// Les URL d'addons Stremio « configurés » contiennent fréquemment des clés
/// d'API (services de débridage, etc.) encodées dans le chemin ; les URL de
/// flux contiennent souvent des signatures dans la requête. Toute URL est donc
/// réduite à `schéma://hôte/` + segments courts, et toute valeur de requête est masquée.
public enum Redactor {
    public static let mask = "‹…›"

    private static let keyValuePatterns: [NSRegularExpression] = {
        let keys = "authKey|auth_key|password|passwd|token|access_token|refresh_token|apikey|api_key|secret|session"
        let patterns = [
            // "authKey":"valeur"  /  "password": "valeur"
            "(\"(?:\(keys))\"\\s*:\\s*\")[^\"]*(\")",
            // authKey=valeur (requête, formulaires)
            "((?:\(keys))=)[^&\\s\"]+()",
            // Authorization: Bearer xxx
            "((?:Bearer|Basic)\\s+)[A-Za-z0-9._~+/=-]+()",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    private static let urlPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "https?://[^\\s\"'<>]+", options: [.caseInsensitive])
    }()

    /// Expurge une chaîne libre (message de journal).
    public static func redact(_ input: String) -> String {
        var text = input
        // 1. URL d'abord (chemins de configuration et valeurs de requête), de la
        //    fin vers le début pour conserver la validité des plages.
        let range = NSRange(text.startIndex..., in: text)
        let matches = urlPattern.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            guard let r = Range(match.range, in: text) else { continue }
            let raw = String(text[r])
            text.replaceSubrange(r, with: redactURLString(raw))
        }
        // 2. Paires clé/valeur sensibles restantes.
        for regex in keyValuePatterns {
            let full = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: "$1\(mask)$2")
        }
        return text
    }

    /// Forme expurgée d'une URL, adaptée à l'affichage et aux journaux.
    public static func redact(url: URL) -> String {
        redactURLString(url.absoluteString)
    }

    static func redactURLString(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host else {
            return mask
        }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let cleaned = segments.map { segment -> String in
            looksSensitive(segment) ? mask : String(segment)
        }
        var result = "\(components.scheme ?? "https")://\(host)"
        if let port = components.port { result += ":\(port)" }
        if !cleaned.isEmpty { result += "/" + cleaned.joined(separator: "/") }
        if let items = components.queryItems, !items.isEmpty {
            result += "?" + items.map { "\($0.name)=\(mask)" }.joined(separator: "&")
        }
        return result
    }

    /// Heuristique : un segment long, encodé ou contenant une affectation est
    /// probablement une configuration ou une clé.
    static func looksSensitive(_ segment: Substring) -> Bool {
        if segment.count > 24 { return true }
        if segment.contains("=") || segment.contains("%7B") || segment.contains("%7b") || segment.contains("{") {
            return true
        }
        // Chaîne alphanumérique de 16+ caractères mêlant chiffres et lettres : clé probable.
        if segment.count >= 16 {
            let hasDigit = segment.contains(where: \.isNumber)
            let hasLetter = segment.contains(where: \.isLetter)
            if hasDigit && hasLetter && !segment.contains(".") { return true }
        }
        return false
    }
}
