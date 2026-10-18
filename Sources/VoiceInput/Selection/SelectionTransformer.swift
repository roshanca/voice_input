import Foundation

/// Failure surface for selection transforms — deliberately small; every
/// case is non-fatal and reaches the caller through the completion.
enum SelectionTransformError: LocalizedError {
    /// No usable LLM profile (missing baseURL/model, or API key for a
    /// provider that needs one).
    case notConfigured
    /// The provider answered with an empty or whitespace-only completion —
    /// that must never be injected over the user's selection.
    case emptyResponse
    /// Non-2xx HTTP status from the provider.
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No LLM profile configured."
        case .emptyResponse: return "The model returned an empty response."
        case .httpStatus(let code):
            switch code {
            case 401: return "Unauthorized: check your API key."
            case 429: return "Rate limited: too many requests."
            default: return "LLM request failed with status \(code)."
            }
        }
    }
}

/// One-shot LLM transforms behind the selection hotkeys (translate,
/// rewrite). Deliberately separate from `LLMRefiner`: the refiner owns the
/// dictation session's delegate/requestID contract and writes history
/// through its caller — a transform sharing it would cancel a refinement in
/// flight and could leak into session bookkeeping. Profile + Keychain
/// resolution and the OpenAI-compatible streaming request shape mirror the
/// refiner's; there's no delegate protocol — a transform is a single
/// request with partials and one terminal result.
@MainActor
final class SelectionTransformer {
    /// Which selection transform to run — drives the prompt and the panel
    /// copy. The dictionary action isn't here: it needs no model call.
    enum Kind {
        case translate
        case rewrite

        /// Panel text while the request is in flight.
        var progressLabel: String {
            switch self {
            case .translate: return "Translating…"
            case .rewrite: return "Rewriting…"
            }
        }

        /// Flash-message prefix when the request fails.
        var failureLabel: String {
            switch self {
            case .translate: return "Translation failed"
            case .rewrite: return "Rewrite failed"
            }
        }
    }

    private var task: Task<Void, Never>?
    /// Identity of the request allowed to invoke callbacks. A new `transform`
    /// restamps it before superseding the old task and `cancel()` clears it —
    /// either way a stale task's late events (a partial, a failure, even a
    /// URLError.cancelled surfacing as a generic error) find a mismatched or
    /// absent identity and drop before reaching the caller.
    private var currentRequestID: UUID?

    private let overrideConfig: LLMConfig?
    /// Explicit key for ad-hoc configs (e.g. testing an unsaved profile);
    /// otherwise the key is resolved from the Keychain by config id.
    private let apiKeyOverride: String?
    /// Streaming request transport — injectable so tests can drive scripted
    /// cancellation races without touching the network.
    private let session: URLSession

    init(config: LLMConfig? = nil, apiKeyOverride: String? = nil, session: URLSession = .shared) {
        self.overrideConfig = config
        self.apiKeyOverride = apiKeyOverride
        self.session = session
    }

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

    /// Streaming transform: `onPartial` reports accumulated text as it
    /// arrives; `completion` fires exactly once with the trimmed result or
    /// the failure — except after `cancel()`, which fires neither (the
    /// caller treats cancellation as the end of the press, same contract as
    /// the refiner's dropped callbacks). `requestID` binds every callback
    /// of this request to the caller's current press — callbacks for a
    /// superseded or cancelled id are dropped.
    ///
    /// A new call supersedes a request still in flight: the old task is
    /// cancelled so its late result can't inject text after the user has
    /// already re-pressed with a different selection.
    func transform(kind: Kind, text: String, requestID: UUID,
                   onPartial: @escaping (String) -> Void,
                   completion: @escaping (Result<String, Error>) -> Void) {
        // Restamp identity BEFORE cancelling the in-flight task: the old
        // task can still run callbacks while it unwinds, and they must
        // already read as stale.
        currentRequestID = requestID
        task?.cancel()
        task = nil
        guard isConfigured else {
            AppLogger.shared.warning("Selection transform skipped — no LLM profile configured")
            completion(.failure(SelectionTransformError.notConfigured))
            return
        }

        let baseURL = config.baseURL
        let urlString = baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions"
        guard let url = URL(string: urlString) else {
            AppLogger.shared.error("Invalid LLM base URL: \(LogRedactor.sanitizedURL(urlString))")
            completion(.failure(SelectionTransformError.notConfigured))
            return
        }

        let systemPrompt: String
        switch kind {
        case .translate:
            systemPrompt = SelectionPrompts.translate(targetLanguage: UserDefaults.standard.translateTargetLanguage)
        case .rewrite:
            systemPrompt = SelectionPrompts.rewrite
        }
        // Tag-wrap the selection so instructions inside it read as inert
        // text — the same reason transcripts are wrapped for the refiner.
        let userContent = "<text>\n\(text)\n</text>"

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.0,
            "stream": true
        ]
        // Reasoning effort is pure latency for a mechanical transform —
        // same suppression the refiner sends; unknown keys are ignored.
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

