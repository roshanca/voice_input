import Foundation

/// One completed unit from an OpenAI-compatible SSE stream.
enum SSEStreamEvent: Equatable {
    /// Extracted `choices[0].delta.content` — a text fragment to append.
    case delta(String)
    /// The `data: [DONE]` terminator — callers stop consuming.
    case done
}

/// Incremental SSE reader for the OpenAI-compatible chat stream, with hard
/// resource ceilings (#34). `bytes.lines` buffers a whole line before
/// yielding it, and the old loop accumulated output without a cap — an
/// anomalous or hostile endpoint could grow memory and UI work without
/// bound. Feed wire bytes one at a time; an exceeded cap throws
/// `StreamError`, and unwinding the consume loop cancels the URLSession
/// task behind the stream.
///
/// `\n` never occurs inside a UTF-8 multibyte sequence, so splitting on the
/// raw byte is decoding-safe.
struct SSEStreamParser {
    enum StreamError: LocalizedError, Equatable {
        /// A line grew past `maxLineBytes` with no terminator.
        case lineTooLong
        /// One event (a blank-line-separated block) passed `maxEventBytes`.
        case eventTooLarge
        /// Accumulated `delta.content` passed `maxOutputBytes`.
        case outputTooLarge
        /// The stream was still producing past the caller's deadline —
        /// `timeoutInterval` bounds idle gaps, not total duration.
        case timedOut

        var errorDescription: String? {
            switch self {
            case .lineTooLong:
                return "Stream aborted: a single line exceeded the size limit."
            case .eventTooLarge:
                return "Stream aborted: an event exceeded the size limit."
            case .outputTooLarge:
                return "Stream aborted: the response exceeded the output limit."
            case .timedOut:
                return "The request took too long."
            }
        }
    }

    private let maxLineBytes: Int
    private let maxEventBytes: Int
    private let maxOutputBytes: Int
    /// When set, completing a line after this point throws `timedOut`.
    /// Checked per line — a stream that produces nothing at all is the
    /// idle timeout's job.
    private let deadline: Date?
    private let now: () -> Date

    /// Bytes of the current unterminated line.
    private var lineBuffer = Data()
    /// Bytes accumulated since the last blank line — the event budget.
    private var eventBytes = 0
    /// UTF-8 bytes of extracted content so far — the cumulative budget.
    private var outputBytes = 0

    init(maxLineBytes: Int = ResourceLimits.sseMaxLineBytes,
         maxEventBytes: Int = ResourceLimits.sseMaxEventBytes,
         maxOutputBytes: Int = ResourceLimits.sseMaxOutputBytes,
         deadline: Date? = nil,
         now: @escaping () -> Date = Date.init) {
        self.maxLineBytes = maxLineBytes
        self.maxEventBytes = maxEventBytes
        self.maxOutputBytes = maxOutputBytes
        self.deadline = deadline
        self.now = now
    }

    /// Feed one wire byte. Returns an event when the byte completed a
    /// `data:` line that yields delta text (or the `[DONE]` sentinel);
    /// non-data lines and event boundaries produce nil.
    mutating func ingest(_ byte: UInt8) throws -> SSEStreamEvent? {
        guard byte != UInt8(ascii: "\n") else {
            return try completeLine()
        }
        lineBuffer.append(byte)
        eventBytes += 1
        if lineBuffer.count > maxLineBytes { throw StreamError.lineTooLong }
        if eventBytes > maxEventBytes { throw StreamError.eventTooLarge }
        return nil
    }

    /// EOF flush: a trailing line without its `\n` still completes —
    /// `bytes.lines` yielded the final fragment too, and a truncated
    /// stream must not silently lose its last event.
    mutating func finish() throws -> SSEStreamEvent? {
        guard !lineBuffer.isEmpty else { return nil }
        return try completeLine()
    }

    private mutating func completeLine() throws -> SSEStreamEvent? {
        if let deadline, now() >= deadline { throw StreamError.timedOut }
        defer { lineBuffer.removeAll(keepingCapacity: true) }
        var line = lineBuffer[...]
        if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
        guard !line.isEmpty else {
            // Blank line: event boundary — the next block starts fresh.
            eventBytes = 0
            return nil
        }
        guard line.starts(with: "data:".utf8) else { return nil }
        let payload = String(decoding: line.dropFirst(5), as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        return try parseDelta(payload)
    }

    /// Pull `choices[0].delta.content` out of one `data:` payload.
    /// Anything else — role deltas, usage trailers, unparseable JSON — is
    /// skipped, matching the loop this replaces.
    private mutating func parseDelta(_ payload: String) throws -> SSEStreamEvent? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        outputBytes += content.utf8.count
        if outputBytes > maxOutputBytes { throw StreamError.outputTooLarge }
        return .delta(content)
    }
}
