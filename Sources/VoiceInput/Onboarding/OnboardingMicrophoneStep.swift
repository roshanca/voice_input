import SwiftUI

/// First-run mic pick — the same SettingsStore-backed picker Settings
/// shows, so the choice lands on `selectedMicUID` through the normal
/// write path (#27).
struct OnboardingMicrophoneStep: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the microphone VoiceInput listens on. System Default follows your macOS input setting.")
                .foregroundStyle(.secondary)
            Form {
                Section {
                    Picker("Input device", selection: $store.selectedMicUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(store.inputDevices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("A missing mic usually means Microphone access is still pending — grant it on the previous step, or revisit Settings → Audio later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        // refresh() is what fills `inputDevices` — the main window calls it
        // on appear, so onboarding must too.
        .onAppear { store.refresh() }
    }
}
