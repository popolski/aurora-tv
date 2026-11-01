import Foundation

/// Valeur JSON arbitraire. Sert à conserver intactes les données qu'on ne
/// comprend pas (champs d'un `libraryItem` Stremio, par exemple) afin de ne
/// jamais les détruire lors d'une réécriture.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Valeur JSON non reconnue")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Préserve les entiers (timeOffset en ms, etc.) sans « .0 ».
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n ? String(Int64(n)) : String(n)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        default: nil
        }
    }
}

/// Clé de codage dynamique.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?
    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// Décodage tolérant : les réponses d'addons sont des données externes non
/// fiables. Un élément invalide est ignoré plutôt que de faire échouer la liste.
extension KeyedDecodingContainer {
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !nested.isAtEnd {
            if let value = try? nested.decode(T.self) {
                result.append(value)
            } else {
                // Avance d'un élément même s'il est invalide.
                _ = try? nested.decode(JSONValue.self)
            }
        }
        return result
    }

    /// Chaîne tolérante : accepte aussi un nombre (`"year": 2019` vs `"2019"`).
    func lenientString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    /// URL tolérante : chaîne vide, invalide ou schéma non HTTP(S) → nil.
    func lenientURL(forKey key: Key, allowedSchemes: Set<String> = ["http", "https"]) -> URL? {
        guard let s = lenientString(forKey: key), let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    /// Liste de chaînes tolérante (accepte aussi une chaîne unique).
    func lenientStrings(forKey key: Key) -> [String] {
        if let arr = try? decodeIfPresent([JSONValue].self, forKey: key) {
            return arr.compactMap(\.stringValue).filter { !$0.isEmpty }
        }
        if let s = lenientString(forKey: key) { return [s] }
        return []
    }

    func lenientBool(forKey key: Key) -> Bool {
        (try? decodeIfPresent(JSONValue.self, forKey: key))?.boolValue ?? false
    }

    func lenientInt(forKey key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    func lenientInt64(forKey key: Key) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite { return Int64(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    /// Date tolérante : ISO 8601 (avec ou sans fractions) ou millisecondes Unix.
    func lenientDate(forKey key: Key) -> Date? {
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return StremioDate.parse(s)
        }
        if let ms = try? decodeIfPresent(Double.self, forKey: key), ms.isFinite {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }
}

/// Dates au format utilisé par l'API Stremio (RFC 3339 côté chrono/Rust,
/// `toISOString()` côté JavaScript).
public enum StremioDate {
    public static func parse(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = withFraction().date(from: s) { return d }
        if let d = plain().date(from: s) { return d }
        // Date seule (« 2019-05-03 »).
        if s.count == 10 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)
        }
        return nil
    }

    /// Format d'écriture : `2026-11-01T10:00:00.000Z` (identique à JavaScript).
    public static func format(_ date: Date) -> String {
        withFraction().string(from: date)
    }

    private static func withFraction() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func plain() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}
