import XCTest
@testable import VoiceInput

/// Temp-recording bookkeeping (#35): the session↔file naming convention,
/// owner-only directory permissions, symlink rejection, the flock that
/// proves a file is still owned, and the orphan sweeps for both the
/// dedicated dir and the pre-#35 legacy location — all against test dirs,
/// no real temp access and no TCC involvement.
final class RecordingTempStoreTests: XCTestCase {
    private var parentDir: TemporaryDirectory!
    private var dirURL: URL!
    private var legacyURL: URL!
    private var store: RecordingTempStore!

    override func setUpWithError() throws {
        parentDir = try TemporaryDirectory()
        // Neither directory is pre-created — tests decide what exists
        // (sweep must tolerate absence; ensure must create).
        dirURL = parentDir.url.appendingPathComponent("VoiceInput-ASR", isDirectory: true)
        legacyURL = parentDir.url.appendingPathComponent("LegacyTemp", isDirectory: true)
        store = RecordingTempStore(directoryURL: dirURL, legacyDirectoryURL: legacyURL)
    }

    override func tearDown() {
        store = nil
        dirURL = nil
        legacyURL = nil
        parentDir = nil
    }

    /// Writes `name` under `dir` (creating it), optionally backdating both
    /// timestamps — the sweep trusts the newest, so one must not stay
    /// recent or the file won't look expired.
    @discardableResult
    private func makeFile(in dir: URL, named name: String, modifiedAgo age: TimeInterval? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("PCM".utf8).write(to: url)
        if let age {
            let past = Date().addingTimeInterval(-age)
            try FileManager.default.setAttributes(
                [.modificationDate: past, .creationDate: past],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    private func makeRecording(in dir: URL, id: UUID = UUID(), modifiedAgo age: TimeInterval? = nil) throws -> URL {
        try makeFile(in: dir, named: RecordingTempStore.fileName(forSessionID: id), modifiedAgo: age)
    }

    private var expiredAge: TimeInterval { RecordingTempStore.orphanMaxAge + 60 }

    // MARK: - naming convention

    /// The convention that links session ↔ recording and that the sweep
    /// matches on: `voiceinput-asr-<uuid>.wav`.
    func testFileNameConvention() {
        let id = UUID()
        XCTAssertEqual(RecordingTempStore.fileName(forSessionID: id), "voiceinput-asr-\(id.uuidString).wav")
    }

    /// The middle must parse as a UUID — a merely similar name is not
    /// ours to delete, however old it is.
    func testIsRecordingFileNameRequiresRealUUID() {
        XCTAssertTrue(RecordingTempStore.isRecordingFileName(RecordingTempStore.fileName(forSessionID: UUID())))
        for name in [
            "voiceinput-asr-notes.wav",       // words, not a UUID
            "voiceinput-asr-12345.wav",       // digits, not a UUID
            "voiceinput-asr-\(UUID().uuidString).txt", // wrong extension
            "voiceinput-asr.wav",             // no id at all
            "other-\(UUID().uuidString).wav", // wrong prefix
        ] {
            XCTAssertFalse(RecordingTempStore.isRecordingFileName(name), name)
        }
    }

    // MARK: - directory creation

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

    /// A symlink at the recording path is refused: neither ensure nor
    /// recording creation may follow it into a foreign directory, and
    /// nothing outside it gets touched.
    func testSymlinkedDirectoryIsRejected() throws {
        let external = parentDir.url.appendingPathComponent("External", isDirectory: true)
        let outsideFile = try makeRecording(in: external, modifiedAgo: expiredAge)
        try FileManager.default.createSymbolicLink(atPath: dirURL.path, withDestinationPath: external.path)

        XCTAssertThrowsError(try store.ensureDirectory()) { error in
            XCTAssertEqual(error as? RecordingTempStoreError, .insecureDirectory)
        }
        XCTAssertThrowsError(try store.openRecordingFileDescriptor(forSessionID: UUID()))

        // The sweep must not descend through the link either — the
        // external file would otherwise have been deleted.
        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    // MARK: - recording lock

    /// The session lock is exclusive: a second claim on the same name
    /// fails — that is exactly the signal the sweep relies on.
    func testRecordingDescriptorLockIsExclusive() throws {
        let id = UUID()
        let fd = try store.openRecordingFileDescriptor(forSessionID: id)
        XCTAssertThrowsError(try store.openRecordingFileDescriptor(forSessionID: id)) { error in
            XCTAssertEqual(error as? RecordingTempStoreError, .recordingLocked)
        }
        close(fd)
    }

    // MARK: - orphan sweep

    /// The backstop for a process killed mid-capture: unlocked recordings
    /// older than the grace window are removed at next launch.
    func testSweepDeletesExpiredRecordings() throws {
        let expired = try makeRecording(in: dirURL, modifiedAgo: expiredAge)
        XCTAssertEqual(store.sweepOrphans(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
    }

    /// The age gate is the secondary condition: a file young enough to
    /// belong to a live capture is never touched even when unlocked.
    func testSweepKeepsFreshRecordings() throws {
        let fresh = try makeRecording(in: dirURL)
        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// The decisive condition: a file whose flock a live session still
    /// holds is not an orphan — even expired, even with the clock advanced
    /// (a suspended process, another instance mid-capture).
    func testSweepKeepsExpiredRecordingStillLocked() throws {
        let locked = try makeRecording(in: dirURL, modifiedAgo: expiredAge)
        let fd = open(locked.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { close(fd) }

        XCTAssertEqual(store.sweepOrphans(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
    }

    /// Once the holder is gone the same file becomes a normal orphan.
    func testSweepDeletesRecordingAfterLockReleased() throws {
        let locked = try makeRecording(in: dirURL, modifiedAgo: expiredAge)
        let fd = open(locked.path, O_RDONLY)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        close(fd)

        XCTAssertEqual(store.sweepOrphans(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: locked.path))
    }

    /// Only files matching the full convention are eligible — anything
    /// else in the directory (other extensions, non-UUID names, symlinks,
    /// same-named directories) is not ours to delete.
    func testSweepIgnoresNonConformingEntries() throws {
        let otherWav = try makeFile(in: dirURL, named: "unrelated.wav", modifiedAgo: expiredAge)
        let noUUID = try makeFile(in: dirURL, named: "voiceinput-asr-notes.wav", modifiedAgo: expiredAge)
        let txt = try makeFile(in: dirURL, named: "voiceinput-asr-\(UUID().uuidString).txt", modifiedAgo: expiredAge)
        let subdir = dirURL.appendingPathComponent(RecordingTempStore.fileName(forSessionID: UUID()), isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
        let link = dirURL.appendingPathComponent(RecordingTempStore.fileName(forSessionID: UUID()))
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: otherWav.path)
        XCTAssertEqual(store.sweepOrphans(), 0)
        for url in [otherWav, noUUID, txt, subdir, link] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    /// Pre-#35 builds leaked recordings straight into the shared temp
    /// root — the upgrade sweep must reach them there too, with the same
    /// strict checks.
    func testSweepDeletesLegacyRootRecordings() throws {
        let legacyOrphan = try makeRecording(in: legacyURL, modifiedAgo: expiredAge)
        let legacyFresh = try makeRecording(in: legacyURL)
        let legacyBad = try makeFile(in: legacyURL, named: "voiceinput-asr-notes.wav", modifiedAgo: expiredAge)
        XCTAssertEqual(store.sweepOrphans(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyOrphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyBad.path))
    }

    /// First launch (or a cleaned temp root): nothing to sweep must not
    /// be an error.
    func testSweepToleratesMissingDirectories() {
        XCTAssertEqual(store.sweepOrphans(), 0)
    }
}
