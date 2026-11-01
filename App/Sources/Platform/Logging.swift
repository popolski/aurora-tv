import Foundation
import os
import LanterneCore
import AetherEngine

/// Destination `os.Logger` : visible dans Console.app (Mac relié) et dans les sysdiagnose.
nonisolated final class OSLogSink: LogSink {
    private let logger = os.Logger(subsystem: "io.github.popolski.lanterne", category: "app")

    nonisolated func write(_ entry: LogEntry) {
        let text = "[\(entry.category)] \(entry.message)"
        switch entry.level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }
}

/// Journal fichier dans `Library/Caches/Logs` (purgeable), limité à ~2 Mo
/// avec rotation, écrit sur une file série pour ne jamais bloquer l'appelant.
nonisolated final class FileLogSink: LogSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.popolski.lanterne.filelog", qos: .utility)
    private let url: URL
    private let previous: URL
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private let maxSize: UInt64 = 2 * 1024 * 1024

    nonisolated init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("lanterne.log")
        previous = dir.appendingPathComponent("lanterne.1.log")
    }

    nonisolated func write(_ entry: LogEntry) {
        let line = entry.formatted + "\n"
        queue.async { [self] in append(line) }
    }

    nonisolated private func append(_ line: String) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            size = (try? handle?.seekToEnd()) ?? 0
        }
        guard let data = line.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
        size += UInt64(data.count)
        if size > maxSize { rotate() }
    }

    nonisolated private func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        size = 0
    }

    /// Contenu des journaux (ancien puis courant), pour l'envoi de diagnostic.
    nonisolated func contents() -> String {
        queue.sync {
            try? handle?.synchronize()
            let old = (try? String(contentsOf: previous, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return old + current
        }
    }
}

enum LogSetup {
    nonisolated(unsafe) static var fileSink: FileLogSink?

    static func configure(uiTest: Bool) {
        let store = LogStore.shared
        let env = ProcessInfo.processInfo.environment["LANTERNE_LOG_LEVEL"]?.lowercased()
        store.setMinimumLevel(env == "debug" ? .debug : .info)
        store.addSink(OSLogSink())
        if !uiTest {
            let sink = FileLogSink()
            store.addSink(sink)
            fileSink = sink
        }
        // Journaux du moteur de lecture, expurgés par LogStore (le moteur
        // expurge déjà ses identifiants, double sécurité).
        let engineLog = LogChannel("aether")
        EngineLog.handler = { @Sendable line in engineLog.info(line) }
    }
}
