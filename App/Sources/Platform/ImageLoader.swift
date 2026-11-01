import SwiftUI
import UIKit
import ImageIO
import LanterneCore

/// Chargement d'images distant : cache mémoire (images décodées et réduites à
/// la taille d'affichage), cache disque HTTP dans `Library/Caches`,
/// dédoublonnage des requêtes simultanées, annulation.
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 160 * 1024 * 1024
        let config = URLSessionConfiguration.default
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Images", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: cacheDir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    /// Image réduite pour un côté maximal de `maxPixel` pixels.
    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let key = "\(url.absoluteString)#\(maxPixel)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count < 25 * 1024 * 1024 else { return nil }
            return Self.downsample(data, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }

    func clearMemory() { memory.removeAllObjects() }
}

/// Image distante avec fondu d'apparition et emplacement de remplacement.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    let maxPixel: Int
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    /// Appelé avec l'image chargée (teinte ambiante, etc.).
    var onLoaded: ((UIImage) -> Void)?

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            // Le remplaçant disparaît une fois l'image chargée : indispensable pour
            // les logos transparents (sinon le titre texte reste visible dessous).
            if image == nil {
                placeholder()
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if loadedURL != url { image = nil }
            let loaded = await ImageLoader.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                image = loaded
                loadedURL = url
            }
            if let loaded { onLoaded?(loaded) }
        }
    }
}
