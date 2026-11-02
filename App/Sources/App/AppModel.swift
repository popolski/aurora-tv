import Foundation
import Observation
import SwiftUI
import LanterneCore

/// Ce qu'il faut lire : contenu, vidéo (épisode), source choisie.
nonisolated struct PlaybackContext: Identifiable {
    let id = UUID()
    var meta: MetaItem
    /// Identifiant de la vidéo lue (`tt…` pour un film, `tt…:S:E` pour un épisode).
    var videoID: String
    var video: MetaVideo?
    var source: RankedSource?
    /// Lecture d'un fichier local (diagnostic) sans addon.
    var localTest: LocalTestMedia?
    var startPosition: TimeInterval?
    /// Toutes les sources trouvées pour cette vidéo (changement de source en cours de lecture).
    var alternatives: [RankedSource] = []
}

/// Médias de test embarqués (mires générées avec FFmpeg, libres de droits).
nonisolated struct LocalTestMedia: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let fileName: String
    let externalSubtitle: String?

    var url: URL? { Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "TestMedia") }
    var subtitleURL: URL? {
        externalSubtitle.flatMap { Bundle.main.url(forResource: $0, withExtension: nil, subdirectory: "TestMedia") }
    }

    static let all: [LocalTestMedia] = [
        .init(id: "h264", title: "MP4 · H.264 · AAC", detail: "Chemin natif AVFoundation. Mire mobile, horodatage, bip et flash blanc chaque seconde.",
              fileName: "test-h264-aac.mp4", externalSubtitle: "test-external-fr.srt"),
        .init(id: "hevc", title: "MKV · HEVC 10 bits · E-AC-3 + AAC", detail: "Deux pistes audio (fr 440 Hz, en 660 Hz), sous-titres SRT (fr) et ASS (en) intégrés.",
              fileName: "test-hevc10-multi.mkv", externalSubtitle: nil),
        .init(id: "dts", title: "MKV · H.264 · DTS", detail: "Audio DTS décodé par le moteur FFmpeg (non natif sur Apple TV).",
              fileName: "test-h264-dts.mkv", externalSubtitle: nil),
    ]
}

/// État global de l'application et accès aux services.
@MainActor
@Observable
final class AppModel {
    // Services (non observés).
    @ObservationIgnored let addonClient: AddonClient
    @ObservationIgnored let aggregator: AddonAggregator
    @ObservationIgnored let registry: AddonRegistry
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let account: AccountService
    /// Minutages communautaires (intro, résumé, générique).
    @ObservationIgnored let skipTimes: SkipTimesClient
    /// Notes Rotten Tomatoes / Metacritic (Wikidata).
    @ObservationIgnored let reviews: ReviewScoresClient
    @ObservationIgnored let defaults: any KeyValueStore
    @ObservationIgnored let isUITest: Bool
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastForegroundSync = Date.distantPast
    @ObservationIgnored let log = LogChannel("app")