        AppLogger.shared.info("Selection transform started (\(kind)) — streaming request to \(LogRedactor.sanitizedURL(urlString))")
        let requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Same resource ceilings as the refiner's stream (#34): a
                // wall-clock race bounds connect + headers, the parser
                // enforces line/event/output caps and the deadline while
                // the body streams. The injected session stays the transport
                // so scripted cancellation tests still drive this path.
                let session = self.session
                let deadline = Date().addingTimeInterval(ResourceLimits.llmTotalRequestDuration)
                let (bytes, response) = try await TotalRequestTimeout.run(seconds: ResourceLimits.llmTotalRequestDuration) { [request, session] in
                    try await session.bytes(for: request)
                }

                if let httpResponse = response as? HTTPURLResponse {
                    AppLogger.shared.info("Selection transform HTTP status: \(httpResponse.statusCode)")
                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Bounded read — an error body is a page of text at
                        // most; unterminated lines must not buffer whole.
                        let bodyData = try await BoundedBodyReader.prefix(from: bytes, maxBytes: ResourceLimits.errorBodyMaxBytes)
                        let bodyString = String(String(decoding: bodyData, as: UTF8.self).prefix(2000))
                        // Same shape as the refiner's: status stays
                        // visible, the untrusted body is withheld.
                        AppLogger.shared.error("Selection transform failed", metadata: [
                            "statusCode": httpResponse.statusCode,
                            "body": SensitiveLogValue(bodyString)
                        ])
                        guard self.isLive(requestID) else { return }
                        completion(.failure(SelectionTransformError.httpStatus(httpResponse.statusCode)))
                        return
                    }
                }

                var parser = SSEStreamParser(deadline: deadline)
                var coalescer = PartialUpdateCoalescer()
                var accumulated = ""
                stream: for try await byte in bytes {
                    try Task.checkCancellation()
                    switch try parser.ingest(byte) {
                    case .delta(let content):
                        accumulated += content
                        // Rate-limited — each partial re-renders the full
                        // accumulated string in the panel.
                        if coalescer.shouldEmit() {
                            // A late partial from a superseded/cancelled
                            // request must not reach the caller's panel.
                            guard self.isLive(requestID) else { return }
                            onPartial(accumulated)
                        }
                    case .done:
                        break stream
                    case nil:
                        continue
                    }
                }
                if case .delta(let content) = try parser.finish() {
                    accumulated += content
                }

                let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                // Final delivery gate: identity and cancellation are
                // re-checked so a stale request can never resolve the
                // caller's in-flight state or inject its result.
                guard self.isLive(requestID) else { return }
                guard !trimmed.isEmpty else {
                    AppLogger.shared.warning("Selection transform returned empty content")
                    completion(.failure(SelectionTransformError.emptyResponse))
                    return
                }
                completion(.success(trimmed))
            } catch is CancellationError {
                AppLogger.shared.info("Selection transform canceled")
            } catch {
                // URLSession reports a cancelled load as URLError.cancelled
                // (-999), not CancellationError — either shape is a cancel,
                // which fires no completion. A genuine error reports only
                // while this request is still the live one.
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else {
                    AppLogger.shared.info("Selection transform canceled")
                    return
                }
                guard self.isLive(requestID) else { return }
                AppLogger.shared.error("Selection transform error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
        task = requestTask
        // A cancelled request keeps running until its awaits unwind — track
        // it so shutdown observes the real exit (cancellation ≠ completion).
        TrackedTaskStore.shared.track(requestTask, label: "selection-transform")
    }

    /// A request is live only while it is the identity the caller waits on
    /// and its task hasn't been asked to cancel — the first half catches a
    /// superseded request, the second a cancelled one whose awaits haven't
    /// unwound yet.
    private func isLive(_ requestID: UUID) -> Bool {
        currentRequestID == requestID && !Task.isCancelled
    }

    /// Cancellation is a request, not completion: the tracked task stays
    /// observable in TrackedTaskStore until its body actually exits. Identity
    /// is cleared BEFORE cancel() so a callback fired during the unwind
    /// finds no live request and drops.
    func cancel() {
        currentRequestID = nil
        task?.cancel()
        task = nil
    }
}
