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
        "authorization", "cookie", "credential", "credentials"
    ]

    /// Secrets embedded in plain message strings: "key=value" in URLs and
    /// "Authorization: Bearer …" style headers.
    private static let sensitivePatterns = [
        #"(?i)(authorization\s*[:=]\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#,
        #"(?i)([?&](?:api_key|apikey|key|token|access_token|refresh_token|secret|password)=)[^&#\s]+"#,
        #"(?i)((?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|oauth[-_ ]?token|bearer[-_ ]?token|token|secret|password)\s*[:=]\s*)[^\s,;&]+"#
    ]

    private static let compiledPatterns: [NSRegularExpression] = sensitivePatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeyWords.contains { normalized.hasSuffix($0) }
    }

    /// Scrubs secrets embedded in free-text messages and shortens home paths.
    static func redactText(_ text: String) -> String {
        var output = text
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
