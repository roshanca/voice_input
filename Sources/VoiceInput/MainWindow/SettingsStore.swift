import Foundation
import Combine

/// Single write-path from SwiftUI into UserDefaults / managers.
/// AppDelegate reads the scalar toggles from UserDefaults at time of use,
/// so no observation is needed in that direction.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var selectedPage: AppPage = .home

    @Published var language: RecognizedLanguage {
        didSet {
            guard language != oldValue else { return }
            LanguageManager.shared.current = language
        }
    }
    @Published var llmEnabled: Bool {
        didSet { UserDefaults.standard.llmEnabled = llmEnabled }
    }
    @Published var copyToClipboard: Bool {
        didSet { UserDefaults.standard.copyToClipboard = copyToClipboard }
    }
    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.autoSend = autoSend }
    }
    @Published var autoSendOverrides: [String: Bool] {
        didSet { UserDefaults.standard.autoSendOverrides = autoSendOverrides }
    }
    @Published var interactionSounds: Bool {
        didSet { UserDefaults.standard.interactionSounds = interactionSounds }
    }
    @Published var selectedMicUID: String? {
        didSet { UserDefaults.standard.selectedMicUID = selectedMicUID }
    }
    @Published var dictionaryDirectReplacement: Bool {
        didSet { UserDefaults.standard.dictionaryDirectReplacement = dictionaryDirectReplacement }
    }
    /// The first dictation binding's hotkey — the settings UI edits a single
    /// binding today, but persistence already stores a binding list.
    @Published var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            let bindings = [HotkeyBinding(hotkey: hotkey, behavior: .hold)]
            HotkeyManager.persistDictation(bindings)
            HotkeyManager.shared.update(dictation: bindings, rePaste: HotkeyManager.savedRePaste)
        }
    }

    /// Available audio input devices; refreshed when the settings window appears.
    @Published private(set) var inputDevices: [AudioInputDevice] = []

    @Published private(set) var llmConfigs: [LLMConfig]
    @Published var selectedConfigID: UUID? {
        didSet { UserDefaults.standard.selectedConfigID = selectedConfigID }
    }

    private init() {
        let defaults = UserDefaults.standard
        language = LanguageManager.shared.current
        llmEnabled = defaults.llmEnabled
        copyToClipboard = defaults.copyToClipboard
        autoSend = defaults.autoSend
        autoSendOverrides = defaults.autoSendOverrides
        interactionSounds = defaults.interactionSounds
        selectedMicUID = defaults.selectedMicUID
        dictionaryDirectReplacement = defaults.dictionaryDirectReplacement
        hotkey = HotkeyManager.savedDictation.first?.hotkey ?? .fnKey
        llmConfigs = defaults.llmConfigs
        selectedConfigID = defaults.selectedConfigID
    }

    /// Re-read values that may have been changed from the menu bar while the
    /// window was closed. Called when the main window appears.
    func refresh() {
        let defaults = UserDefaults.standard
        language = LanguageManager.shared.current
        llmEnabled = defaults.llmEnabled
        copyToClipboard = defaults.copyToClipboard
        autoSend = defaults.autoSend
        autoSendOverrides = defaults.autoSendOverrides
        interactionSounds = defaults.interactionSounds
        selectedMicUID = defaults.selectedMicUID
        dictionaryDirectReplacement = defaults.dictionaryDirectReplacement
        inputDevices = AudioDeviceManager.inputDevices()
        llmConfigs = defaults.llmConfigs
        if let id = defaults.selectedConfigID, llmConfigs.contains(where: { $0.id == id }) {
            selectedConfigID = id
        } else {
            selectedConfigID = llmConfigs.first?.id
        }
    }

    // MARK: - Per-app auto-send

    /// Writes one app's rule; `.inherit` removes the entry so the app
    /// follows the global toggle again.
    func setAutoSendOverride(_ override: AutoSendRules.Override, for bundleID: String) {
        var overrides = autoSendOverrides
        switch override {
        case .inherit: overrides.removeValue(forKey: bundleID)
        case .on: overrides[bundleID] = true
        case .off: overrides[bundleID] = false
        }
        autoSendOverrides = overrides
    }

    // MARK: - LLM profiles

    func saveLLMConfig(_ config: LLMConfig, apiKey: String) {
        var configs = llmConfigs
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        KeychainHelper.set(key: apiKey, for: config.id)
        persist(configs)
        selectedConfigID = config.id
    }

    func deleteLLMConfig(id: UUID) {
        var configs = llmConfigs
        configs.removeAll { $0.id == id }
        KeychainHelper.delete(account: id)
        persist(configs)
        if selectedConfigID == id {
            selectedConfigID = configs.first?.id
        }
    }

    private func persist(_ configs: [LLMConfig]) {
        UserDefaults.standard.llmConfigs = configs
        llmConfigs = configs
    }
}
