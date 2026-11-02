import Foundation
import CoreGraphics
import UIKit
import Vision
import LanterneCore

/// Le logo de titre est-il lisible (lettres latines) ? Certains addons fournissent le logo
/// dans la langue d'origine (coréen, japonais…) alors que le titre est déjà lisible.
///
/// Reconnaissance de texte de tvOS (Vision), hors du fil principal : lecture rapide
/// (lettres latines) d'abord, lecture complète seulement si elle ne trouve rien de sûr.
/// Logo sans texte reconnaissable (police très stylisée) : on se fie à l'origine du film.
actor LogoCheck {
    static let shared = LogoCheck()
    private var cache: [URL: Bool] = [:]

    func isReadable(_ url: URL, nonLatinOrigin: Bool) async -> Bool {
        if let cached = cache[url] { return cached }
        guard let image = await ImageLoader.shared.image(for: url, maxPixel: 700), let cg = image.cgImage,
              let flattened = Self.flattened(cg) else { return true }
        let readable: Bool
        if Self.latinText(in: flattened) {
            readable = true
        } else {
            let text = Self.anyText(in: flattened)
            readable = text.isEmpty ? !nonLatinOrigin : !TitleLocalizer.needsLocalization(text)
        }
        cache[url] = readable
        return readable
    }

    /// Logo posé sur un gris moyen : le texte, clair ou foncé, ressort sur la transparence.
    private nonisolated static func flattened(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Lecture rapide : au moins 3 lettres latines reconnues avec assurance.
    private nonisolated static func latinText(in image: CGImage) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let letters = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.6 }
            .map(\\.string)
            .joined()
            .unicodeScalars.filter { $0.properties.isAlphabetic }
        return letters.count >= 3 && !TitleLocalizer.needsLocalization(String(String.UnicodeScalarView(letters)))
    }

    /// Lecture complète, langue détectée automatiquement (coréen, japonais, chinois…).
    private nonisolated static func anyText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
