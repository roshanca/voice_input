import OSLog
import Cocoa

@MainActor
final class AppLogger {
    static let shared = AppLogger()

    private let osLog = Logger(subsystem: "com.voiceinput.app", category: "VoiceInput")
    private var entries: [(date: Date, level: String, message: String)] = []
    private let maxEntries = 500

    private init() {}

    func debug(_ message: String) {
        log(level: "DEBUG", message: message)
    }

    func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    private func log(level: String, message: String) {
        let now = Date()
        entries.append((now, level, message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        switch level {
        case "ERROR": osLog.error("\(message)")
        case "WARN": osLog.warning("\(message)")
        case "DEBUG": osLog.debug("\(message)")
        default: osLog.info("\(message)")
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
