import SwiftUI
import Combine
import AVFoundation
import Speech
@preconcurrency import ApplicationServices

/// Microphone / Speech Recognition / Accessibility status rows with
/// request + System Settings deep links. Refreshes while visible.
struct PermissionsSection: View {
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var accessibilityGranted = false

    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            permissionRow(
                title: "Accessibility",
                description: "Required for the global dictation hotkey and text insertion.",
                granted: accessibilityGranted,
                actionTitle: "Open Settings"
            ) {
                openSystemSettings("Privacy_Accessibility")
            }
            permissionRow(
                title: "Microphone",
                description: "VoiceInput can record your voice.",
                granted: micStatus == .granted,
                actionTitle: micStatus == .denied ? "Open Settings" : "Request"
            ) {
                if micStatus == .denied {
                    openSystemSettings("Privacy_Microphone")
                } else {
                    AVAudioApplication.requestRecordPermission { _ in
                        DispatchQueue.main.async { refresh() }
                    }
                }
            }
            permissionRow(
                title: "Speech Recognition",
                description: "On-device and server-based speech transcription.",
                granted: speechStatus == .authorized,
                actionTitle: speechStatus == .denied ? "Open Settings" : "Request"
            ) {
                if speechStatus == .denied || speechStatus == .restricted {
                    openSystemSettings("Privacy_SpeechRecognition")
                } else {
                    SFSpeechRecognizer.requestAuthorization { _ in
                        DispatchQueue.main.async { refresh() }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    @ViewBuilder
    private func permissionRow(title: String, description: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button(actionTitle, action: action)
            }
        }
    }

    private func refresh() {
        micStatus = AVAudioApplication.shared.recordPermission
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        accessibilityGranted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
    }

    private func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
