import Foundation

/// Wall-clock ceiling for a whole request (#34). `timeoutInterval`
/// measures idle gaps only, so an endpoint that keeps trickling bytes —
/// or an SSE stream that never terminates — would hold a request open
/// forever.
enum TotalRequestTimeout {
    struct TimedOut: LocalizedError, Equatable {
        let seconds: TimeInterval
        var errorDescription: String? { "The request took too long." }
    }

    /// Races `operation` against `seconds`; whichever finishes first wins.
    /// The loser is cancelled — the group's structured scope still waits
    /// for its real exit before returning (cancellation ≠ completion).
    static func run<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            // Two children were just added, so next() can't legitimately
            // return nil — but if it did, surfacing a cancellation beats
            // a crash or a hang.
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}
