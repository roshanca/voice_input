import Foundation

/// Paged steps of the first-run onboarding flow (#27). Declaration order is
/// display order; permissions precede the hotkey practice because the event
/// tap can't fire without Accessibility, and the LLM pointer stays an
/// optional pointer at Settings near the end rather than a rebuilt editor.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case microphone
    case hotkey
    case llm
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to VoiceInput"
        case .permissions: return "Permissions"
        case .microphone: return "Choose a Microphone"
        case .hotkey: return "Your Dictation Hotkey"
        case .llm: return "Optional: LLM Polish"
        case .done: return "You're All Set"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "mic.circle"
        case .permissions: return "checkmark.shield"
        case .microphone: return "mic"
        case .hotkey: return "keyboard"
        case .llm: return "sparkles"
        case .done: return "checkmark.circle"
        }
    }

    var isFirst: Bool { self == Self.allCases.first }
    var isLast: Bool { self == Self.allCases.last }

    /// Raw values follow declaration order, so ±1 walks the flow — and a
    /// step inserted in the middle renumbers its neighbors automatically.
    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}
