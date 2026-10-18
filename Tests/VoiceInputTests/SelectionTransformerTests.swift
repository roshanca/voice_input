import os
import XCTest
@testable import VoiceInput

/// Cancellation isolation for SelectionTransformer (#33): a superseded or
/// Esc-cancelled request must never fire its callbacks. URLSession reports
/// that cancellation as URLError.cancelled (-999), which used to land in the
/// generic failure branch and resolve the caller's in-flight state while the
/// successor was still running. A scripted URLProtocol on a fictional host
/// drives every response — no network, no permissions.
@MainActor
final class SelectionTransformerTests: XCTestCase {

    override func setUp() {
        ScriptedURLProtocol.scripts = []
    }

    private func makeTransformer() -> SelectionTransformer {
        // Ollama needs no API key and the override skips the Keychain read —
        // no Keychain, no UserDefaults, no network involved anywhere.
        let config = LLMConfig(id: UUID(), name: "Stub", providerType: .ollama,
                               baseURL: "http://\(ScriptedURLProtocol.stubHost)/v1",
                               model: "stub-model")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [ScriptedURLProtocol.self]
        return SelectionTransformer(config: config, apiKeyOverride: "",
                                    session: URLSession(configuration: sessionConfig))
    }

    /// The audited race: B presses while A waits on its stream. A's unwinding
    /// task must deliver nothing — no late partials, and not the
    /// URLError.cancelled that used to reach completion as a failure.
    func testSupersededRequestDeliversNothing() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.line(Self.sse("A-part")), .hang]),
            .init(steps: [.line(Self.sse("B-result")), .line("data: [DONE]"), .complete])
        ]
        let transformer = makeTransformer()
        let a = CallbackLog()
        transformer.transform(kind: .rewrite, text: "A", requestID: UUID(),
                              onPartial: { a.partials.append($0) },
                              completion: { a.results.append($0) })
        let aPartialArrived = await waitUntil { !a.partials.isEmpty }
        XCTAssertTrue(aPartialArrived, "A's first partial never arrived")
        let partialsAtSupersede = a.partials.count

        let b = CallbackLog()
        transformer.transform(kind: .rewrite, text: "B", requestID: UUID(),
                              onPartial: { b.partials.append($0) },
                              completion: { b.results.append($0) })

        let bCompleted = await waitUntil { !b.results.isEmpty }
        XCTAssertTrue(bCompleted, "B never completed")
        let allUnwound = await TrackedTaskStore.shared.waitForAll(timeout: .seconds(5))
        XCTAssertTrue(allUnwound, "superseded task did not unwind")

        XCTAssertTrue(a.results.isEmpty, "superseded request delivered \(a.results)")
        XCTAssertEqual(a.partials.count, partialsAtSupersede, "late partials arrived after supersede")
        XCTAssertEqual(b.partials, ["B-result"])
        XCTAssertEqual(b.results.count, 1)
        guard case .success(let text) = b.results.first else {
            return XCTFail("B should succeed — got \(String(describing: b.results.first))")
        }
        XCTAssertEqual(text, "B-result")
    }

    /// Esc path after a supersede: B replaces A, then the user cancels B —
    /// neither request may resolve.
    func testSupersedeThenCancelDeliversNothing() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.hang]),
            .init(steps: [.hang])
        ]
        let transformer = makeTransformer()
        let a = CallbackLog()
        transformer.transform(kind: .rewrite, text: "A", requestID: UUID(),
                              onPartial: { a.partials.append($0) },
                              completion: { a.results.append($0) })
        let b = CallbackLog()
        transformer.transform(kind: .rewrite, text: "B", requestID: UUID(),
                              onPartial: { b.partials.append($0) },
                              completion: { b.results.append($0) })

        transformer.cancel()
        let allUnwound = await TrackedTaskStore.shared.waitForAll(timeout: .seconds(5))
        XCTAssertTrue(allUnwound, "cancelled tasks did not unwind")

        XCTAssertTrue(a.results.isEmpty, "superseded request delivered \(a.results)")
        XCTAssertTrue(b.results.isEmpty, "cancelled request delivered \(b.results)")
    }

    /// Esc path on a single in-flight request: cancel() must not produce a
    /// completion — the cancelled request's failure flash is exactly the
    /// spurious surface this fix removes.
    func testCancelDeliversNoCompletion() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.line(Self.sse("part")), .hang])
        ]
        let transformer = makeTransformer()
        let log = CallbackLog()
        transformer.transform(kind: .rewrite, text: "T", requestID: UUID(),
                              onPartial: { log.partials.append($0) },
                              completion: { log.results.append($0) })
        let partialArrived = await waitUntil { !log.partials.isEmpty }
        XCTAssertTrue(partialArrived, "partial never arrived")

        transformer.cancel()
        let unwound = await TrackedTaskStore.shared.waitForAll(timeout: .seconds(5))
        XCTAssertTrue(unwound, "cancelled task did not unwind")

        XCTAssertTrue(log.results.isEmpty, "cancel delivered \(log.results)")
        XCTAssertEqual(log.partials.count, 1, "late partials arrived after cancel")
    }

    /// The URLSession-level cancel shape: a load can report URLError.cancelled
    /// (-999) while the Swift task is not marked cancelled — the session
    /// tearing the load down is a cancel too, never a failure the caller sees.
    func testURLErrorCancelledIsNotDeliveredAsFailure() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.fail(URLError(.cancelled))])
        ]
        let transformer = makeTransformer()
        let log = CallbackLog()
        transformer.transform(kind: .rewrite, text: "T", requestID: UUID(),
                              onPartial: { log.partials.append($0) },
                              completion: { log.results.append($0) })

        let unwound = await TrackedTaskStore.shared.waitForAll(timeout: .seconds(5))
        XCTAssertTrue(unwound, "task did not exit")
        XCTAssertTrue(log.results.isEmpty, "URLError.cancelled surfaced as a failure: \(log.results)")
    }

    /// Control: a genuine failure on the live request still reports exactly
    /// once — the isolation drops stale work, not real errors.
    func testLiveRequestFailureStillReports() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.fail(URLError(.timedOut))])
        ]
        let transformer = makeTransformer()
        let log = CallbackLog()
        transformer.transform(kind: .rewrite, text: "T", requestID: UUID(),
                              onPartial: { log.partials.append($0) },
                              completion: { log.results.append($0) })

        let failed = await waitUntil { !log.results.isEmpty }
        XCTAssertTrue(failed, "live failure never reported")
        XCTAssertEqual(log.results.count, 1)
        guard case .failure = log.results[0] else {
            return XCTFail("expected a failure, got \(log.results[0])")
        }
    }

    /// Control: the happy path still delivers one trimmed success.
    func testLiveRequestSuccessDeliversTrimmed() async throws {
        ScriptedURLProtocol.scripts = [
            .init(steps: [.line(Self.sse("hel")), .line(Self.sse("lo")),
                          .line("data: [DONE]"), .complete])
        ]
        let transformer = makeTransformer()
        let log = CallbackLog()
        transformer.transform(kind: .rewrite, text: "T", requestID: UUID(),
                              onPartial: { log.partials.append($0) },
                              completion: { log.results.append($0) })

        let completed = await waitUntil { !log.results.isEmpty }
        XCTAssertTrue(completed, "live request never completed")
        XCTAssertEqual(log.partials, ["hel", "hello"])
        guard case .success(let text) = log.results.first else {
            return XCTFail("expected success, got \(String(describing: log.results.first))")
        }
        XCTAssertEqual(text, "hello")
    }

    // MARK: - Helpers

    /// Callback sink for one transform call. Transform callbacks run on the
    /// main actor like the class itself — a plain log is safe.
    private final class CallbackLog {
        var partials: [String] = []
        var results: [Result<String, Error>] = []
    }

    /// One OpenAI-style SSE chunk carrying `content` as the delta.
    private static func sse(_ content: String) -> String {
        #"data: {"choices":[{"delta":{"content":"\#(content)"}}]}"#
    }

    /// Poll on the main actor until `condition` holds or `timeout` expires.
    /// Callbacks under test are main-actor work, so sleeping lets them run.
    private func waitUntil(_ timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Deterministic stub server for the transformer's URLSession: each request
/// to the fictional host dequeues the next script in arrival order, so a
/// test can hand request A and request B different server behavior. Steps
/// are emitted on a small delay to keep cancellation windows open.
private final class ScriptedURLProtocol: URLProtocol {
    static let stubHost = "selection-transform.test"

    enum Step {
        /// Emit one SSE line ("data: ..." — [DONE] included).
        case line(String)
        /// Fail the load with a transport error.
        case fail(URLError)
        /// Finish the load cleanly.
        case complete
        /// Keep the load open until the client cancels it — the "A still
        /// waiting on the server" shape from the issue.
        case hang
    }

    struct Script {
        var steps: [Step]
    }

    private static let queue = OSAllocatedUnfairLock(initialState: [Script]())

    static var scripts: [Script] {
        get { queue.withLock { $0 } }
        set { queue.withLock { $0 = newValue } }
    }

    private static func nextScript() -> Script {
        queue.withLock { scripts in
            scripts.isEmpty ? Script(steps: [.complete]) : scripts.removeFirst()
        }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private var isStopped: Bool { stopped.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == stubHost
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let script = Self.nextScript()
        Task {
            if let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "text/event-stream"]) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            for step in script.steps {
                if isStopped { return }
                switch step {
                case .line(let line):
                    client?.urlProtocol(self, didLoad: Data("\(line)\n".utf8))
                    // The gap between emissions is where cancellations land.
                    try? await Task.sleep(for: .milliseconds(15))
                case .fail(let error):
                    client?.urlProtocol(self, didFailWithError: error)
                    return
                case .complete:
                    client?.urlProtocolDidFinishLoading(self)
                    return
                case .hang:
                    while !isStopped {
                        try? await Task.sleep(for: .milliseconds(15))
                    }
                    return
                }
            }
            if !isStopped {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
