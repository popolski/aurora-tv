import Foundation

public enum VideoResolution: Int, Sendable, Codable, Comparable, CaseIterable {
    case sd = 480, hd720 = 720, fhd1080 = 1080, qhd1440 = 1440, uhd2160 = 2160

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .sd: "SD"
        case .hd720: "720p"
        case .fhd1080: "1080p"
        case .qhd1440: "1440p"
        case .uhd2160: "4K"
        }
    }

    public init(height: Int) {
        switch height {
        case 1800...: self = .uhd2160
        case 1300..<1800: self = .qhd1440
        case 900..<1300: self = .fhd1080
        case 650..<900: self = .hd720
        default: self = .sd
        }
    }
}

public enum HDRFormat: String, Sendable, Codable, CaseIterable {
    case dolbyVision, hdr10Plus, hdr10, hlg

    public var label: String {
        switch self {
        case .dolbyVision: "Dolby Vision"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR10"
        case .hlg: "HLG"
        }
    }

    public var shortLabel: String {
        switch self {
        case .dolbyVision: "DV"
        case .hdr10Plus: "HDR10+"
        case .hdr10: "HDR"
        case .hlg: "HLG"
        }
    }
}

public enum VideoCodec: String, Sendable, Codable {
    case hevc, avc, av1, vp9, mpeg4, mpeg2
    public var label: String {
        switch self {
        case .hevc: "HEVC"
        case .avc: "H.264"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .mpeg4: "MPEG-4"
        case .mpeg2: "MPEG-2"
        }
    }
}

public enum AudioCodec: String, Sendable, Codable, CaseIterable {
    case trueHD, dtsX, dtsHDMA, dts, eac3, ac3, aac, flac, opus, mp3

    public var label: String {
        switch self {
        case .trueHD: "TrueHD"
        case .dtsX: "DTS:X"
        case .dtsHDMA: "DTS-HD MA"
        case .dts: "DTS"
        case .eac3: "E-AC-3"
        case .ac3: "AC-3"
        case .aac: "AAC"
        case .flac: "FLAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        }
    }

    /// Format accepté tel quel par AVFoundation sur tvOS (sans transcodage).
    public var isNativeOnAppleTV: Bool {
        switch self {
        case .eac3, .ac3, .aac, .flac, .mp3: true
        case .trueHD, .dtsX, .dtsHDMA, .dts, .opus: false
        }
    }
}

public enum SourceQuality: Int, Sendable, Codable, Comparable {
    case cam = 0, unknown = 1, hdtv = 2, webRip = 3, web = 4, webDL = 5, bluRay = 6, remux = 7

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String? {
        switch self {
        case .cam: "CAM"
        case .unknown: nil
        case .hdtv: "HDTV"
        case .webRip: "WEBRip"
        case .web: "WEB"
        case .webDL: "WEB-DL"
        case .bluRay: "BluRay"
        case .remux: "REMUX"
        }
    }
}

public enum ContainerFormat: String, Sendable, Codable {
    case mp4, mov, mkv, webm, avi, mpegts, hls, dash, unknown

    public var label: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .webm: "WebM"
        case .avi: "AVI"
        case .mpegts: "MPEG-TS"
        case .hls: "HLS"
        case .dash: "DASH"
        case .unknown: "?"
        }
    }

    static func from(pathExtension ext: String) -> ContainerFormat {
        switch ext.lowercased() {
        case "mp4", "m4v": .mp4
        case "mov": .mov
        case "mkv", "mk3d": .mkv
        case "webm": .webm
        case "avi": .avi
        case "ts", "m2ts", "mts": .mpegts
        case "m3u8": .hls
        case "mpd": .dash
        default: .unknown
        }
    }
}

