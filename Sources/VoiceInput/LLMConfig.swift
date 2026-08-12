import Foundation

enum ProviderType: String, Codable, CaseIterable {
    case openAICompatible = "openai"
    case ollama = "ollama"

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .ollama: return "Ollama (Local)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        case .ollama: return "llama3.1"
        }
    }
}

struct LLMConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var providerType: ProviderType
    var baseURL: String
    /// API keys live in the Keychain (account = id). This field is kept only for
    /// decoding legacy data; it is always encoded as "".
    var apiKey: String
    var model: String
    /// Empty = use the built-in default prompt.
    var systemPrompt: String

    private enum CodingKeys: String, CodingKey {
        case id, name, providerType, baseURL, apiKey, model, systemPrompt
    }

    init(id: UUID, name: String, providerType: ProviderType, baseURL: String, apiKey: String = "", model: String, systemPrompt: String = "") {
        self.id = id
        self.name = name
        self.providerType = providerType
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        providerType = try container.decode(ProviderType.self, forKey: .providerType)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try container.decode(String.self, forKey: .model)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(providerType, forKey: .providerType)
        try container.encode(baseURL, forKey: .baseURL)
        // Never persist the key in UserDefaults — it lives in the Keychain.
        try container.encode("", forKey: .apiKey)
        try container.encode(model, forKey: .model)
        try container.encode(systemPrompt, forKey: .systemPrompt)
    }

    static var `default`: LLMConfig {
        LLMConfig(
            id: UUID(),
            name: "Default",
            providerType: .openAICompatible,
            baseURL: "",
            model: ProviderType.openAICompatible.defaultModel
        )
    }
}
