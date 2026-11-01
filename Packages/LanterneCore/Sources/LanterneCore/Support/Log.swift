import Foundation
import Synchronization

/// Niveau de gravité d'une entrée de journal.
public enum LogLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case debug = 0, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

/// Une ligne de journal. Le message est **déjà expurgé** au moment de sa création.
public struct LogEntry: Sendable, Codable, Identifiable, Hashable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public var formatted: String {
        "\(LogEntry.formatter.string(from: date)) [\(level.label)] [\(category)] \(message)"
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Destination supplémentaire des journaux (fichier, os_log…). Appelée depuis
/// n'importe quel thread : l'implémentation doit être thread-safe et non bloquante.
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// Journal applicatif : tampon circulaire en mémoire (consultable depuis
/// Réglages › Diagnostics) + destinations optionnelles.
///
/// Toute chaîne passe par `Redactor.redact` avant stockage : aucun jeton,
/// mot de passe ou URL d'addon configurée n'est conservé en clair.
public final class LogStore: Sendable {
    public static let shared = LogStore(capacity: 2_000)

    private struct State {
        var entries: [LogEntry] = []
        var nextID: UInt64 = 0
        var sinks: [any LogSink] = []
        var minimumLevel: LogLevel = .debug
    }

    private let state: Mutex<State>
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(capacity, 10)
        self.state = Mutex(State())
    }

    public func addSink(_ sink: any LogSink) {
        state.withLock { $0.sinks.append(sink) }
    }

    public func setMinimumLevel(_ level: LogLevel) {
        state.withLock { $0.minimumLevel = level }
    }

    public func log(_ level: LogLevel, _ category: String, _ message: @autoclosure () -> String) {
        let minimum = state.withLock { $0.minimumLevel }
        guard level >= minimum else { return }
        let clean = Redactor.redact(message())
        let (entry, sinks): (LogEntry, [any LogSink]) = state.withLock { s in
            let e = LogEntry(id: s.nextID, date: Date(), level: level, category: category, message: clean)
            s.nextID &+= 1
            s.entries.append(e)
            if s.entries.count > capacity {
                s.entries.removeFirst(s.entries.count - capacity)
            }
            return (e, s.sinks)
        }
        for sink in sinks { sink.write(entry) }
    }

    public func snapshot(minimumLevel: LogLevel = .debug) -> [LogEntry] {
        state.withLock { $0.entries.filter { $0.level >= minimumLevel } }
    }

    public func clear() {
        state.withLock { $0.entries.removeAll() }
    }

    /// Export texte complet (pour partage/diagnostic).
    public func exportText() -> String {
        snapshot().map(\.formatted).joined(separator: "\n")
    }
}

/// Raccourci de journalisation par catégorie.
public struct LogChannel: Sendable {
    public let category: String
    private let store: LogStore

    public init(_ category: String, store: LogStore = .shared) {
        self.category = category
        self.store = store
    }

    public func debug(_ message: @autoclosure () -> String) { store.log(.debug, category, message()) }
    public func info(_ message: @autoclosure () -> String) { store.log(.info, category, message()) }
    public func warning(_ message: @autoclosure () -> String) { store.log(.warning, category, message()) }
    public func error(_ message: @autoclosure () -> String) { store.log(.error, category, message()) }
}
