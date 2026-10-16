import SwiftUI

/// Points at the real profile editor instead of rebuilding it (#27): the
/// step explains what an LLM profile unlocks and deep-links into Settings.
struct OnboardingLLMStep: View {
    /// Finishes the flow and opens the main window on the Settings page.
    var onOpenSettings: () -> Void

    /// Read on appear — a user who configures a profile mid-flow via the
    /// settings window gets an honest status on return.
    @State private var configured = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VoiceInput needs no account. Add an LLM profile — any OpenAI-compatible endpoint or local Ollama — to unlock:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                featureRow("text.badge.checkmark", "Refinement", "cleans up recognition slips before the text lands.")
                featureRow("translate", "Voice translation", "hold the translate hotkey to speak one language, insert another.")
                featureRow("wand.and.stars", "Voice rewrite", "speak an instruction, get the generated answer inserted.")
            }

            Spacer()

            HStack {
                if configured {
                    Label("A profile is already configured.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Open Settings…", action: onOpenSettings)
            }

            Text("Or skip it — Settings → LLM Refinement is always there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            configured = LLMRefiner.isConfigured(UserDefaults.standard.currentLLMConfig)
        }
    }

    private func featureRow(_ symbol: String, _ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text("\(name) — \(detail)")
                .foregroundStyle(.primary)
        }
    }
}
