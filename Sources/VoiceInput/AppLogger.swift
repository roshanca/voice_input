import OSLog
import Cocoa

@MainActor
final class AppLogger {
    static let shared = AppLogger()

    private let osLog = Logger(subsystem: "com.voiceinput.app", category: "VoiceInput")
    private var entries: [(date: Date, level: String, message: String)] = []
    private let maxEntries = 500

    private init() {}

    func debug(_ message: String, sensitive: Bool = false, metadata: [String: Any] = [:]) {
        log(level: "DEBUG", message: message, sensitive: sensitive, metadata: metadata)
    }

    func info(_ message: String, sensitive: Bool = false, metadata: [String: Any] = [:]) {
        log(level: "INFO", message: message, sensitive: sensitive, metadata: metadata)
    }

    func warning(_ message: String, sensitive: Bool = false, metadata: [String: Any] = [:]) {
        log(level: "WARN", message: message, sensitive: sensitive, metadata: metadata)
    }

    func error(_ message: String, sensitive: Bool = false, metadata: [String: Any] = [:]) {
        log(level: "ERROR", message: message, sensitive: sensitive, metadata: metadata)
    }

    /// Every message is redacted before it is stored or emitted: `sensitive`
    /// messages (e.g. transcribed speech) collapse to `<redacted>`, free text
    /// is scrubbed for embedded secrets, and metadata is rendered with
    /// sensitive keys and values masked. Nothing downstream — the ring
    /// buffer, the logs window, OSLog, or a diagnostics export — can surface
    /// the original content.
    private func log(level: String, message: String, sensitive: Bool, metadata: [String: Any]) {
        var line = sensitive ? LogRedactor.placeholder : LogRedactor.redactText(message)
        if !metadata.isEmpty {
            line += " \(LogRedactor.renderMetadata(metadata))"
        }

        let now = Date()
        entries.append((now, level, line))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let osLevel: OSLogType
        switch level {
        case "ERROR": osLevel = .error
        case "WARN": osLevel = .default
        case "DEBUG": osLevel = .debug
        default: osLevel = .info
        }
        osLog.log(level: osLevel, "\(line, privacy: .public)")
    }

    func formattedLogs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "[\(formatter.string(from: $0.date))] [\($0.level)] \($0.message)" }.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }
}
