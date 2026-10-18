import Foundation

/// Wraps a metadata value whose contents must never reach a log line.
struct SensitiveLogValue {
    let rawValue: Any

    init(_ rawValue: Any) {
        self.rawValue = rawValue
    }
}

/// Redacts secrets and dictated content before anything is stored in memory
/// or written to OSLog. All entry points are pure so they stay testable.
enum LogRedactor {
    static let placeholder = "<redacted>"

    /// Lowercased, alphanumeric-only key suffixes. Suffix matching catches
    /// camelCase compounds (apiKey, accessToken, rawText); over-redacting a
    /// key like "context" is preferred over leaking a transcript.
    private static let sensitiveKeyWords = [
        "transcript", "text", "prompt", "result",
        "token", "password", "passwd", "secret", "bearer",
        "apikey", "accesskey", "secretkey", "privatekey", "sessionkey", "appkey",
        "authorization", "cookie", "credential", "credentials",
        // Arbitrary-content carriers: server response bodies and error
        // details can echo secrets (or user text) back into a log line.
        "body", "response", "message", "detail", "content", "output"
    ]

    /// Secrets embedded in plain message strings: "key=value" in URLs and
    /// "Authorization: Bearer …" style headers. URL userinfo is NOT here —
    /// a character-class regex can't bound it (spaces and unencoded "@"
    /// inside userinfo are both legal to Foundation); scrubURLUserinfo
    /// scans the authority properly.
    private static let sensitivePatterns = [
        #"(?i)(authorization\s*[:=]\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#,
        #"(?i)([?&](?:api_key|apikey|key|token|access_token|refresh_token|secret|password)=)[^&#\s]+"#,
        #"(?i)((?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|oauth[-_ ]?token|bearer[-_ ]?token|token|secret|password)\s*[:=]\s*)[^\s,;&]+"#
    ]

