import Foundation

/// Ce que l'application peut faire d'un flux, **avant** toute tentative de lecture.
public enum Playability: Sendable, Hashable {
    /// URL HTTP(S) lisible directement par un moteur de l'application.
    case direct(PlayableSource)
    /// Torrent résolu en HTTP par un serveur de streaming Stremio externe
    /// (configuré par l'utilisateur, ex. conteneur Docker sur le NAS).
    case viaStreamingServer(PlayableSource)
    /// Non lisible ; `reason` est affichable tel quel.
    case unsupported(reason: String)

    public var playable: PlayableSource? {
        switch self {
        case .direct(let p), .viaStreamingServer(let p): p
        case .unsupported: nil
        }
    }

    public var isPlayable: Bool { playable != nil }
}

/// Estimation de compatibilité avec les moteurs (déduite des caractéristiques annoncées).
public enum EngineFit: Int, Sendable, Hashable, Comparable {
    /// Conteneur et codecs annoncés acceptés par AVFoundation sans conversion.
    case native = 3
    /// Nécessite le moteur FFmpeg (MKV, DTS, TrueHD, AVI…).
    case needsFFmpeg = 2
    /// Caractéristiques inconnues : le moteur décidera à l'ouverture.
    case unknown = 1
    /// Probablement illisible sur Apple TV (codec annoncé non pris en charge).
    case unlikely = 0

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .native: "Natif"
        case .needsFFmpeg: "FFmpeg"
        case .unknown: "À vérifier"
        case .unlikely: "Peu probable"
        }
    }
}

/// Source prête à être confiée à un moteur de lecture.
public struct PlayableSource: Sendable, Hashable {
    public var url: URL
    /// En-têtes HTTP exigés par la source (`behaviorHints.proxyHeaders.request`), filtrés.
    public var headers: [String: String]
    public var fit: EngineFit

    public init(url: URL, headers: [String: String] = [:], fit: EngineFit) {
        self.url = url; self.headers = headers; self.fit = fit
    }
}

public enum PlayabilityClassifier {
    /// - Parameter streamingServer: URL de base d'un serveur de streaming
    ///   Stremio (ex. `http://192.168.1.10:11470`), ou `nil`.
    public static func classify(_ stream: StreamItem, traits: StreamTraits, streamingServer: URL?) -> Playability {
        switch stream.source {
        case .url(let url):
            // Note : un flux HTTP en clair vers Internet n'est lisible que grâce à
            // l'exception ATS « médias » (NSAllowsArbitraryLoadsForMedia).
            let headers = stream.behaviorHints.proxyHeaders?.request ?? [:]
            return .direct(PlayableSource(url: url, headers: headers, fit: fit(for: traits)))
        case .torrent(let hash, let index, let announce, let mustInclude):
            guard let server = streamingServer else {
                return .unsupported(reason: "Torrent : nécessite un serveur de streaming Stremio (Réglages › Lecture).")
            }
            guard let url = torrentURL(server: server, infoHash: hash, fileIndex: index, announce: announce, fileMustInclude: mustInclude) else {
                return .unsupported(reason: "Adresse du serveur de streaming invalide.")
            }
            return .viaStreamingServer(PlayableSource(url: url, fit: fit(for: traits)))
        case .youtube:
            return .unsupported(reason: "Vidéo YouTube : non prise en charge.")
        case .external:
            return .unsupported(reason: "Lien externe : s'ouvre hors de l'application.")
        case .playerFrame:
            return .unsupported(reason: "Lecteur web intégré : non pris en charge.")
        case .archive(let kind):
            return .unsupported(reason: "Archive \(kind.uppercased()) : non prise en charge.")
        case .unsupported:
            return .unsupported(reason: "Type de source inconnu.")
        }
    }

    /// URL torrent du serveur de streaming, au format de stremio-core :
    /// `<serveur>/<infoHash>/<fileIdx ou -1>?tr=…&f=…`.
    public static func torrentURL(server: URL, infoHash: String, fileIndex: Int?, announce: [String], fileMustInclude: [String]) -> URL? {
        guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = path + "/\(infoHash.lowercased())/\(fileIndex.map(String.init) ?? "-1")"
        var items: [URLQueryItem] = announce.map { URLQueryItem(name: "tr", value: $0) }
        items += fileMustInclude.map { URLQueryItem(name: "f", value: $0) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
    }

    /// Compatibilité estimée à partir des caractéristiques **annoncées**.
    public static func fit(for t: StreamTraits) -> EngineFit {
        if let codec = t.videoCodec, codec == .mpeg2 { return .needsFFmpeg }
        switch t.container {
        case .mkv, .avi, .webm, .mpegts, .dash:
            return .needsFFmpeg
        case .hls:
            return .native
        case .mp4, .mov:
            if t.audioCodecs.contains(where: { !$0.isNativeOnAppleTV }) { return .needsFFmpeg }
            if let codec = t.videoCodec, codec == .vp9 || codec == .mpeg4 { return .needsFFmpeg }
            return .native
        case .unknown:
            if t.audioCodecs.contains(where: { !$0.isNativeOnAppleTV }) { return .needsFFmpeg }
            return .unknown
        }
    }
}
