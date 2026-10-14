import Foundation

/// Cancellation is not completion: `Task.cancel()` asks, the task finishes
/// only once its suspension points have actually unwound. The store retains
/// every in-flight and cancelled-but-still-running task, so shutdown and
/// shared-resource reuse can observe real exits instead of assuming
/// cancel() finished the work.
@MainActor
final class TrackedTaskStore {
    static let shared = TrackedTaskStore()

    private struct Entry {
        let task: Task<Void, Never>
        let label: String
    }
    private var entries: [UUID: Entry] = [:]

    /// Labels of tasks still running (cancelled or not) — for diagnostics.
    private(set) var outstanding: [String] = []

    /// Keep `task` until its body actually returns — including the full
    /// unwind after a cancellation. Removal is automatic.
    func track(_ task: Task<Void, Never>, label: String) {
        let id = UUID()
        entries[id] = Entry(task: task, label: label)
        refreshOutstanding()
        Task { [weak self] in
            _ = await task.value
            self?.entries.removeValue(forKey: id)
            self?.refreshOutstanding()
        }
    }

    /// Ask every tracked task to cancel. They stay registered — and
    /// observable — until their bodies really return.
    func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
    }

    /// Suspend until no tracked task remains, or `timeout` expires.
    /// Returns false when tasks outlived the deadline — that is the point:
    /// a stuck task is observed, not silently assumed gone.
    @discardableResult
    func waitForAll(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !entries.isEmpty {
            if ContinuousClock.now >= deadline {
                AppLogger.shared.warning("Tracked tasks still outstanding at deadline: \(outstanding.joined(separator: ", "))")
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func refreshOutstanding() {
        outstanding = entries.values.map(\.label).sorted()
    }
}
