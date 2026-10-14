import Cocoa
import AVFoundation
import Speech
import UniformTypeIdentifiers
@preconcurrency import ApplicationServices

/// Builds a diagnostics bundle — redacted in-memory logs plus the environment
/// details a bug report needs — and saves it via NSSavePanel. Dictated text
/// is never included; the logger only ever stores redacted lines.
@MainActor
enum DiagnosticsExporter {
    static func makeReport() -> String {
        var lines = [
            "VoiceInput Diagnostics",
            "Generated: \(timestamp())",
            "App version: \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Permissions",
            "  Accessibility: \(accessibilityGranted ? "granted" : "not granted")",
            "  Microphone: \(microphoneStatus)",
            "  Speech Recognition: \(speechStatus)",
            "",
            "Logs (sensitive content is redacted; dictated text is never included)",
            String(repeating: "-", count: 72)
        ]
        let logs = AppLogger.shared.formattedLogs()
        lines.append(logs.isEmpty ? "(no log entries)" : logs)
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportViaSavePanel() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeReport().write(to: url, atomically: true, encoding: .utf8)
            AppLogger.shared.info("Diagnostics exported to \(url.path)")
        } catch {
            AppLogger.shared.error("Diagnostics export failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't export diagnostics"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private static var accessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
    }

    private static var microphoneStatus: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    private static var speechStatus: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "VoiceInput-Diagnostics-\(formatter.string(from: Date())).txt"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}
