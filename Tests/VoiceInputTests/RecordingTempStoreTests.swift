import XCTest
@testable import VoiceInput

/// Temp-recording bookkeeping (#35): the session↔file naming convention,
/// owner-only directory permissions, path containment, and the launch
/// orphan sweep's age gate — all against a test dir, no real temp access
/// and no TCC involvement.
final class RecordingTempStoreTests: XCTestCase {
    private var parentDir: TemporaryDirectory!
    private var dirURL: URL!
    private var store: RecordingTempStore!

    override func setUpWithError() throws {
        parentDir = try TemporaryDirectory()
        // The store's directory is NOT pre-created — tests decide whether
        // it exists (sweep must tolerate it missing).
        dirURL = parentDir.url.appendingPathComponent("VoiceInput-ASR", isDirectory: true)
        store = RecordingTempStore(directoryURL: dirURL)
    }

    override func tearDown() {
        store = nil
        dirURL = nil
        parentDir = nil
    }

    private func makeRecording(named name: String? = nil, modifiedAgo age: TimeInterval? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = dirURL.appendingPathComponent(name ?? RecordingTempStore.fileName(forSessionID: UUID()))
        try Data("PCM".utf8).write(to: url)
        if let age {
            let past = Date().addingTimeInterval(-age)
            // Both timestamps must read as expired — the sweep trusts the
            // newest one so a just-created file is never mistaken for an
            // orphan.
            try FileManager.default.setAttributes(
                [.modificationDate: past, .creationDate: past],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    // MARK: - naming + containment

    /// The convention that links session ↔ recording and that the sweep
    /// matches on: `voiceinput-asr-<uuid>.wav`.
    func testFileNameConvention() {
        let id = UUID()
        XCTAssertEqual(RecordingTempStore.fileName(forSessionID: id), "voiceinput-asr-\(id.uuidString).wav")
    }

    /// A handed-in name is reduced to its last path component — deletes
    /// must never escape the recording directory.
    func testFileURLStaysInsideRecordingDirectory() {
        let url = store.fileURL(forFileName: "../evil.wav")
        XCTAssertEqual(url, dirURL.appendingPathComponent("evil.wav"))
    }

    // MARK: - directory permissions

    /// Raw mic audio sits here: the directory must be owner-only.
    func testEnsureDirectoryCreatesOwnerOnlyDirectory() throws {
        try store.ensureDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: dirURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o700)
    }

    /// A pre-existing directory with looser permissions gets tightened —
    /// the guarantee comes from the store, not from whatever created it.
    func testEnsureDirectoryRepairsLoosePermissions() throws {
        try FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try store.ensureDirectory()
        let attrs = try FileManager.default.attributesOfItem(atPath: dirURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o700)
    }

    // MARK: - orphan sweep

    /// The backstop for a process killed mid-capture: recordings older
    /// than the grace window are removed at next launch.
    func testSweepDeletesExpiredRecordings() throws {
        let expired = try makeRecording(modifiedAgo: RecordingTempStore.orphanMaxAge + 60)
        XCTAssertEqual(store.sweepOrphans(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    }

    /// The age gate is what makes the sweep safe: a file young enough to
    /// belong to a live capture is never touched.
    func testSweepKeepsFreshRecordings() throws {
        let fresh = try makeRecording()
        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Only files matching the recording convention are eligible —
    /// anything else in the directory (or a same-named subdirectory) is
    /// not ours to delete.
    func testSweepIgnoresNonMatchingEntries() throws {
        let otherWav = try makeRecording(named: "unrelated.wav", modifiedAgo: RecordingTempStore.orphanMaxAge + 60)
        let txt = try makeRecording(named: "voiceinput-asr-notes.txt", modifiedAgo: RecordingTempStore.orphanMaxAge + 60)
        let subdir = dirURL.appendingPathComponent("voiceinput-asr-dir.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: txt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: subdir.path))
    }

    /// First launch (or a cleaned temp root): nothing to sweep must not be
    /// an error.
    func testSweepToleratesMissingDirectory() {
        XCTAssertEqual(store.sweepOrphans(), 0)
    }
}
