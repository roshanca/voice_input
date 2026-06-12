import Foundation

@MainActor
protocol LLMRefinerDelegate: AnyObject {
    func llmRefinerDidStart(_ refiner: LLMRefiner)
    func llmRefiner(_ refiner: LLMRefiner, didFinishWith text: String)
    func llmRefiner(_ refiner: LLMRefiner, didFailWith error: Error)
}

@MainActor
final class LLMRefiner {
    weak var delegate: LLMRefinerDelegate?
    private var task: URLSessionDataTask?

    private let overrideConfig: LLMConfig?

    private var config: LLMConfig {
        overrideConfig ?? UserDefaults.standard.currentLLMConfig ?? LLMConfig.default
    }

    var isConfigured: Bool {
        !config.baseURL.isEmpty && !config.model.isEmpty &&
        (config.providerType == .ollama || !config.apiKey.isEmpty)
    }

    init(config: LLMConfig? = nil) {
        self.overrideConfig = config
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

        let systemPrompt = """
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

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.0
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        AppLogger.shared.info("Sending LLM request to \(urlString)")
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppLogger.shared.error("LLM request error: \(error.localizedDescription)")
                    self.delegate?.llmRefiner(self, didFailWith: error)
                    return
                }
                guard let data else {
                    AppLogger.shared.error("LLM request returned no data")
                    self.delegate?.llmRefiner(self, didFinishWith: text)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    AppLogger.shared.info("LLM HTTP status: \(httpResponse.statusCode)")
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        AppLogger.shared.error("LLM request failed — status: \(httpResponse.statusCode), body: \(bodyString)")
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
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let message = first["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        AppLogger.shared.info("LLM response parsed successfully")
                        self.delegate?.llmRefiner(self, didFinishWith: trimmed)
                    } else {
                        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        AppLogger.shared.warning("LLM response parse failed — body: \(bodyString)")
                        self.delegate?.llmRefiner(self, didFinishWith: text)
                    }
                } catch {
                    AppLogger.shared.error("LLM JSON parse error: \(error.localizedDescription)")
                    self.delegate?.llmRefiner(self, didFinishWith: text)
                }
            }
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
