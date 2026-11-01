import Foundation
#if canImport(Compression)
import Compression
#endif

/// Champ `state.watched` d'un `libraryItem` Stremio : épisodes vus d'une série.
///
/// Format (module `stremio-watched-bitfield`) :
/// `{idVidéoAncre}:{longueurAncre}:{base64(zlib(bitfield))}`, bit *i* du
/// tableau = vidéo *i* (bit de poids faible en premier dans chaque octet), les
/// vidéos étant triées par (saison, épisode, date de sortie).
///
/// Implémenté d'après le code source JavaScript de référence ; la
/// compatibilité réelle avec les données d'un compte reste à valider.
public struct WatchedBitField: Sendable, Hashable {
    public private(set) var videoIDs: [String]
    private var bits: [UInt8]

    public init(videoIDs: [String]) {
        self.videoIDs = videoIDs
        self.bits = [UInt8](repeating: 0, count: (videoIDs.count + 7) / 8)
    }

    /// Ordre utilisé par stremio-core (`LibraryItem::watched_bitfield`).
    public static func orderedVideoIDs(_ videos: [MetaVideo]) -> [String] {
        let minValue = Int64.min
        return videos.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let sa = a.season.map(Int64.init) ?? minValue, sb = b.season.map(Int64.init) ?? minValue
            if sa != sb { return sa < sb }
            let ea = a.season == nil ? minValue : (a.episode.map(Int64.init) ?? minValue)
            let eb = b.season == nil ? minValue : (b.episode.map(Int64.init) ?? minValue)
            if ea != eb { return ea < eb }
            let ra = a.released.map { Int64($0.timeIntervalSince1970 * 1000) } ?? minValue
            let rb = b.released.map { Int64($0.timeIntervalSince1970 * 1000) } ?? minValue
            if ra != rb { return ra < rb }
            return lhs.offset < rhs.offset  // tri stable
        }.map(\.element.id)
    }

    /// Reconstruit le champ à partir de sa forme sérialisée, en le recalant sur
    /// la liste de vidéos actuelle. Renvoie un champ vierge si l'ancre est introuvable.
    public init(serialized: String, videoIDs: [String]) throws {
        var components = serialized.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3 else { throw WatchedBitFieldError.invalidFormat }
        let payload = components.removeLast()
        guard let anchorLength = Int(components.removeLast()), anchorLength >= 0 else { throw WatchedBitFieldError.invalidFormat }
        let anchorID = components.joined(separator: ":")
        self.init(videoIDs: videoIDs)
        guard let anchorIndex = videoIDs.firstIndex(of: anchorID) else { return }
        guard let compressed = Data(base64Encoded: payload) else { throw WatchedBitFieldError.invalidFormat }
        let previous = try Self.inflate(compressed)
        let offset = (anchorLength - 1) - anchorIndex
        for i in 0..<videoIDs.count {
            let j = i + offset
            guard j >= 0, j < anchorLength else { continue }
            let byte = j / 8
            guard byte < previous.count else { continue }
            if previous[byte] & (1 << UInt8(j % 8)) != 0 { set(index: i, true) }
        }
    }

    public func isWatched(_ videoID: String) -> Bool {
        guard let i = videoIDs.firstIndex(of: videoID) else { return false }
        return get(index: i)
    }

    public mutating func setWatched(_ videoID: String, _ watched: Bool) {
        guard let i = videoIDs.firstIndex(of: videoID) else { return }
        set(index: i, watched)
    }

    public var watchedIDs: Set<String> {
        Set(videoIDs.indices.filter { get(index: $0) }.map { videoIDs[$0] })
    }

    public func serialize() throws -> String {
        var last = 0
        for i in stride(from: videoIDs.count - 1, through: 0, by: -1) where get(index: i) {
            last = i
            break
        }
        guard !videoIDs.isEmpty else { throw WatchedBitFieldError.empty }
        let packed = try Self.deflate(Data(bits))
        return "\(videoIDs[last]):\(last + 1):\(packed.base64EncodedString())"
    }

    private func get(index i: Int) -> Bool {
        let byte = i / 8
        guard byte < bits.count else { return false }
        return bits[byte] & (1 << UInt8(i % 8)) != 0
    }

    private mutating func set(index i: Int, _ value: Bool) {
        let byte = i / 8
        guard byte < bits.count else { return }
        if value { bits[byte] |= (1 << UInt8(i % 8)) } else { bits[byte] &= ~(1 << UInt8(i % 8)) }
    }

    // MARK: zlib (RFC 1950) autour du DEFLATE brut du framework Compression

    static func inflate(_ data: Data) throws -> [UInt8] {
        #if canImport(Compression)
        guard data.count > 6 else { throw WatchedBitFieldError.invalidFormat }
        let raw = data.dropFirst(2)  // en-tête zlib ; la somme Adler-32 finale est ignorée par le décodeur
        var capacity = max(raw.count * 8, 1024)
        while capacity <= 16 * 1024 * 1024 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&output, capacity, base, src.count, nil, COMPRESSION_ZLIB)
            }
            if written == 0 { throw WatchedBitFieldError.invalidFormat }
            if written < capacity { return Array(output.prefix(written)) }
            capacity *= 4
        }
        throw WatchedBitFieldError.invalidFormat
        #else
        throw WatchedBitFieldError.unsupportedPlatform
        #endif
    }

    static func deflate(_ data: Data) throws -> Data {
        #if canImport(Compression)
        let capacity = data.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, capacity, base, src.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 || data.isEmpty else { throw WatchedBitFieldError.invalidFormat }
        var result = Data([0x78, 0x9C])
        result.append(contentsOf: output.prefix(written))
        let adler = adler32(data)
        result.append(contentsOf: [UInt8(adler >> 24 & 0xFF), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return result
        #else
        throw WatchedBitFieldError.unsupportedPlatform
        #endif
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

public enum WatchedBitFieldError: Error, Sendable {
    case invalidFormat, empty, unsupportedPlatform
}