    // État observé par l'interface.
    var addons: [AddonDescriptor] = []
    var addonStatuses: [AddonRegistry.Status] = []
    var continueWatching: [LibraryItem] = []
    var libraryItems: [LibraryItem] = []
    var history: [LibraryItem] = []
    /// Films déjà vus (bibliothèque et historique), pour estomper ou masquer dans les catalogues.
    private(set) var watchedMovieIDs: Set<String> = []
    var session: StremioSession?
    var syncState: AccountService.SyncState = .idle
    var isBootstrapped = false
    /// Incrémenté à chaque changement de bibliothèque (pour rafraîchir les fiches).
    var libraryRevision = 0
    var playback: PlaybackContext?
    /// Bande-annonce affichée en plein écran (la bande-annonce de fond se met en pause).
    var isTrailerPresented = false
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.encode(settings, forKey: Self.settingsKey)
            if !isUITest { TopShelfBridge.publish(settings) }
        }
    }

    static let settingsKey = "settings.v1"

    init(addonClient: AddonClient, registry: AddonRegistry, library: LibraryStore, account: AccountService,
         skipTimes: SkipTimesClient, reviews: ReviewScoresClient, titles: TitleLocalizer?,
         defaults: any KeyValueStore, isUITest: Bool) {
        self.skipTimes = skipTimes
        self.reviews = reviews
        self.addonClient = addonClient
        var aggregator = AddonAggregator(client: addonClient)
        aggregator.titles = titles
        self.aggregator = aggregator
        self.registry = registry
        self.library = library
        self.account = account
        self.defaults = defaults
        self.isUITest = isUITest
        self.settings = defaults.decode(AppSettings.self, forKey: Self.settingsKey) ?? AppSettings()
        if !isUITest { TopShelfBridge.publish(settings, force: true) }
    }

    static func make() -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-uitest")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let http: any HTTPClient = isUITest
            ? UITestHTTPClient()
            : URLSessionHTTPClient(userAgent: "Aurora/\(version) (tvOS)")
        let secrets: any SecretStore = isUITest ? InMemorySecretStore() : KeychainSecretStore(service: "io.github.popolski.lanterne")
        let defaults: any KeyValueStore = isUITest ? InMemoryStore() : UserDefaultsStore()
        let fileCache: any KeyValueStore = isUITest ? InMemoryStore() : FileStore.caches(subdirectory: "Lanterne")
        let client = AddonClient(http: http)
        let registry = AddonRegistry(secrets: secrets, cache: fileCache, client: client)
        let library = LibraryStore(file: fileCache, mirror: defaults)
        let account = AccountService(api: StremioAPI(http: http), secrets: secrets, library: library, registry: registry)
        LogSetup.configure(uiTest: isUITest)
        return AppModel(addonClient: client, registry: registry, library: library, account: account,
                        skipTimes: SkipTimesClient(http: http), reviews: ReviewScoresClient(http: http),
                        titles: isUITest ? nil : TitleLocalizer(http: http),
                        defaults: defaults, isUITest: isUITest)
    }

    // MARK: Cycle de vie

    func bootstrap() async {
        guard !isBootstrapped else { return }
        log.info("démarrage \(AppInfo.versionString)")
        startObservers()
        await reloadAddons()
        await reloadLibrary()
        await reloadAccount()
        isBootstrapped = true
        await registry.refreshManifests()
        if session != nil {
            await account.syncAll()
            lastForegroundSync = Date()
        }
    }

    func refreshOnForeground() async {
        guard isBootstrapped, session != nil, Date().timeIntervalSince(lastForegroundSync) > 15 * 60 else { return }
        lastForegroundSync = Date()
        await account.syncAll()
    }

    func flushPersistentState() async {
        await library.flush()
    }

    private func startObservers() {
        let registry = self.registry, library = self.library, account = self.account
        observers.append(Task { [weak self] in
            for await _ in await registry.updates() { await self?.reloadAddons() }
        })
        observers.append(Task { [weak self] in
            for await _ in await library.updates() { await self?.reloadLibrary() }
        })
        observers.append(Task { [weak self] in
            for await _ in await account.updates() { await self?.reloadAccount() }
        })
    }

    func reloadAddons() async {
        addons = await registry.activeDescriptors(hideAdult: settings.hideAdultContent)
        addonStatuses = await registry.statuses()
    }

    func reloadLibrary() async {
        continueWatching = await library.continueWatching()
        libraryItems = await library.libraryItems()
        history = await library.history()
        watchedMovieIDs = Set((libraryItems + history + continueWatching)
            .filter { $0.type == ContentType.movie && $0.isWatched }.map(\.id))
        libraryRevision &+= 1
    }

    func reloadAccount() async {
        session = await account.session
        syncState = await account.syncState
    }

    // MARK: Titres déjà vus

    /// Titres à afficher dans un catalogue (réglage « Masquer » : films vus retirés).
    func visibleTitles(_ metas: [MetaItem]) -> [MetaItem] {
        guard settings.watchedTitles == .hide, !watchedMovieIDs.isEmpty else { return metas }
        return metas.filter { !watchedMovieIDs.contains($0.id) }
    }

    /// Réglage « Estomper » : ce titre est-il un film déjà vu ?
    func isDimmed(_ meta: MetaItem) -> Bool {
        settings.watchedTitles == .dim && watchedMovieIDs.contains(meta.id)
    }

    // MARK: Lecture

    func play(_ context: PlaybackContext) {
        guard playback == nil else { return }
        log.info("lecture demandée : \(context.meta.name) [\(context.videoID)]")
        playback = context
        PlayerPresenter.present(context, app: self)
    }

    /// Appelé à la fermeture du lecteur : envoie la progression au compte.
    func playbackDidEnd() {
        playback = nil
        Task {
            await library.flush()
            await account.pushLibraryChanges()
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var versionString: String { "Aurora \(version) (\(build))" }
}
