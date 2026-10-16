import Foundation

/// Minimal multipart/form-data (RFC 2046 §5.1, RFC 7578) body builder.
/// Fields are emitted in array order — callers keep that order fixed so
/// the wire format is stable and the builder stays a pure function tests
/// can verify byte-for-byte. No streaming: dictation audio is a few MB,
/// so an in-memory body is honest and sufficient.
enum MultipartFormData {
    struct Field: Equatable {
        let name: String
        let value: String
    }

    /// Layout per part: `--boundary`, Content-Disposition (plus
    /// Content-Type for the file part), blank line, payload, CRLF. The
    /// closing boundary gets the `--` suffix. Matches what OpenAI-
    /// compatible `/audio/transcriptions` endpoints expect.
    static func body(boundary: String, fields: [Field], fileField: String, fileName: String, mimeType: String, fileData: Data) -> Data {
        var body = Data()
        for field in fields {
            body.append(contentsOf: "--\(boundary)\r\n".utf8)
            body.append(contentsOf: "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8)
            body.append(contentsOf: "\(field.value)\r\n".utf8)
        }
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: \(mimeType)\r\n\r\n".utf8)
        body.append(fileData)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        return body
    }
}
