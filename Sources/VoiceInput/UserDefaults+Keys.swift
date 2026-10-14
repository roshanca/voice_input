import Foundation

extension UserDefaults {
    enum Keys {
        static let selectedLanguage = "selectedLanguage"
        static let llmEnabled = "llmEnabled"
        static let llmConfigs = "llmConfigs"
        static let selectedConfigID = "selectedConfigID"
        static let copyToClipboard = "copyToClipboard"
        static let autoSend = "autoSend"
        static let interactionSounds = "interactionSounds"
        static let selectedMicUID = "selectedMicUID"
        static let dictionaryDirectReplacement = "dictionaryDirectReplacement"
        static let dictationHotkeyBindings = "dictationHotkeyBindings"
        // Legacy key: single scalar hotkey, superseded by the binding list
        // above but kept in sync for downgrade compatibility.
        static let hotkeyData = "hotkeyData"
        // Legacy keys for migration
        static let legacyLLMBaseURL = "llmBaseURL"
        static let legacyLLMAPIKey = "llmAPIKey"
        static let legacyLLMModel = "llmModel"
    }

    var selectedLanguage: String {
        get { string(forKey: Keys.selectedLanguage) ?? "zh-CN" }
        set { set(newValue, forKey: Keys.selectedLanguage) }
    }

    var llmEnabled: Bool {
        get { bool(forKey: Keys.llmEnabled) }
        set { set(newValue, forKey: Keys.llmEnabled) }
    }

    var copyToClipboard: Bool {
        get { bool(forKey: Keys.copyToClipboard) }
        set { set(newValue, forKey: Keys.copyToClipboard) }
    }

    var autoSend: Bool {
        get { bool(forKey: Keys.autoSend) }
        set { set(newValue, forKey: Keys.autoSend) }
    }

    var interactionSounds: Bool {
        get { bool(forKey: Keys.interactionSounds) }
        set { set(newValue, forKey: Keys.interactionSounds) }
    }

    var selectedMicUID: String? {
        get { string(forKey: Keys.selectedMicUID) }
        set { set(newValue, forKey: Keys.selectedMicUID) }
    }

    /// Defaults to true — dictionary replacements apply directly to ASR output.
    var dictionaryDirectReplacement: Bool {
        get { object(forKey: Keys.dictionaryDirectReplacement) as? Bool ?? true }
        set { set(newValue, forKey: Keys.dictionaryDirectReplacement) }
    }

    /// Legacy accessor: raw scalar hotkey payload. Superseded by
    /// `dictationHotkeyBindings` and kept in sync with its first binding.
    var hotkeyData: Data? {
        get { data(forKey: Keys.hotkeyData) }
        set { set(newValue, forKey: Keys.hotkeyData) }
    }

    /// Dictation hotkey bindings. Reads migrate the legacy scalar `hotkeyData`
    /// into a one-element `.hold` list; writes keep `hotkeyData` in sync with
    /// the first binding so older builds still see a valid hotkey.
    var dictationHotkeyBindings: [HotkeyBinding] {
        get {
            if let data = data(forKey: Keys.dictationHotkeyBindings),
               let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
               !decoded.isEmpty {
                return decoded
            }
            if let data = hotkeyData,
               let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) {
                let migrated = [HotkeyBinding(hotkey: hotkey, behavior: .hold)]
                self.dictationHotkeyBindings = migrated
                return migrated
            }
            return [HotkeyBinding(hotkey: .fnKey, behavior: .hold)]
        }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: Keys.dictationHotkeyBindings)
            if let first = newValue.first {
                hotkeyData = try? JSONEncoder().encode(first.hotkey)
            }
        }
    }

    var llmConfigs: [LLMConfig] {
        get {
            guard let data = data(forKey: Keys.llmConfigs),
                  let decoded = try? JSONDecoder().decode([LLMConfig].self, from: data) else {
                // Migrate from legacy single config if present
                let legacyURL = string(forKey: Keys.legacyLLMBaseURL) ?? ""
                let legacyKey = string(forKey: Keys.legacyLLMAPIKey) ?? ""
                let legacyModel = string(forKey: Keys.legacyLLMModel) ?? "gpt-4o-mini"
                if !legacyURL.isEmpty || !legacyKey.isEmpty {
                    let migrated = LLMConfig(
                        id: UUID(),
                        name: "Default",
                        providerType: .openAICompatible,
                        baseURL: legacyURL,
                        model: legacyModel
                    )
                    if !legacyKey.isEmpty {
                        KeychainHelper.set(key: legacyKey, for: migrated.id)
                    }
                    self.llmConfigs = [migrated]
                    removeObject(forKey: Keys.legacyLLMBaseURL)
                    removeObject(forKey: Keys.legacyLLMAPIKey)
                    removeObject(forKey: Keys.legacyLLMModel)
                    return [migrated]
                }
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                set(data, forKey: Keys.llmConfigs)
            }
        }
    }

    /// One-shot migration: move any plaintext API keys still embedded in the
    /// stored configs into the Keychain, then re-encode with blanked keys.
    /// Call once at app launch.
    @discardableResult
    func migrateLLMAPIKeysToKeychain() -> Bool {
        let configs = llmConfigs
        var changed = false
        for config in configs where !config.apiKey.isEmpty {
            KeychainHelper.set(key: config.apiKey, for: config.id)
            changed = true
        }
        if changed {
            // Encoding blanks the apiKey field (see LLMConfig.encode(to:)).
            llmConfigs = configs
        }
        return changed
    }

    var selectedConfigID: UUID? {
        get {
            guard let uuidString = string(forKey: Keys.selectedConfigID) else { return nil }
            return UUID(uuidString: uuidString)
        }
        set {
            set(newValue?.uuidString, forKey: Keys.selectedConfigID)
        }
    }

    var currentLLMConfig: LLMConfig? {
        let configs = llmConfigs
        guard let selectedID = selectedConfigID,
              let config = configs.first(where: { $0.id == selectedID }) else {
            return configs.first
        }
        return config
    }
}
