import Foundation

enum RecognizedLanguage: String, CaseIterable {
    case english = "en-US"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

@MainActor
final class LanguageManager {
    static let shared = LanguageManager()

    var current: RecognizedLanguage {
        get {
            RecognizedLanguage(rawValue: UserDefaults.standard.selectedLanguage) ?? .simplifiedChinese
        }
        set {
            UserDefaults.standard.selectedLanguage = newValue.rawValue
            NotificationCenter.default.post(name: .languageDidChange, object: newValue)
        }
    }
}

extension Notification.Name {
    static let languageDidChange = Notification.Name("languageDidChange")
}
