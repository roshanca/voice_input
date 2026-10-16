import SwiftUI

/// Paged first-run flow (#27). The view owns only navigation — permission
/// checks live in the shared PermissionsSection, persistence of
/// `hasCompletedOnboarding` happens in the controller's `onFinish`, and
/// each step's content is its own type.
struct OnboardingView: View {
    @State private var step = OnboardingStep.welcome
    /// Reached via Continue on the last step, Skip anywhere, or the LLM
    /// step's settings deep link — the controller writes the flag + closes.
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // Fixed size: the window is non-resizable, and a stable frame keeps
        // the footer from jumping as pages change height.
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: step.symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 34)
            Text(step.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            // Hidden rather than removed on the first page so the dots stay
            // centered — a disappearing button would shift them sideways.
            Button("Back") {
                if let previous = step.previous {
                    step = previous
                }
            }
            .disabled(step.isFirst)
            .opacity(step.isFirst ? 0 : 1)
            .accessibilityHidden(step.isFirst)

            Spacer()
            dots
            Spacer()

            if step.isLast {
                Button("Start Dictating") { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Skip") { onFinish() }
                Button(step.isFirst ? "Get Started" : "Continue") {
                    if let next = step.next {
                        step = next
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeContent
        case .permissions: OnboardingPermissionsStep()
        case .microphone: OnboardingMicrophoneStep()
        case .hotkey: OnboardingHotkeyStep()
        case .llm: OnboardingLLMStep(onOpenSettings: openSettingsAndFinish)
        case .done: doneContent
        }
    }

    /// "Set up in Settings" finishes the flow first so the flag write and
    /// window close land before the main window claims focus.
    private func openSettingsAndFinish() {
        onFinish()
        MainWindowController.shared.show(page: .settings)
    }

    private var dictationHotkeyName: String {
        HotkeyManager.savedDictation.first?.hotkey.displayName ?? "the dictation hotkey"
    }

    private var welcomeContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("Push-to-talk dictation, anywhere.")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Hold a hotkey, speak, and the text is typed into whatever app you're in — optionally polished, translated, or rewritten by an LLM.\n\nThis one-time setup grants the permissions it needs, picks your microphone, and lets you try the hotkey.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var doneContent: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("Hold \(dictationHotkeyName) to dictate.")
                .font(.title3)
                .fontWeight(.semibold)
            Text("That's everything — the mic icon in the menu bar is home base for Settings, History, and Stats. You can re-run this walkthrough any time from Settings → General.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
