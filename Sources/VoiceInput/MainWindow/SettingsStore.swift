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
    /// Per-app LLM profile routes: bundle identifier → profile UUID string.
    /// An app with no entry refines on the globally selected profile.
    @Published var perAppLLMProfileOverrides: [String: String] {
        didSet { UserDefaults.standard.perAppLLMProfileOverrides = perAppLLMProfileOverrides }
    }
    @Published var interactionSounds: Bool {
        didSet { UserDefaults.standard.interactionSounds = interactionSounds }
    }
    @Published var historyAudioEnabled: Bool {
        didSet { UserDefaults.standard.historyAudioEnabled = historyAudioEnabled }
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
            persistDictationBinding()
        }
    }
    /// The first dictation binding's behavior (hold / tap / doubleTap).
    @Published var hotkeyBehavior: HotkeyBehavior {
        didSet {
            guard hotkeyBehavior != oldValue else { return }
            persistDictationBinding()
        }
    }

    private func persistDictationBinding() {
        let bindings = [HotkeyBinding(hotkey: hotkey, behavior: hotkeyBehavior)]
        HotkeyManager.persistDictation(bindings)
        HotkeyManager.shared.update(
            dictation: bindings,
            rePaste: HotkeyManager.savedRePaste,
            translate: HotkeyManager.savedTranslate,
            rewrite: HotkeyManager.savedRewrite,
            selectionTranslate: HotkeyManager.savedSelectionTranslate,
            selectionRewrite: HotkeyManager.savedSelectionRewrite,
            addToDictionary: HotkeyManager.savedAddToDictionary
        )
    }

    /// Language the translate hotkey translates into — free-form, read
    /// verbatim into the LLM prompt; the accessor normalizes blank to English.
    /// Shared by voice translate and translate-selection.
    @Published var translateTargetLanguage: String {
        didSet {
            guard translateTargetLanguage != oldValue else { return }
            UserDefaults.standard.translateTargetLanguage = translateTargetLanguage
        }
    }
    /// Read-only display of the first translate binding — the list is
    /// persisted and routed, but not editable from settings yet.
    var translateHotkeyDisplay: String {
        HotkeyManager.savedTranslate.first?.hotkey.displayName ?? "Unbound"
    }

    /// Read-only display of the first rewrite binding — same persisted-but-
    /// not-editable status as the translate chord.
    var rewriteHotkeyDisplay: String {
        HotkeyManager.savedRewrite.first?.hotkey.displayName ?? "Unbound"
    }

    /// Display names of the persisted selection-action chords. Read-only —
    /// the settings UI has no chord editor yet, and nothing else writes
    /// these keys, so there's nothing to publish.
    var selectionTranslateChordLabel: String {
        HotkeyManager.savedSelectionTranslate.first?.hotkey.displayName ?? "—"
    }

    var selectionRewriteChordLabel: String {
        HotkeyManager.savedSelectionRewrite.first?.hotkey.displayName ?? "—"
    }

    var addToDictionaryChordLabel: String {
        HotkeyManager.savedAddToDictionary.first?.hotkey.displayName ?? "—"
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
        perAppLLMProfileOverrides = defaults.perAppLLMProfileOverrides
        interactionSounds = defaults.interactionSounds
        historyAudioEnabled = defaults.historyAudioEnabled
        selectedMicUID = defaults.selectedMicUID
        dictionaryDirectReplacement = defaults.dictionaryDirectReplacement
        translateTargetLanguage = defaults.translateTargetLanguage
        hotkey = HotkeyManager.savedDictation.first?.hotkey ?? .fnKey
        hotkeyBehavior = HotkeyManager.savedDictation.first?.behavior ?? .hold
        llmConfigs = defaults.llmConfigs
        selectedConfigID = defaults.selectedConfigID
        translateTargetLanguage = defaults.translateTargetLanguage
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
        perAppLLMProfileOverrides = defaults.perAppLLMProfileOverrides
        interactionSounds = defaults.interactionSounds
        historyAudioEnabled = defaults.historyAudioEnabled
        selectedMicUID = defaults.selectedMicUID
        dictionaryDirectReplacement = defaults.dictionaryDirectReplacement
        translateTargetLanguage = defaults.translateTargetLanguage
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

    // MARK: - Per-app LLM profiles

    /// Writes one app's profile route; nil removes the entry so the app
    /// follows the global active profile again.
    func setLLMProfileOverride(_ configID: UUID?, for bundleID: String) {
        var overrides = perAppLLMProfileOverrides
        if let configID {
            overrides[bundleID] = configID.uuidString
        } else {
            overrides.removeValue(forKey: bundleID)
        }
        perAppLLMProfileOverrides = overrides
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
        // Prune per-app routes pointing at the deleted profile. Resolve would
        // fall back for dangling ids anyway, but dropping them keeps an app's
        // settings row from advertising a profile that no longer exists.
        var overrides = perAppLLMProfileOverrides
        for (bundleID, raw) in overrides where raw == id.uuidString {
            overrides.removeValue(forKey: bundleID)
        }
        if overrides != perAppLLMProfileOverrides {
            perAppLLMProfileOverrides = overrides
        }
    }

    private func persist(_ configs: [LLMConfig]) {
        UserDefaults.standard.llmConfigs = configs
        llmConfigs = configs
    }
}
