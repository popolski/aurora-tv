import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import LanterneCore

/// Images du carrousel avec le titre du film incrusté (logo du film, ou son nom).
///
/// tvOS n'affiche pas le titre dans ce style de carrousel : il doit faire partie de
/// l'image. Les images composées sont écrites dans le conteneur du groupe d'apps,
/// que le système peut lire ; sans groupe, le carrousel garde l'image d'origine.
/// Dessin en Core Graphics / Core Text (utilisables hors du fil principal).
enum TopShelfArtwork {
    static let width = 1920
    static let height = 1080

    private static let inProgressKey = "topshelf.artwork.inProgress"
    private static let disabledUntilKey = "topshelf.artwork.disabledUntil"

    /// Adresse locale de l'image composée de chaque film (si elle a pu être faite à temps).
    ///
    /// Une image à la fois : l'extension dispose de très peu de mémoire, et tvOS l'arrête
    /// sans prévenir si elle en demande trop (constaté au build 28 : carrousel vide).
    /// Si un passage précédent a été interrompu pendant cette étape, la composition est
    /// suspendue 24 h et le carrousel garde les images d'origine.
    static func images(for metas: [MetaItem], deadline: TimeInterval, shared: UserDefaults?) async -> [String: URL] {
        guard let directory = directory() else { return [:] }
        let now = Date()
        if let until = shared?.object(forKey: disabledUntilKey) as? Date, until > now { return [:] }
        if shared?.bool(forKey: inProgressKey) == true {
            shared?.set(now.addingTimeInterval(24 * 3600), forKey: disabledUntilKey)
            shared?.set(false, forKey: inProgressKey)
            shared?.synchronize()
            return [:]
        }
        shared?.set(true, forKey: inProgressKey)
        shared?.synchronize()
        defer {
            shared?.set(false, forKey: inProgressKey)
            shared?.synchronize()
        }
        var images: [String: URL] = [:]
        for meta in metas {
            let remaining = deadline - Date().timeIntervalSince(now)
            guard remaining > 0.5 else { break }
            let url = try? await withDeadline(seconds: remaining) { await image(for: meta, in: directory) }
            if let url = url.flatMap({ $0 }) { images[meta.id] = url }
        }
        cleanup(directory, keeping: Set(images.values.map(\.lastPathComponent)))
        return images
    }

    private static func directory() -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.groupID()) else {
            return nil
        }
        let dir = base.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func image(for meta: MetaItem, in directory: URL) async -> URL? {
        guard let backgroundURL = meta.background, DeepLink.isValidID(meta.id) else { return nil }
        let file = directory.appendingPathComponent("\(meta.id.replacingOccurrences(of: ":", with: "_"))-\(key(for: meta)).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let backgroundData = await TopShelfLoader.fetch(backgroundURL),
              let background = decode(backgroundData, maxPixel: 1920) else { return nil }
        var logo: CGImage?
        if let logoURL = meta.logo, let data = await TopShelfLoader.fetch(logoURL) { logo = decode(data, maxPixel: 800) }
        guard let jpeg = render(background: background, logo: logo, title: meta.name) else { return nil }
        do {
            try jpeg.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// Clé stable (le `Hasher` de Swift change à chaque lancement) : FNV-1a des adresses et du titre.
    private static func key(for meta: MetaItem) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let source = [meta.background?.absoluteString ?? "", meta.logo?.absoluteString ?? "", meta.name, "v1"].joined(separator: "|")
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func cleanup(_ directory: URL, keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// Image 1920×1080 : fond recadré, voile sombre à gauche, titre à gauche au-dessus
    /// de la zone où tvOS affiche ses textes (bas de l'écran).
    static func render(background: CGImage, logo: CGImage?, title: String) -> Data? {
        let W = CGFloat(width), H = CGFloat(height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high

        // Fond recadré pour remplir l'écran.
        let bw = CGFloat(background.width), bh = CGFloat(background.height)
        let scale = max(W / bw, H / bh)
        let drawn = CGSize(width: bw * scale, height: bh * scale)
        ctx.draw(background, in: CGRect(x: (W - drawn.width) / 2, y: (H - drawn.height) / 2, width: drawn.width, height: drawn.height))

        // Voile sombre à gauche (lisibilité du titre). Origine Core Graphics : en bas à gauche.
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.62)
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        if let gradient = CGGradient(colorsSpace: space, colors: [black, clear] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: W * 0.62, y: 0), options: [])
        }

        // Zone du titre : à gauche, bas du titre à 58 % de la hauteur depuis le haut.
        let left = W * 0.05
        let bottom = H * 0.42
        let box = CGSize(width: W * 0.36, height: H * 0.20)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 18, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))

        if let logo {
            let lw = CGFloat(logo.width), lh = CGFloat(logo.height)
            let s = min(box.width / lw, box.height / lh)
            ctx.draw(logo, in: CGRect(x: left, y: bottom, width: lw * s, height: lh * s))
        } else {
            drawTitle(title, in: ctx, origin: CGPoint(x: left, y: bottom), maxWidth: W * 0.45)
        }

        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Nom du film en gras, sur deux lignes au plus, aligné en bas sur `origin`.
    private static func drawTitle(_ title: String, in ctx: CGContext, origin: CGPoint, maxWidth: CGFloat) {
        let size: CGFloat = title.count > 28 ? 72 : 92
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: size * 2.6), nil)
        let rect = CGRect(x: origin.x, y: origin.y, width: maxWidth, height: ceil(fitted.height))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}
