import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Recognition language", selection: $store.language) {
                    ForEach(RecognizedLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Label("Language", systemImage: "globe")
            }

            Section {
                Toggle(isOn: $store.copyToClipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy result to clipboard")
                        Text("Keep the dictated text in the clipboard after pasting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $store.autoSend) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-send (press Return)")
                        Text("Press Return after inserting text — sends the message in chat apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Dictation", systemImage: "text.cursor")
            }

            Section {
                Picker("Microphone", selection: $store.selectedMicUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(store.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Toggle(isOn: $store.interactionSounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Interaction sounds")
                        Text("Play sounds for start / stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Audio", systemImage: "mic")
            }

            Section {
                Toggle(isOn: $store.llmEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable LLM refinement")
                        Text("Fix recognition errors with an LLM before inserting text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !store.llmConfigs.isEmpty {
                    Picker("Active profile", selection: $store.selectedConfigID) {
                        ForEach(store.llmConfigs) { config in
                            Text(config.name).tag(Optional(config.id))
                        }
                    }
                }
                NavigationLink("Manage Profiles…") {
                    LLMProfilesView()
                }
            } header: {
                Label("LLM Refinement", systemImage: "sparkles")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictate")
                        Text("Hold to dictate, release to insert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Dictate hotkey", selection: $store.hotkey) {
                        ForEach(Hotkey.allCases, id: \.self) { hotkey in
                            Text(hotkey.displayName).tag(hotkey)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            } header: {
                Label("Keyboard Shortcut", systemImage: "keyboard")
            } footer: {
                Text("F-keys may conflict with media functions depending on your keyboard settings.")
            }

            Section {
                PermissionsSection()
            } header: {
                Label("Permissions", systemImage: "checkmark.shield")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Start VoiceInput automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Logs")
                    Spacer()
                    Button("View Logs…") {
                        (NSApp.delegate as? AppDelegate)?.openLogsWindow()
                    }
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("General", systemImage: "gearshape")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