    private static let compiledPatterns: [NSRegularExpression] = sensitivePatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// `scheme://` detector for the userinfo sweep — the authority that
    /// follows is scanned char-by-char so malformed userinfo can't slip
    /// past a character class.
    private static let schemeDelimiterRegex = try? NSRegularExpression(
        pattern: #"[a-z][a-z0-9+.-]*://"#, options: [.caseInsensitive]
    )

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeyWords.contains { normalized.hasSuffix($0) }
    }

    /// Scrubs secrets embedded in free-text messages — URL userinfo,
    /// key=value secrets, bearer headers — and shortens home paths.
    static func redactText(_ text: String) -> String {
        // Userinfo masks FIRST: a `secret=value` pattern hit inside
        // `user:pass token=x@host` would otherwise swallow the "@" plus
        // everything after it, and the sweep would find no boundary —
        // leaving the credentials' prefix standing.
        var output = scrubURLUserinfo(text)
        for pattern in compiledPatterns {
            output = pattern.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: "$1\(placeholder)"
            )
        }
        let home = NSHomeDirectory()
        if !home.isEmpty {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        return output
    }

    /// Masks `userinfo@` on any `scheme://` authority embedded in free
    /// text — userinfo is credentials by definition, and this is the
    /// backstop for strings that never went through `sanitizedURL`.
    ///
    /// The authority run after `://` ends at the first `/`, `?`, or `#`;
    /// whitespace does NOT end it, because Foundation accepts spaced
    /// userinfo and auto-encodes it. For a run containing "@": userinfo
    /// ends at the LAST "@" — an unencoded "@" is legal inside it, so a
    /// lazier split leaves a password suffix standing (`pa@ss` → `ss`
    /// would leak). If the run also contains whitespace the URL's extent
    /// is ambiguous (encoded credentials vs. ordinary message text) and
    /// the whole URL — authority plus its path tail — is masked instead.
    private static func scrubURLUserinfo(_ text: String) -> String {
        guard let matches = schemeDelimiterRegex?.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ), !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let schemeRange = Range(match.range, in: text),
                  schemeRange.lowerBound >= cursor else { continue }

            var index = schemeRange.upperBound
            while index < text.endIndex, !"/?#".contains(text[index]) {
                index = text.index(after: index)
            }
            let authority = text[schemeRange.upperBound..<index]
            // Userinfo ends at the LAST "@" in the authority.
            guard let at = authority.lastIndex(of: "@") else { continue }

            output += text[cursor..<schemeRange.upperBound]
            if authority.contains(where: \.isWhitespace) {
                while index < text.endIndex, !text[index].isWhitespace {
                    index = text.index(after: index)
                }
                output += placeholder
            } else {
                output += "\(placeholder)@"
                index = text.index(after: at)
            }
            cursor = index
        }
        output += text[cursor...]
        return output
    }

    /// Path segments from the OpenAI-compatible endpoint vocabulary this
    /// app speaks (`{base}/audio/transcriptions`, `{base}/chat/completions`
    /// plus the base-path nouns those endpoints are mounted under). Any
    /// other segment is user-chosen — a gateway path can itself be a
    /// secret — and collapses to `…` in logs.
    private static let allowedURLPathSegments: Set<String> = [
        "api", "openai", "v1", "v2", "v3", "v1beta",
        "audio", "transcriptions", "translations", "speech",
        "chat", "completions", "responses", "models",
        "embeddings", "generate", "version", "ollama"
    ]

    /// Query item names safe to name in a log line — values never are.
    /// Everything else is dropped outright: credentials ride query
    /// strings (`?api_key=…`) more often than any other URL part.
    private static let allowedURLQueryNames: Set<String> = [
        "model", "format", "language", "response_format", "stream", "version"
    ]

    /// A configured endpoint URL rendered safe for a log line. Scheme,
    /// host, and port survive (they're the debugging signal); userinfo
    /// and fragments never do; path segments and query items pass only
    /// through the allowlists above — an allowlist, not a denylist,
    /// because an unknown component is assumed sensitive. An unparseable
    /// input collapses to the placeholder: its raw form can carry
    /// `user:password@` and must never be echoed.
    static func sanitizedURL(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else {
            return placeholder
        }
        var safe = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)"
        if let port = components.port {
            safe += ":\(port)"
        }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        if !segments.isEmpty {
            safe += "/" + segments.map {
                allowedURLPathSegments.contains($0.lowercased()) ? String($0) : "…"
            }.joined(separator: "/")
        }
        if let items = components.queryItems, !items.isEmpty {
            var rendered = items.compactMap { item -> String? in
                allowedURLQueryNames.contains(item.name.lowercased())
                    ? "\(item.name)=\(placeholder)"
                    : nil
            }
            if rendered.count < items.count { rendered.append("…") }
            safe += "?\(rendered.joined(separator: "&"))"
        } else if components.query != nil {
            // Malformed query — present but unparseable, so nothing in it
            // can be checked against the allowlist.
            safe += "?…"
        }
        return safe
    }

    /// Stable, content-free error identifier for a log line — what an
    /// `errorCode` metadata entry carries instead of `localizedDescription`.
    /// `RemoteASRError` reports its case (`httpStatus` keeps the status but
    /// never the server's `message`, which is body echo); anything else
    /// reports `domain.code`, which carries no user/server text either.
    static func errorCode(_ error: Error) -> String {
        if let remote = error as? RemoteASRError {
            return "remoteASR.\(remote.logCode)"
        }
        let nsError = error as NSError
        return "\(nsError.domain).\(nsError.code)"
    }

    /// Deterministic "{key: value, …}" rendering with every sensitive value
    /// already replaced by the placeholder.
    static func renderMetadata(_ metadata: [String: Any]) -> String {
        renderDictionary(metadata)
    }

    private static func renderValue(_ value: Any, keyIsSensitive: Bool) -> String {
        if keyIsSensitive || value is SensitiveLogValue {
            return placeholder
        }
        switch value {
        case let dictionary as [String: Any]:
            return renderDictionary(dictionary)
        case let array as [Any]:
            return "[" + array.map { renderValue($0, keyIsSensitive: false) }.joined(separator: ", ") + "]"
        case let string as String:
            return redactText(string)
        default:
            return redactText(String(describing: value))
        }
    }

    private static func renderDictionary(_ dictionary: [String: Any]) -> String {
        let body = dictionary.keys.sorted().map { key in
            "\(key): \(renderValue(dictionary[key] ?? "", keyIsSensitive: isSensitiveKey(key)))"
        }.joined(separator: ", ")
        return "{\(body)}"
    }
}
