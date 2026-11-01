import Foundation

/// Référence minimale d'un contenu pour créer ou mettre à jour un élément.
public struct LibraryMetaRef: Sendable, Hashable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: URL?
    public var posterShape: PosterShape
    public var defaultVideoID: String?

    public init(id: String, type: String, name: String, poster: URL? = nil, posterShape: PosterShape = .poster, defaultVideoID: String? = nil) {
        self.id = id; self.type = type; self.name = name; self.poster = poster; self.posterShape = posterShape
        self.defaultVideoID = defaultVideoID
    }

    public init(_ meta: MetaItem) {
        self.init(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, posterShape: meta.posterShape,
                  defaultVideoID: meta.defaultVideoID)
    }
}

/// Bibliothèque locale : source de vérité sur l'appareil, synchronisable avec Stremio.
///
/// Persistance : fichier complet en cache (purgeable) + copie de secours
/// compacte des éléments récents dans `UserDefaults` (persistant). Les
/// écritures sont regroupées (au plus une toutes les `saveDelay` secondes)
/// pour ne pas solliciter le stockage pendant la lecture.
public actor LibraryStore {
    public static let watchedThreshold = 0.7
    public static let creditsThreshold = 0.9

    private var items: [String: LibraryItem] = [:]
    private var dirty: Set<String> = []
    private var lastStreams: [String: String] = [:]
    private var lastStreamOrder: [String] = []
    private let file: any KeyValueStore
    private let mirror: any KeyValueStore
    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private let log = LogChannel("library")

    static let fileKey = "library.v1.json"
    static let mirrorKey = "library.mirror.v1"
    static let dirtyKey = "library.dirty.v1"
    static let streamsKey = "library.lastStreams.v1"
    static let mirrorLimit = 150

    public init(file: any KeyValueStore, mirror: any KeyValueStore, saveDelay: TimeInterval = 2) {
        self.file = file
        self.mirror = mirror
        self.saveDelay = saveDelay
        var loaded: [LibraryItem] = file.decode([LibraryItem].self, forKey: Self.fileKey) ?? []
        if loaded.isEmpty, let backup = mirror.decode([LibraryItem].self, forKey: Self.mirrorKey) {
            loaded = backup
            LogChannel("library").warning("cache bibliothèque absent : restauration de \(backup.count) éléments depuis la copie de secours")
        }
        self.items = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.mtime >= b.mtime ? a : b })
        self.dirty = Set(mirror.decode([String].self, forKey: Self.dirtyKey) ?? [])
        if let streams = mirror.decode(LastStreams.self, forKey: Self.streamsKey) {
            self.lastStreams = streams.map
            self.lastStreamOrder = streams.order
        }
    }

    struct LastStreams: Codable {
        var map: [String: String]
        var order: [String]
    }

    // MARK: Lecture

    public func item(_ id: String) -> LibraryItem? { items[id] }

    public func allItems() -> [LibraryItem] { Array(items.values) }

    /// Éléments de la bibliothèque (ajoutés explicitement), du plus récent au plus ancien.
    public func libraryItems(type: String? = nil) -> [LibraryItem] {
        items.values
            .filter { $0.isInLibrary && (type == nil || $0.type == type) }
            .sorted { ($0.ctime ?? $0.mtime) > ($1.ctime ?? $1.mtime) }
    }

    /// « Continuer à regarder », trié par date de visionnage.
    public func continueWatching(limit: Int = 40) -> [LibraryItem] {
        let list = items.values
            .filter(\.isInContinueWatching)
            .sorted { ($0.state.lastWatched ?? $0.mtime) > ($1.state.lastWatched ?? $1.mtime) }
        return Array(list.prefix(limit))
    }

    /// Historique (tout élément déjà visionné), du plus récent au plus ancien.
    public func history(limit: Int = 200) -> [LibraryItem] {
        let list = items.values
            .filter { $0.state.lastWatched != nil && $0.type != "other" }
            .sorted { ($0.state.lastWatched ?? .distantPast) > ($1.state.lastWatched ?? .distantPast) }
        return Array(list.prefix(limit))
    }

    /// Position de reprise (secondes) pour une vidéo, si elle est significative.
    public func resumePosition(itemID: String, videoID: String) -> TimeInterval? {
        guard let item = items[itemID], item.state.videoID == videoID else { return nil }
        let offset = item.state.timeOffset
        guard offset > 5_000 else { return nil }
        if item.state.duration > 0, Double(offset) > Double(item.state.duration) * Self.creditsThreshold { return nil }
        return TimeInterval(offset) / 1000
    }

    public func watchedVideoIDs(itemID: String, videos: [MetaVideo]) -> Set<String> {
        guard let item = items[itemID], let raw = item.state.watched, !videos.isEmpty else { return [] }
        let ids = WatchedBitField.orderedVideoIDs(videos)
        return (try? WatchedBitField(serialized: raw, videoIDs: ids))?.watchedIDs ?? []
    }

    public func lastStreamFingerprint(videoID: String) -> String? { lastStreams[videoID] }

    // MARK: Modifications

    public func addToLibrary(_ meta: LibraryMetaRef, now: Date = Date()) {
        var item = items[meta.id] ?? LibraryItem(id: meta.id, type: meta.type, name: meta.name, ctime: now, mtime: now)
        apply(meta, to: &item)
        item.removed = false
        item.temp = false
        if item.ctime == nil { item.ctime = now }
        commit(item, now: now)
    }

    public func removeFromLibrary(_ id: String, now: Date = Date()) {
        guard var item = items[id] else { return }
        item.removed = true
        // Conserve l'élément en historique s'il a une progression.
        item.temp = item.state.timeOffset > 0
        commit(item, now: now)
    }

    /// Retire de « Continuer à regarder » sans toucher au reste.
    public func dismissFromContinueWatching(_ id: String, now: Date = Date()) {
        guard var item = items[id] else { return }
        item.state.timeOffset = 0
        commit(item, now: now)
    }

    /// Point de progression pendant la lecture (logique alignée sur stremio-core).
    /// - Parameters:
    ///   - position: position actuelle (s).
    ///   - duration: durée totale (s), 0 si inconnue.
    ///   - played: temps réellement regardé depuis le dernier point (s), hors sauts.
    public func recordProgress(_ meta: LibraryMetaRef, videoID: String, position: TimeInterval, duration: TimeInterval,
                               played: TimeInterval, videos: [MetaVideo] = [], now: Date = Date()) {
        var item = items[meta.id] ?? LibraryItem(id: meta.id, type: meta.type, name: meta.name, ctime: now, mtime: now)
        apply(meta, to: &item)
        item.state.lastWatched = now
        if item.state.videoID != videoID {
            item.state.overallTimeWatched += item.state.timeWatched
            item.state.timeWatched = 0
            item.state.flaggedWatched = 0
            item.state.videoID = videoID
        }
        let playedMs = Int64(max(0, min(played, 3600)) * 1000)
        item.state.timeWatched += playedMs
        item.state.overallTimeWatched += playedMs
        item.state.timeOffset = Int64(max(0, position) * 1000)
        if duration.isFinite, duration > 0 { item.state.duration = Int64(duration * 1000) }

        if item.state.flaggedWatched == 0, item.state.duration > 0,
           Double(item.state.timeWatched) > Double(item.state.duration) * Self.watchedThreshold {
            item.state.flaggedWatched = 1
            item.state.timesWatched += 1
            setBit(&item, videoID: videoID, watched: true, videos: videos)
        }
        if item.temp && item.state.timesWatched == 0 { item.removed = true }
        if item.removed { item.temp = true }
        commit(item, now: now)
    }

    /// Fin de lecture : si le générique est atteint, passe à l'épisode suivant
    /// (ou retire de « Continuer » pour un film).
    public func finishPlayback(_ meta: LibraryMetaRef, videoID: String, position: TimeInterval, duration: TimeInterval,
                               nextVideoID: String?, ended: Bool, now: Date = Date()) {
        guard var item = items[meta.id], item.state.videoID == videoID else { return }
        let reachedCredits = ended || (duration > 0 && position > duration * Self.creditsThreshold)
        guard reachedCredits else { return }
        item.state.timeOffset = 0
        if let next = nextVideoID {
            advance(&item, to: next)
        }
        commit(item, now: now)
    }

    /// Marque un film/une série entière comme vu(e) ou non vu(e).
    public func markWatched(_ meta: LibraryMetaRef, watched: Bool, now: Date = Date()) {
        var item = items[meta.id] ?? LibraryItem(id: meta.id, type: meta.type, name: meta.name, ctime: now, mtime: now)
        apply(meta, to: &item)
        if watched {
            item.state.timesWatched += 1
            item.state.lastWatched = now
            item.state.timeOffset = 0
        } else {
            item.state.timesWatched = 0
            item.state.flaggedWatched = 0
        }
        commit(item, now: now)
    }

    /// Marque un épisode comme vu/non vu ; avance le pointeur de reprise si besoin.
    public func setEpisodeWatched(_ meta: LibraryMetaRef, videoID: String, watched: Bool, videos: [MetaVideo], now: Date = Date()) {
        var item = items[meta.id] ?? LibraryItem(id: meta.id, type: meta.type, name: meta.name, ctime: now, mtime: now)
        apply(meta, to: &item)
        setBit(&item, videoID: videoID, watched: watched, videos: videos)
        if watched {
            item.state.lastWatched = max(item.state.lastWatched ?? now, now)
            if item.state.videoID == videoID || item.state.videoID == nil {
                let watchedSet = watchedIDs(item, videos: videos)
                if let next = NextEpisode.after(videoID: videoID, in: videos, excluding: watchedSet, now: now) {
                    advance(&item, to: next.id)
                } else {
                    item.state.timeOffset = 0
                }
            }
        }
        if item.temp && item.state.timesWatched == 0 && item.state.watched == nil { item.removed = true }
        if item.removed { item.temp = true }
        commit(item, now: now)
    }

    public func rememberStream(videoID: String, fingerprint: String) {
        lastStreams[videoID] = fingerprint
        lastStreamOrder.removeAll { $0 == videoID }
        lastStreamOrder.append(videoID)
        if lastStreamOrder.count > 300 {
            let overflow = lastStreamOrder.prefix(lastStreamOrder.count - 300)
            for key in overflow { lastStreams.removeValue(forKey: key) }
            lastStreamOrder.removeFirst(overflow.count)
        }
        scheduleSave()
    }

    /// Efface toutes les données locales (déconnexion).
    public func eraseAll() {
        items.removeAll()
        dirty.removeAll()
        lastStreams.removeAll()
        lastStreamOrder.removeAll()
        file.set(nil, forKey: Self.fileKey)
        mirror.set(nil, forKey: Self.mirrorKey)
        mirror.set(nil, forKey: Self.dirtyKey)
        mirror.set(nil, forKey: Self.streamsKey)
        notify()
    }

    // MARK: Synchronisation

    public func dirtyItems() -> [LibraryItem] { dirty.compactMap { items[$0] } }

    public func markClean(_ ids: [String]) {
        for id in ids { dirty.remove(id) }
        scheduleSave()
    }

    public func mtimes() -> [String: Date] { items.mapValues(\.mtime) }

    /// Fusion des éléments distants : le plus récent (`_mtime`) gagne. Un
    /// élément local modifié plus récemment est conservé (et reste à envoyer).
    @discardableResult
    public func merge(remote: [LibraryItem]) -> Int {
        var changed = 0
        for r in remote {
            if let local = items[r.id], local.mtime >= r.mtime {
                if local.mtime > r.mtime { dirty.insert(r.id) }
                continue
            }
            items[r.id] = r
            dirty.remove(r.id)
            changed += 1
        }
        if changed > 0 {
            scheduleSave()
            notify()
        }
        return changed
    }

    // MARK: Observation

    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notify() {
        for c in observers.values { c.yield() }
    }

    // MARK: Persistance

    /// Écrit immédiatement (mise en arrière-plan, fermeture du lecteur).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.saveFromTask()
        }
    }

    private func saveFromTask() {
        saveTask = nil
        persist()
    }

    private func persist() {
        let all = Array(items.values)
        file.encode(all, forKey: Self.fileKey)
        // Copie de secours compacte : éléments récents, sans l'objet brut.
        let recent = all
            .filter { $0.isInLibrary || $0.state.lastWatched != nil }
            .sorted { $0.mtime > $1.mtime }
            .prefix(Self.mirrorLimit)
            .map { item -> LibraryItem in
                var copy = item
                copy.raw = nil
                return copy
            }
        mirror.encode(Array(recent), forKey: Self.mirrorKey)
        mirror.encode(Array(dirty), forKey: Self.dirtyKey)
        mirror.encode(LastStreams(map: lastStreams, order: lastStreamOrder), forKey: Self.streamsKey)
    }

    // MARK: Interne

    private func apply(_ meta: LibraryMetaRef, to item: inout LibraryItem) {
        if !meta.name.isEmpty { item.name = meta.name }
        if let p = meta.poster { item.poster = p }
        item.posterShape = meta.posterShape
        if item.type.isEmpty { item.type = meta.type }
        if let d = meta.defaultVideoID { item.defaultVideoID = d }
    }

    private func advance(_ item: inout LibraryItem, to videoID: String) {
        item.state.videoID = videoID
        item.state.overallTimeWatched += item.state.timeWatched
        item.state.timeWatched = 0
        item.state.flaggedWatched = 0
        // Convention Stremio : 1 ms = « épisode suivant à commencer ».
        item.state.timeOffset = 1
    }

    private func watchedIDs(_ item: LibraryItem, videos: [MetaVideo]) -> Set<String> {
        guard let raw = item.state.watched, !videos.isEmpty else { return [] }
        return (try? WatchedBitField(serialized: raw, videoIDs: WatchedBitField.orderedVideoIDs(videos)))?.watchedIDs ?? []
    }

    private func setBit(_ item: inout LibraryItem, videoID: String, watched: Bool, videos: [MetaVideo]) {
        guard !videos.isEmpty else { return }
        let ids = WatchedBitField.orderedVideoIDs(videos)
        var field = item.state.watched.flatMap { try? WatchedBitField(serialized: $0, videoIDs: ids) } ?? WatchedBitField(videoIDs: ids)
        field.setWatched(videoID, watched)
        if let s = try? field.serialize() { item.state.watched = s }
    }

    private func commit(_ item: LibraryItem, now: Date) {
        var item = item
        item.mtime = now
        items[item.id] = item
        dirty.insert(item.id)
        scheduleSave()
        notify()
    }
}

