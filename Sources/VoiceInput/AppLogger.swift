import OSLog
import Cocoa

@MainActor
final class AppLogger {
    static let shared = AppLogger()

    private let osLog = Logger(subsystem: "com.voiceinput.app", category: "VoiceInput")
    private var entries: [(date: Date, level: String, message: String)] = []
    private let maxEntries = 500

    private init() {}

    func debug(_ message: String, sensitive: Bool = false) {
        log(level: "DEBUG", message: message, sensitive: sensitive)
    }

    func info(_ message: String, sensitive: Bool = false) {
        log(level: "INFO", message: message, sensitive: sensitive)
    }

    func warning(_ message: String, sensitive: Bool = false) {
        log(level: "WARN", message: message, sensitive: sensitive)
    }

    func error(_ message: String, sensitive: Bool = false) {
        log(level: "ERROR", message: message, sensitive: sensitive)
    }

    /// OSLog marks interpolated strings private by default, which renders
    /// diagnostic values as `<private>` in `log show`. Non-sensitive messages
    /// are emitted with explicit public privacy so they survive in the log;
    /// sensitive ones (e.g. transcribed speech) stay redacted.
    private func log(level: String, message: String, sensitive: Bool) {
        let now = Date()
        entries.append((now, level, message))
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
        if sensitive {
            osLog.log(level: osLevel, "\(message)")
        } else {
            osLog.log(level: osLevel, "\(message, privacy: .public)")
        }
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
