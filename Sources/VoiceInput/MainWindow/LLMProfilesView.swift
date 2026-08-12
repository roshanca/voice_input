import SwiftUI

/// Drives a one-shot LLM request for the "Test" button.
@MainActor
final class LLMProfileTester: ObservableObject {
    @Published var status = ""
    @Published var isTesting = false
    @Published var succeeded = false

    private var refiner: LLMRefiner?

    func test(config: LLMConfig, apiKey: String) {
        status = "Testing…"
        isTesting = true
        succeeded = false
        let refiner = LLMRefiner(config: config, apiKeyOverride: apiKey)
        refiner.delegate = self
        self.refiner = refiner
        refiner.refine(text: "hello")
    }
}

extension LLMProfileTester: LLMRefinerDelegate {
    func llmRefinerDidStart(_ refiner: LLMRefiner) {}

    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String) {
        status = "Success — response: \(text)"
        succeeded = true
        isTesting = false
        self.refiner = nil
    }

    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error) {
        status = "Failed: \(error.localizedDescription)"
        succeeded = false
        isTesting = false
        self.refiner = nil
    }
}

/// Profile list + editor for LLM refinement configs, presented as a sheet.
struct LLMProfilesView: View {
    @ObservedObject private var store = SettingsStore.shared
    @StateObject private var tester = LLMProfileTester()
    @Environment(\.dismiss) private var dismiss

    @State private var draft = LLMConfig.default
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var hasSelection = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LLM Profiles")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                profileList
                    .frame(width: 200)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { selectProfile(id: store.selectedConfigID ?? store.llmConfigs.first?.id) }
    }

    // MARK: - List

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding<UUID?>(
                get: { hasSelection ? draft.id : nil },
                set: { selectProfile(id: $0) }
            )) {
                ForEach(store.llmConfigs) { config in
                    HStack {
                        if config.id == store.selectedConfigID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(config.name)
                        Spacer()
                    }
                    .tag(config.id)
                }
            }
            Divider()
            HStack {
                Button(action: addProfile) {
                    Image(systemName: "plus")
                }
                Button(action: deleteProfile) {
                    Image(systemName: "minus")
                }
                .disabled(!hasSelection)
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Picker("Provider", selection: $draft.providerType) {
                    ForEach(ProviderType.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("API Base URL", text: $draft.baseURL, prompt: Text(draft.providerType.defaultBaseURL))
                HStack {
                    if showKey {
                        TextField("API Key", text: $apiKey, prompt: Text(draft.providerType == .ollama ? "(optional)" : "sk-..."))
                    } else {
                        SecureField("API Key", text: $apiKey, prompt: Text(draft.providerType == .ollama ? "(optional)" : "sk-..."))
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                }
                TextField("Model", text: $draft.model, prompt: Text(draft.providerType.defaultModel))
            }

            Section {
                TextEditor(text: $draft.systemPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 140)
                HStack {
                    Text("Leave empty to use the built-in prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        draft.systemPrompt = LLMRefiner.defaultSystemPrompt
                    }
                }
            } header: {
                Text("System Prompt")
            }

            Section {
                HStack {
                    Button("Test", action: testConnection)
                        .disabled(tester.isTesting)
                    Button("Save", action: saveProfile)
                        .keyboardShortcut(.defaultAction)
                    Spacer()
                    if !tester.status.isEmpty {
                        Text(tester.status)
                            .font(.caption)
                            .foregroundStyle(tester.succeeded ? Color.green : (tester.isTesting ? Color.secondary : Color.red))
                            .lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!hasSelection)
    }

    // MARK: - Actions

    private func selectProfile(id: UUID?) {
        guard let id, let config = store.llmConfigs.first(where: { $0.id == id }) else {
            hasSelection = false
            draft = .default
            apiKey = ""
            return
        }
        hasSelection = true
        draft = config
        apiKey = KeychainHelper.key(for: config.id)
        tester.status = ""
    }

    private func addProfile() {
        let config = LLMConfig(
            id: UUID(),
            name: "New Config",
            providerType: .openAICompatible,
            baseURL: "",
            model: ""
        )
        store.saveLLMConfig(config, apiKey: "")
        selectProfile(id: config.id)
    }

    private func deleteProfile() {
        guard hasSelection else { return }
        store.deleteLLMConfig(id: draft.id)
        selectProfile(id: store.llmConfigs.first?.id)
    }

    private func saveProfile() {
        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        if config.name.isEmpty { config.name = "Untitled" }
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespaces)
        config.model = config.model.trimmingCharacters(in: .whitespaces)
        if config.model.isEmpty { config.model = config.providerType.defaultModel }
        store.saveLLMConfig(config, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
        draft = config
        tester.status = "Saved."
        tester.succeeded = true
    }

    private func testConnection() {
        var config = draft
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespaces)
        config.model = config.model.trimmingCharacters(in: .whitespaces)
        tester.test(config: config, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }
}