/// Calcul de l'épisode suivant.
public enum NextEpisode {
    /// Épisode suivant `videoID` dans l'ordre canonique, déjà sorti, en sautant
    /// les épisodes marqués vus. Les spéciaux (saison 0) ne sont jamais proposés
    /// depuis une saison régulière.
    public static func after(videoID: String, in videos: [MetaVideo], excluding watched: Set<String> = [], now: Date = Date()) -> MetaVideo? {
        let ordered = videos.sorted(by: MetaVideo.canonicalOrder)
        guard let index = ordered.firstIndex(where: { $0.id == videoID }) else { return nil }
        let current = ordered[index]
        for candidate in ordered[(index + 1)...] {
            if current.season != 0 && candidate.season == 0 { return nil }
            guard candidate.isReleased(asOf: now) else { return nil }
            if watched.contains(candidate.id) { continue }
            return candidate
        }
        return nil
    }

    /// Épisode à lancer depuis la fiche : reprise en cours, sinon premier non vu.
    public static func resumeTarget(item: LibraryItem?, videos: [MetaVideo], watched: Set<String>, now: Date = Date()) -> MetaVideo? {
        let ordered = videos.sorted(by: MetaVideo.canonicalOrder)
        if let current = item?.state.videoID, let v = ordered.first(where: { $0.id == current }), item?.state.timeOffset ?? 0 > 0 {
            return v
        }
        let regular = ordered.filter { $0.season != 0 && $0.isReleased(asOf: now) }
        return regular.first { !watched.contains($0.id) } ?? regular.first ?? ordered.first
    }
}
