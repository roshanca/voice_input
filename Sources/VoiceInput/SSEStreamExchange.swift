import Foundation

/// One bounded streaming request to an OpenAI-compatible chat endpoint
/// (#34). The entire exchange — connect, response headers, and the body —
/// runs inside a single wall-clock race, so a server that trickles bytes
/// or stalls mid-body cannot outrun the budget: when the timeout fires it
/// cancels the task that owns the URLSession stream. A deadline checked
/// only inside the parse loop can't do that — a never-terminated line
/// would never reach the check.
enum SSEStreamExchange {
    /// What the exchange produced.
    enum Outcome {
        /// 2xx (or a non-HTTP response): SSE consumed to `[DONE]` or EOF —
        /// `text` is the accumulated delta content, possibly empty.
        case completed(String)
        /// Non-2xx: status code and a capped body sample for logs/UI.
        case httpError(Int, String)
    }

    /// POSTs `request` and consumes the response within `seconds` of total
    /// wall-clock budget. `session` is injectable so scripted-transport
    /// tests drive the same path; `onPartial` receives the accumulated text
    /// when the coalescer allows an emission — roughly one per interval,
    /// not one per token — and hops back to the caller's actor.
    static func run(request: URLRequest, seconds: TimeInterval,
                    session: URLSession = .shared,
                    partialInterval: TimeInterval = ResourceLimits.partialUpdateInterval,
                    onPartial: @escaping @Sendable (String) async -> Void) async throws -> Outcome {
        try await TotalRequestTimeout.run(seconds: seconds) { [request, session] in
            let (bytes, response) = try await session.bytes(for: request)
            return try await consume(bytes: bytes, response: response, partialInterval: partialInterval, onPartial: onPartial)
        }
    }

    /// Consumes a response body: a non-2xx reads a bounded sample for the
    /// error path; anything else parses `data:` deltas under the parser's
    /// caps. Generic over the byte sequence so tests can drive it with
    /// controlled streams — `URLSession.AsyncBytes` can't be fabricated.
    static func consume<S: AsyncSequence>(bytes: S, response: URLResponse?,
                                          partialInterval: TimeInterval = ResourceLimits.partialUpdateInterval,
                                          onPartial: @escaping @Sendable (String) async -> Void) async throws -> Outcome where S.Element == UInt8 {
        if let http = response as? HTTPURLResponse {
            await AppLogger.shared.info("SSE stream HTTP status: \(http.statusCode)")
            guard (200...299).contains(http.statusCode) else {
                // A bounded read — an error body is a page of text at
                // most, and line-buffered reads would swallow a
                // never-terminated line whole.
                let bodyData = try await BoundedBodyReader.prefix(from: bytes, maxBytes: ResourceLimits.errorBodyMaxBytes)
                return .httpError(http.statusCode, String(String(decoding: bodyData, as: UTF8.self).prefix(2000)))
            }
        }

        // Parse the SSE stream: "data: {json}" lines, terminated by
        // "data: [DONE]". Accumulate delta content; the parser enforces
        // per-line, per-event, and cumulative caps — an exceeded cap
        // throws and unwinds the request.
        var parser = SSEStreamParser()
        var coalescer = PartialUpdateCoalescer(interval: partialInterval)
        var accumulated = ""
        var lastEmitted = ""
        stream: for try await byte in bytes {
            try Task.checkCancellation()
            switch try parser.ingest(byte) {
            case .delta(let content):
                accumulated += content
                // Rate-limited: a partial re-renders the whole accumulated
                // string, so per-token forwarding is O(output²) panel
                // work on a long stream.
                if coalescer.shouldEmit() {
                    lastEmitted = accumulated
                    await onPartial(accumulated)
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
        // One trailing emission carries any coalesced tail — without it the
        // panel can sit a fragment short of the final text until the
        // terminal callback lands.
        if accumulated != lastEmitted {
            await onPartial(accumulated)
        }
        return .completed(accumulated)
    }
}