/// Caractéristiques **annoncées** d'un flux, déduites du nom, de la
/// description et du nom de fichier fournis par l'addon.
///
/// Ces informations peuvent être fausses (nommage libre). Elles ne sont jamais
/// présentées comme mesurées ; les caractéristiques réellement détectées par
/// le moteur de lecture sont stockées à part (`DetectedMediaInfo`).
public struct StreamTraits: Sendable, Hashable, Codable {
    public var resolution: VideoResolution?
    public var hdr: [HDRFormat] = []
    public var videoCodec: VideoCodec?
    public var bitDepth10: Bool = false
    public var audioCodecs: [AudioCodec] = []
    public var atmos: Bool = false
    public var audioChannels: String?
    /// Langues audio annoncées (ISO 639-1).
    public var audioLanguages: [String] = []
    public var isMultiAudio: Bool = false
    /// Version originale sous-titrée en français.
    public var isVOSTFR: Bool = false
    /// Variante française annoncée : « VFF », « VFQ », « VFI », « TRUEFRENCH »…
    public var frenchVariant: String?
    public var sizeBytes: Int64?
    /// La taille provient de `behaviorHints.videoSize` (champ structuré) plutôt que du texte.
    public var sizeFromHints: Bool = false
    public var container: ContainerFormat = .unknown
    public var sourceQuality: SourceQuality = .unknown
    public var seeders: Int?
    /// Lien annoncé « en cache » chez un service de débridage (« [RD+] », « ⚡ »).
    public var debridCached: Bool = false

    public init() {}

    public var hasFrench: Bool { audioLanguages.contains("fr") }

