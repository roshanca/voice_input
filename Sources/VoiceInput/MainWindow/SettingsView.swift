import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @State private var showLLMProfiles = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)
            formContent
        }
        .sheet(isPresented: $showLLMProfiles) {
            LLMProfilesView()
        }
    }

    private var formContent: some View {
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
                AutoSendOverridesView()
            } header: {
                Label("Dictation", systemImage: "text.cursor")
            } footer: {
                Text("Per-app rules apply to the app you're dictating into. Apps without a rule follow the global setting above.")
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
                    LLMProfileOverridesView()
                }
                Button("Manage Profiles…") {
                    showLLMProfiles = true
                }
            } header: {
                Label("LLM Refinement", systemImage: "sparkles")
            } footer: {
                Text("Per-app rules pick the profile a session refines or translates with, based on the app you're dictating into. Apps without a rule use the active profile.")
            }

            Section {
                TextField("Target language", text: $store.translateTargetLanguage)
                LabeledContent("Hotkey") {
                    Text(store.translateHotkeyDisplay)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Voice Translation", systemImage: "translate")
            } footer: {
                Text("Hold \(store.translateHotkeyDisplay) and speak — on release the transcript is translated into the target language (or into Chinese when it is already in it). Needs a configured LLM profile; works even when refinement is off.")
            }

            Section {
                SelectionActionRow(
                    title: "Translate selection",
                    caption: "Translate the selected text, replacing it in place.",
                    chord: store.selectionTranslateChordLabel
                )
                SelectionActionRow(
                    title: "Rewrite selection",
                    caption: "Polish the selected text, replacing it in place.",
                    chord: store.selectionRewriteChordLabel
                )
                SelectionActionRow(
                    title: "Add selection to dictionary",
                    caption: "Teach the selected term to the custom dictionary.",
                    chord: store.addToDictionaryChordLabel
                )
            } header: {
                Label("Selection Actions", systemImage: "character.cursor.ibeam")
            } footer: {
                Text("With no text selected, these keys hold-to-dictate instead. Translation uses the target language above.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictate")
                        Text(store.hotkeyBehavior.usageHint)
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
                Picker("Trigger", selection: $store.hotkeyBehavior) {
                    ForEach(HotkeyBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
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
                    Button("Export Diagnostics…") {
                        DiagnosticsExporter.exportViaSavePanel()
                    }
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
    }
}

/// Read-only label + chord row for the selection-action list — the
/// persisted bindings have no editor UI yet (a later issue adds one), so
/// the row only advertises what the chord is.
private struct SelectionActionRow: View {
    let title: String
    let caption: String
    let chord: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(chord)
                .foregroundStyle(.secondary)
        }
    }
}
