import Foundation

/// Reads a response body under a hard byte ceiling (#34).
/// `URLSession.data(for:)` buffers the whole body — a misbehaving endpoint
/// could stream bytes forever and grow memory without bound.
enum BoundedBodyReader {
    struct BodyTooLarge: LocalizedError, Equatable {
        let limit: Int
        var errorDescription: String? { "The response exceeded the size limit." }
    }

    /// Accumulates `bytes` until EOF, throwing once the body passes
    /// `maxBytes`. Abandoning the iteration unwinds the URLSession task
    /// behind the stream, same as a break.
    static func collect<S: AsyncSequence>(from bytes: S, maxBytes: Int) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maxBytes else { throw BodyTooLarge(limit: maxBytes) }
        }
        return data
    }

    /// Reads at most `maxBytes` then stops — for bodies we only want a
    /// sample of (error text for the log), where truncating beats failing.
    static func prefix<S: AsyncSequence>(from bytes: S, maxBytes: Int) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        for try await byte in bytes {
            guard data.count < maxBytes else { break }
            data.append(byte)
        }
        return data
    }
}
