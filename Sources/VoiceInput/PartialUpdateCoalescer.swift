import Foundation

/// Rate-limits streamed-text UI updates (#34). Every partial copies the
/// whole accumulated string into the panel — label assignment, layout, and
/// a resize animation — so forwarding every token is O(output²) churn on a
/// long stream. `shouldEmit` passes the first fragment immediately for
/// feedback, then at most one update per `interval`; the terminal callback
/// always carries the final text, so nothing is lost by dropping
/// intermediate emissions.
struct PartialUpdateCoalescer {
    private let interval: TimeInterval
    private let now: () -> Date
    private var lastEmit: Date?

    init(interval: TimeInterval = ResourceLimits.partialUpdateInterval,
         now: @escaping () -> Date = Date.init) {
        self.interval = interval
        self.now = now
    }

    /// True when an emission is due — the first call always emits.
    mutating func shouldEmit() -> Bool {
        let now = now()
        guard let lastEmit else {
            self.lastEmit = now
            return true
        }
        guard now.timeIntervalSince(lastEmit) >= interval else { return false }
        self.lastEmit = now
        return true
    }
}
