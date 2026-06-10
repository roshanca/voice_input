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

    private let config: LLMConfig

    var isConfigured: Bool {
        !config.baseURL.isEmpty && !config.model.isEmpty &&
        (config.providerType == .ollama || !config.apiKey.isEmpty)
    }

    init(config: LLMConfig? = nil) {
        self.config = config ?? UserDefaults.standard.currentLLMConfig ?? LLMConfig.default
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
You correct obvious speech recognition errors only. \
Fix: Chinese homophone mistakes, English technical terms wrongly transcribed into Chinese \
(e.g., 配森→Python, 杰森→JSON, 拍森→Python, 杰森→JSON). \
Do NOT rewrite, polish, summarize, or remove any content that appears correct. \
If the input looks correct, return it unchanged.
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
