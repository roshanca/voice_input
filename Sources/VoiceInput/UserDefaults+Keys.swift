import Foundation

extension UserDefaults {
    enum Keys {
        static let selectedLanguage = "selectedLanguage"
        static let llmEnabled = "llmEnabled"
        static let llmConfigs = "llmConfigs"
        static let selectedConfigID = "selectedConfigID"
        static let copyToClipboard = "copyToClipboard"
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
                        apiKey: legacyKey,
                        model: legacyModel
                    )
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
