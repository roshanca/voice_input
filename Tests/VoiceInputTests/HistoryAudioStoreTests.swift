import XCTest
@testable import VoiceInput

/// Clip-file bookkeeping (#25): the session↔file name convention, path
/// containment, existence checks, and deletes — all against a temp dir, no
/// real Application Support access.
final class HistoryAudioStoreTests: XCTestCase {
    private var tempDir: TemporaryDirectory!
    private var store: HistoryAudioStore!

    override func setUpWithError() throws {
        tempDir = try TemporaryDirectory()
        store = HistoryAudioStore(directoryURL: tempDir.url)
    }

    override func tearDown() {
        store = nil
        tempDir = nil
    }

    // MARK: - fileName mapping

    /// The convention that links record ↔ clip: `<uuid>.caf`.
    func testFileNameIsSessionIDPlusCAF() {
        let id = UUID()
        XCTAssertEqual(HistoryAudioStore.fileName(forSessionID: id), "\(id.uuidString).caf")
    }

    /// A stored or handed-in name is reduced to its last path component —
    /// deletes and writes must never escape the audio directory.
    func testFileURLStaysInsideAudioDirectory() {
        let url = store.fileURL(forFileName: "../evil.caf")
        XCTAssertEqual(url, tempDir.url.appendingPathComponent("evil.caf"))
    }

    // MARK: - existence + listing

    func testExistingFileNameNilThenPresent() throws {
        let id = UUID()
        XCTAssertNil(store.existingFileName(forSessionID: id))
        try Data("audio".utf8).write(to: store.fileURL(forSessionID: id))
        XCTAssertEqual(store.existingFileName(forSessionID: id), "\(id.uuidString).caf")
    }

    func testAudioFileNamesListsOnlyClips() throws {
        try Data().write(to: tempDir.url.appendingPathComponent("a.caf"))
        try Data().write(to: tempDir.url.appendingPathComponent("b.caf"))
        try Data().write(to: tempDir.url.appendingPathComponent("notes.txt"))
        try Data().write(to: tempDir.url.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(Set(store.audioFileNames()), ["a.caf", "b.caf"])
    }

    // MARK: - deletes

    func testDeleteRemovesNamedClip() throws {
        let id = UUID()
        try Data().write(to: store.fileURL(forSessionID: id))
        store.deleteAudio(forSessionID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forSessionID: id).path))
    }

    /// Deleting a name that isn't there is a no-op — record-side deletes
    /// never need a pre-check.
    func testDeleteMissingClipIsNoOp() {
        store.delete(fileName: "never-existed.caf")
    }

    /// A traversal-looking name can't reach outside the directory.
    func testDeleteCannotEscapeDirectory() throws {
        let outside = tempDir.url.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString).caf")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        store.delete(fileName: outside.lastPathComponent + "/../" + outside.lastPathComponent)
        // Even the degenerate resolved name resolves inside the dir.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testDeleteAllClearsOnlyClips() throws {
        try Data().write(to: tempDir.url.appendingPathComponent("a.caf"))
        try Data().write(to: tempDir.url.appendingPathComponent("keep.txt"))
        store.deleteAll()
        XCTAssertTrue(store.audioFileNames().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.url.appendingPathComponent("keep.txt").path))
    }
}
