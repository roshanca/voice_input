import Foundation

@MainActor
protocol LLMRefinerDelegate: AnyObject {
    func llmRefinerDidStart(_ refiner: LLMRefiner)
    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String)
    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error)
}

extension LLMRefinerDelegate {
    /// Streamed in-progress text while the model is generating (stream: true).
    func llmRefiner(_ refiner: LLMRefiner, didStreamPartial text: String) {}
}

@MainActor
final class LLMRefiner {
    weak var delegate: LLMRefinerDelegate?
    private var task: Task<Void, Never>?

    private let overrideConfig: LLMConfig?
    /// Explicit key for ad-hoc configs (e.g. testing an unsaved profile);
    /// otherwise the key is resolved from the Keychain by config id.
    private let apiKeyOverride: String?

    private var config: LLMConfig {
        overrideConfig ?? UserDefaults.standard.currentLLMConfig ?? LLMConfig.default
    }

    private var resolvedAPIKey: String {
        apiKeyOverride ?? KeychainHelper.key(for: config.id)
    }

    var isConfigured: Bool {
        !config.baseURL.isEmpty && !config.model.isEmpty &&
        (config.providerType == .ollama || !resolvedAPIKey.isEmpty)
    }

    init(config: LLMConfig? = nil, apiKeyOverride: String? = nil) {
        self.overrideConfig = config
        self.apiKeyOverride = apiKeyOverride
    }

    func refine(text: String) {
        AppLogger.shared.info("LLMRefiner.refine called — provider: \(config.providerType.displayName), model: \(config.model), baseURL: \(config.baseURL)")
        guard isConfigured else {
            AppLogger.shared.warning("LLMRefiner not configured — skipping refinement")
            delegate?.llmRefiner(self, didFinishWith: text)
            return
        }

        delegate?.llmRefinerDidStart(self)

        let urlString = config.baseURL.hasSuffix("/") ? config.baseURL + "chat/completions" : config.baseURL + "/chat/completions"
        guard let url = URL(string: urlString) else {
            AppLogger.shared.error("Invalid URL: \(urlString)")
            delegate?.llmRefiner(self, didFinishWith: text)
            return
        }

        let systemPrompt = resolvedSystemPrompt()

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.0,
            "stream": true
        ]
        // Reasoning models (e.g. DeepSeek flash/reasoner variants) think before
        // answering — pure latency for a mechanical correction task. Disable
        // thinking where the provider supports it; unknown keys are ignored by
        // OpenAI-compatible servers.
        body["chat_template_kwargs"] = ["enable_thinking": false]
        body["thinking"] = ["type": "disabled"]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = resolvedAPIKey
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        AppLogger.shared.info("Sending streaming LLM request to \(urlString)")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    AppLogger.shared.info("LLM HTTP status: \(httpResponse.statusCode)")
                    guard (200...299).contains(httpResponse.statusCode) else {
                        var bodyString = ""
                        for try await line in bytes.lines {
                            bodyString += line
                            if bodyString.count > 2000 { break }
                        }
                        AppLogger.shared.error("LLM request failed — status: \(httpResponse.statusCode), body: \(bodyString)", sensitive: true)
                        let message: String
                        switch httpResponse.statusCode {
                        case 401:
                            message = "Unauthorized: check your API key."
                        case 429:
                            message = "Rate limited: too many requests."
                        default:
                            message = "LLM request failed with status \(httpResponse.statusCode)."
                        }
                        self.delegate?.llmRefiner(self, didFailWith: NSError(domain: "LLMRefiner", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
                        return
                    }
                }

                // Parse the SSE stream: "data: {json}" lines, terminated by
                // "data: [DONE]". Accumulate delta content and mirror it to the
                // floating panel so generation is visible in real time.
                var accumulated = ""
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let payloadData = payload.data(using: .utf8),
                          let json = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let first = choices.first,
                          let delta = first["delta"] as? [String: Any],
                          let content = delta["content"] as? String else { continue }
                    accumulated += content
                    self.delegate?.llmRefiner(self, didStreamPartial: accumulated)
                }

                let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    AppLogger.shared.warning("LLM stream completed with empty content — using raw text")
                    self.delegate?.llmRefiner(self, didFinishWith: text)
                    return
                }
                AppLogger.shared.info("LLM response parsed successfully")
                self.delegate?.llmRefiner(self, didFinishWith: trimmed)
            } catch is CancellationError {
                AppLogger.shared.info("LLM request canceled")
            } catch {
                AppLogger.shared.error("LLM request error: \(error.localizedDescription)")
                self.delegate?.llmRefiner(self, didFailWith: error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - System Prompt

    static let defaultSystemPrompt = """
You correct obvious speech recognition errors only. The input already contains punctuation added by the speech recognizer; preserve it unless it is clearly wrong.

Rules:
1. Fix only clear transcription errors:
   - Chinese homophone mistakes (e.g., 配森→Python, 拍森→Python, 杰森→JSON).
   - English technical terms wrongly transcribed into Chinese.
   - Obvious typos that can be confidently corrected from context.

2. Remove only filler words that carry no meaning, such as "um", "ah", "like", "那个", "然后" when overused. Do not remove words that affect meaning.

3. Never do the following:
   - Summarize, condense, or rewrite correct content.
   - Change wording that is already natural and correct.
   - Strip or alter existing punctuation unless it is clearly misplaced.
   - Add explanations, clarifications, labels, or any extra text.
   - Censor or soften vulgar content; keep the original expression.

4. If the user explicitly asks to polish or rephrase within the transcript (e.g., "帮我润色一下"), follow that instruction for the relevant part only.

5. For self-corrections like "aaa correct bbb" or "aaa (bbb)", output "bbb".

Output only the corrected text, with no introduction, labels, or markdown.
"""

    private func resolvedSystemPrompt() -> String {
        let custom = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.isEmpty ? LLMRefiner.defaultSystemPrompt : custom
        return base + DictionaryStore.shared.promptFragment()
    }
}