    public var sizeLabel: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum StreamTraitsParser {
    private static let b = "(?<![\\p{L}0-9])"
    private static let e = "(?![\\p{L}0-9])"

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    nonisolated(unsafe) private static let patterns: [String: NSRegularExpression] = [
        "2160": rx("\(b)(2160p|4k|uhd)\(e)"),
        "1440": rx("\(b)1440p\(e)"),
        "1080": rx("\(b)(1080p|1080i|fhd)\(e)"),
        "720": rx("\(b)720p\(e)"),
        "sd": rx("\(b)(576p|480p|360p|sd|dvdrip)\(e)"),
        "dv": rx("\(b)(dv|dovi|dolby\\s?vision)\(e)"),
        "hdr10p": rx("\(b)hdr10(\\+|plus)"),
        "hdr10": rx("\(b)hdr10(?![\\p{L}0-9+])"),
        "hdr": rx("\(b)hdr\(e)"),
        "hlg": rx("\(b)hlg\(e)"),
        "hevc": rx("\(b)(hevc|x265|h\\.?265)\(e)"),
        "avc": rx("\(b)(avc|x264|h\\.?264)\(e)"),
        "av1": rx("\(b)av1\(e)"),
        "vp9": rx("\(b)vp9\(e)"),
        "mpeg4": rx("\(b)(xvid|divx)\(e)"),
        "10bit": rx("\(b)(10bit|10-bit|hi10p)\(e)"),
        "truehd": rx("\(b)true-?hd\(e)"),
        "atmos": rx("\(b)atmos\(e)"),
        "dtsx": rx("\(b)dts[:\\-]?x\(e)"),
        "dtshd": rx("\(b)(dts-?hd(\\s?ma)?|dts-?ma)\(e)"),
        "dts": rx("\(b)dts(?![\\p{L}])"),
        "eac3": rx("\(b)(e-?ac-?3|ddp|dd\\+|dolby\\s?digital\\s?plus)(?![\\p{L}])"),
        "ac3": rx("\(b)(ac-?3|dd)(?![\\p{L}+])"),
        "aac": rx("\(b)aac(?![\\p{L}])"),
        "flac": rx("\(b)flac(?![\\p{L}])"),
        "opus": rx("\(b)opus\(e)"),
        "mp3": rx("\(b)mp3\(e)"),
        "channels": rx("(?<![0-9])(?<![0-9]\\.)(7\\.1|5\\.1|2\\.0)(?![0-9])"),
        "remux": rx("\(b)remux\(e)"),
        "bluray": rx("\(b)(blu-?ray|bdrip|brrip)\(e)"),
        "webdl": rx("\(b)web-?dl\(e)"),
        "webrip": rx("\(b)web-?rip\(e)"),
        "web": rx("\(b)web\(e)"),
        "hdtv": rx("\(b)hdtv\(e)"),
        "cam": rx("\(b)(cam|camrip|hdcam|telesync|hdts|hdtc|telecine|screener)\(e)"),
        "multi": rx("\(b)(multi(-?lang|-?audio)?|dual[\\s.-]?audio)\(e)"),
        "vostfr": rx("\(b)(vostfr|subfrench|vost-?fr)\(e)"),
        "french": rx("\(b)(vff|vfq|vfi|vf2|vf|truefrench|french|fr|fra|fre|fran[cç]ais)\(e)"),
        "english": rx("\(b)(eng|english|anglais)\(e)"),
        "spanish": rx("\(b)(spa|spanish|espa[nñ]ol|castellano|latino)\(e)"),
        "german": rx("\(b)(ger|german|deutsch)\(e)"),
        "italian": rx("\(b)(ita|italian|italiano)\(e)"),
        "japanese": rx("\(b)(jpn|japanese)\(e)"),
        "korean": rx("\(b)(kor|korean)\(e)"),
        "russian": rx("\(b)(rus|russian)\(e)"),
        "portuguese": rx("\(b)(por|portuguese|portugu[eê]s)\(e)"),
        "size": rx("(\\d+(?:[.,]\\d+)?)\\s?(tb|to|tib|gb|gib|go|mb|mib|mo)\(e)"),
        "seeders": rx("👤\\s?(\\d+)"),
        "cached": rx("\\[(rd|ad|pm|dl|tb|ed|oc|pp|dlh|en)\\+\\]|⚡"),
    ]

    private static let flagLanguages: [String: String] = [
        "🇫🇷": "fr", "🇬🇧": "en", "🇺🇸": "en", "🇪🇸": "es", "🇲🇽": "es", "🇩🇪": "de", "🇮🇹": "it",
        "🇵🇹": "pt", "🇧🇷": "pt", "🇯🇵": "ja", "🇰🇷": "ko", "🇷🇺": "ru", "🇨🇳": "zh", "🇮🇳": "hi",
        "🇳🇱": "nl", "🇵🇱": "pl", "🇹🇷": "tr", "🇺🇦": "uk",
    ]

    private static func has(_ key: String, _ text: String) -> Bool {
        guard let r = patterns[key] else { return false }
        return r.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstGroup(_ key: String, _ text: String, group: Int = 1) -> String? {
        guard let r = patterns[key],
              let m = r.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > group, let range = Range(m.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    public static func parse(_ stream: StreamItem) -> StreamTraits {
        var t = parse(text: stream.announcedText)
        if let size = stream.behaviorHints.videoSize {
            t.sizeBytes = size
            t.sizeFromHints = true
        }
        if t.container == .unknown {
            if let name = stream.behaviorHints.filename {
                t.container = ContainerFormat.from(pathExtension: (name as NSString).pathExtension)
            }
            if t.container == .unknown, case .url(let url) = stream.source {
                t.container = ContainerFormat.from(pathExtension: url.pathExtension)
            }
        }
        return t
    }

    public static func parse(text: String) -> StreamTraits {
        var t = StreamTraits()
        if has("2160", text) { t.resolution = .uhd2160 }
        else if has("1440", text) { t.resolution = .qhd1440 }
        else if has("1080", text) { t.resolution = .fhd1080 }
        else if has("720", text) { t.resolution = .hd720 }
        else if has("sd", text) { t.resolution = .sd }

        if has("dv", text) { t.hdr.append(.dolbyVision) }
        if has("hdr10p", text) { t.hdr.append(.hdr10Plus) }
        if has("hdr10", text) || (has("hdr", text) && !t.hdr.contains(.hdr10Plus)) { t.hdr.append(.hdr10) }
        if has("hlg", text) { t.hdr.append(.hlg) }

        if has("hevc", text) { t.videoCodec = .hevc }
        else if has("av1", text) { t.videoCodec = .av1 }
        else if has("avc", text) { t.videoCodec = .avc }
        else if has("vp9", text) { t.videoCodec = .vp9 }
        else if has("mpeg4", text) { t.videoCodec = .mpeg4 }
        t.bitDepth10 = has("10bit", text)

        var audio: [AudioCodec] = []
        if has("truehd", text) { audio.append(.trueHD) }
        if has("dtsx", text) { audio.append(.dtsX) }
        else if has("dtshd", text) { audio.append(.dtsHDMA) }
        else if has("dts", text) { audio.append(.dts) }
        if has("eac3", text) { audio.append(.eac3) }
        else if has("ac3", text) { audio.append(.ac3) }
        if has("aac", text) { audio.append(.aac) }
        if has("flac", text) { audio.append(.flac) }
        if has("opus", text) { audio.append(.opus) }
        if has("mp3", text) { audio.append(.mp3) }
        t.audioCodecs = audio
        t.atmos = has("atmos", text)
        t.audioChannels = firstGroup("channels", text)

        if has("remux", text) { t.sourceQuality = .remux }
        else if has("bluray", text) { t.sourceQuality = .bluRay }
        else if has("webdl", text) { t.sourceQuality = .webDL }
        else if has("webrip", text) { t.sourceQuality = .webRip }
        else if has("web", text) { t.sourceQuality = .web }
        else if has("hdtv", text) { t.sourceQuality = .hdtv }
        if has("cam", text) { t.sourceQuality = .cam }

        // Langues.
        var langs: [String] = []
        func add(_ code: String) { if !langs.contains(code) { langs.append(code) } }
        t.isVOSTFR = has("vostfr", text)
        t.isMultiAudio = has("multi", text)
        if let variant = firstGroup("french", text) {
            add("fr")
            let upper = variant.uppercased()
            if ["VFF", "VFQ", "VFI", "VF2", "TRUEFRENCH"].contains(upper) { t.frenchVariant = upper }
        }
        if has("english", text) { add("en") }
        if has("spanish", text) { add("es") }
        if has("german", text) { add("de") }
        if has("italian", text) { add("it") }
        if has("japanese", text) { add("ja") }
        if has("korean", text) { add("ko") }
        if has("russian", text) { add("ru") }
        if has("portuguese", text) { add("pt") }
        // Drapeaux dans l'ordre d'apparition (le dictionnaire n'est pas ordonné).
        let flags = flagLanguages.compactMap { flag, code -> (String.Index, String)? in
            text.range(of: flag).map { ($0.lowerBound, code) }
        }.sorted { $0.0 < $1.0 }
        for (_, code) in flags { add(code) }
        // VOSTFR : la piste audio n'est pas française (sauf mention explicite d'une VF).
        if t.isVOSTFR, firstGroup("french", text).map({ $0.lowercased().hasPrefix("vf") || $0.lowercased() == "truefrench" }) != true {
            langs.removeAll { $0 == "fr" }
        }
        t.audioLanguages = langs

        if let r = patterns["size"],
           let m = r.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let numRange = Range(m.range(at: 1), in: text), let unitRange = Range(m.range(at: 2), in: text),
           let value = Double(text[numRange].replacingOccurrences(of: ",", with: ".")) {
            let unit = text[unitRange].lowercased()
            let multiplier: Double = switch unit {
            case "tb", "to", "tib": 1_099_511_627_776
            case "gb", "gib", "go": 1_073_741_824
            default: 1_048_576
            }
            t.sizeBytes = Int64(value * multiplier)
        }
        if let s = firstGroup("seeders", text) { t.seeders = Int(s) }
        t.debridCached = has("cached", text)

        // Conteneur depuis une extension présente dans le texte (nom de fichier).
        for line in text.split(separator: "\n") {
            let ext = (String(line) as NSString).pathExtension
            let c = ContainerFormat.from(pathExtension: ext)
            if c != .unknown { t.container = c; break }
        }
        return t
    }
}
