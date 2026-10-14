import XCTest
@testable import VoiceInput

@MainActor
final class TrackedTaskStoreTests: XCTestCase {

    private func makeStore() -> TrackedTaskStore { TrackedTaskStore() }

    func testFinishedTaskIsRemoved() async throws {
        let store = makeStore()
        let task = Task { () -> Void in }
        store.track(task, label: "finishes-immediately")
        // Track registers synchronously; removal needs a hop — wait for it.
        let exited = await store.waitForAll(timeout: .seconds(1))
        XCTAssertTrue(exited)
        XCTAssertTrue(store.outstanding.isEmpty)
    }

    func testCancelledTaskStaysTrackedUntilBodyExits() async throws {
        let store = makeStore()
        var release: (() -> Void)!
        let gate = Task { () -> Void in
            await withCheckedContinuation { continuation in
                release = { continuation.resume() }
            }
        }
        store.track(gate, label: "ignores-cancellation")

        store.cancelAll()
        // Cancellation was requested but the body has not unwound — it must
        // still be tracked. This is the invariant "cancel ≠ done".
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.outstanding, ["ignores-cancellation"])

        release()
        let exited = await store.waitForAll(timeout: .seconds(1))
        XCTAssertTrue(exited)
        XCTAssertTrue(store.outstanding.isEmpty)
    }

    func testWaitForAllTimesOutOnStuckTask() async throws {
        let store = makeStore()
        let stuck = Task { () -> Void in
            await withCheckedContinuation { _ in }  // never resumes
        }
        store.track(stuck, label: "stuck")
        let exited = await store.waitForAll(timeout: .milliseconds(100))
        XCTAssertFalse(exited)
        XCTAssertEqual(store.outstanding, ["stuck"])
        stuck.cancel()
    }

    func testMultipleTasksTrackedIndependently() async throws {
        let store = makeStore()
        var release: (() -> Void)!
        let gated = Task { () -> Void in
            await withCheckedContinuation { c in release = { c.resume() } }
        }
        store.track(gated, label: "gated")
        store.track(Task { () -> Void in }, label: "instant")

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.outstanding, ["gated"])

        release()
        let exited = await store.waitForAll(timeout: .seconds(1))
        XCTAssertTrue(exited)
    }
}
