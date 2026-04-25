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
    var apiKey: String
    var model: String

    static var `default`: LLMConfig {
        LLMConfig(
            id: UUID(),
            name: "Default",
            providerType: .openAICompatible,
            baseURL: "",
            apiKey: "",
            model: ProviderType.openAICompatible.defaultModel
        )
    }
}
