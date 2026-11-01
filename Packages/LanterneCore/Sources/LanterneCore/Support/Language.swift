import Foundation

/// Normalisation des codes de langue (ISO 639-1/639-2/BCP 47) vers ISO 639-1.
public enum LanguageCode {
    private static let iso639_2: [String: String] = [
        "fre": "fr", "fra": "fr", "eng": "en", "spa": "es", "esl": "es", "ger": "de", "deu": "de",
        "ita": "it", "por": "pt", "pob": "pt", "pt-br": "pt", "jpn": "ja", "kor": "ko", "rus": "ru",
        "ara": "ar", "chi": "zh", "zho": "zh", "dut": "nl", "nld": "nl", "pol": "pl", "tur": "tr",
        "swe": "sv", "nor": "no", "nob": "no", "dan": "da", "fin": "fi", "gre": "el", "ell": "el",
        "heb": "he", "hun": "hu", "cze": "cs", "ces": "cs", "rum": "ro", "ron": "ro", "ukr": "uk",
        "hin": "hi", "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms", "cat": "ca",
        "bul": "bg", "hrv": "hr", "srp": "sr", "slv": "sl", "slo": "sk", "slk": "sk", "per": "fa",
        "fas": "fa", "lit": "lt", "lav": "lv", "est": "et", "ice": "is", "isl": "is", "baq": "eu",
        "eus": "eu", "glg": "gl", "und": "und", "mul": "mul",
    ]

    /// Renvoie un code ISO 639-1 en minuscules, ou `nil` si non reconnu.
    public static func normalize(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "_", with: "-")
        if let mapped = iso639_2[s] { return mapped == "und" ? nil : mapped }
        let base = String(s.split(separator: "-").first ?? Substring(s))
        if base.count == 2 { return base }
        if let mapped = iso639_2[base] { return mapped == "und" ? nil : mapped }
        // Noms complets fréquents dans les libellés d'addons.
        switch base {
        case "french", "français", "francais": return "fr"
        case "english", "anglais": return "en"
        case "spanish", "español", "espagnol": return "es"
        case "german", "deutsch", "allemand": return "de"
        case "italian", "italiano", "italien": return "it"
        case "portuguese", "português", "portugais": return "pt"
        case "japanese", "japonais": return "ja"
        default: return nil
        }
    }

    /// Nom affichable en français (« Français », « Anglais »…).
    public static func displayName(_ code: String?, locale: Locale = Locale(identifier: "fr_FR")) -> String {
        guard let code, let norm = normalize(code) else { return "Inconnue" }
        if norm == "mul" { return "Multilingue" }
        return locale.localizedString(forLanguageCode: norm)?.capitalized(with: locale) ?? norm.uppercased()
    }
}
