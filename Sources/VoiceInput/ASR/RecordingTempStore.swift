import Foundation

/// Filesystem home for remote-ASR upload recordings: one WAV per session
/// under `NSTemporaryDirectory()/VoiceInput-ASR/`, named
/// `voiceinput-asr-<sessionID>.wav`. A dedicated directory — not the shared
/// temp root — so the launch sweep owns everything matching its naming
/// convention, created 0700 because it holds raw microphone audio.
/// Stateless path math + FileManager calls; the directory is injectable so
/// tests never touch the real temp location.
final class RecordingTempStore {
    static let shared = RecordingTempStore()

    /// Both halves of the naming convention sweeps match on — a recording
    /// is by definition `voiceinput-asr-<uuid>.wav` in this directory.
    static let filePrefix = "voiceinput-asr-"
    static let fileExtension = "wav"

    /// Launch sweeps remove only recordings older than this. A live
    /// capture's file is young (created moments ago, appended while the
    /// session runs), so the age gate is what keeps the sweep from ever
    /// deleting an active session's recording — e.g. a second instance
    /// mid-dictation. An hour is far beyond any utterance; older files can
    /// only come from a process that died holding them.
    static let orphanMaxAge: TimeInterval = 60 * 60

    /// Owner-only — temp roots are per-user, but explicit permissions make
    /// the privacy guarantee independent of umask and inherited modes.
    static let directoryPermissions: NSNumber = 0o700

    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInput-ASR", isDirectory: true)
    }

    /// Pure mapping — session id → recording file name. Static so the
    /// convention is usable without a store instance.
    static func fileName(forSessionID id: UUID) -> String {
        "\(filePrefix)\(id.uuidString).\(fileExtension)"
    }

    func fileURL(forSessionID id: UUID) -> URL {
        fileURL(forFileName: Self.fileName(forSessionID: id))
    }

    /// Only the last path component is honored: a handed-in name must
    /// never let a delete/write escape the recording directory.
    func fileURL(forFileName name: String) -> URL {
        directoryURL.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }

    /// Creates the directory owner-only, and re-asserts the mode when it
    /// already exists — a widened or inherited permission must not survive
    /// the next recording.
    func ensureDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        let attrs = try fileManager.attributesOfItem(atPath: directoryURL.path)
        if (attrs[.posixPermissions] as? NSNumber) != Self.directoryPermissions {
            try fileManager.setAttributes([.posixPermissions: Self.directoryPermissions], ofItemAtPath: directoryURL.path)
        }
    }

    /// Names of files matching the recording convention — sweep input.
    func recordingFileNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return contents.filter {
            $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".\(Self.fileExtension)")
        }
    }

    /// Deletes recordings orphaned by a previous process — crash, kill, or
    /// an exit path that predates terminate-time discard. Returns how many
    /// files were removed. Run at launch only, and even then only files
    /// whose newest timestamp predates `maxAge` go: anything younger is
    /// conservatively treated as a live capture's file. Non-regular files
    /// and unstatable entries are skipped rather than removed.
    @discardableResult
    func sweepOrphans(now: Date = Date(), maxAge: TimeInterval = RecordingTempStore.orphanMaxAge) -> Int {
        let cutoff = now.addingTimeInterval(-maxAge)
        var removed = 0
        for name in recordingFileNames() {
            let url = fileURL(forFileName: name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]),
                  values.isRegularFile == true else { continue }
            // The newest timestamp wins — buffered writes can leave an
            // untouched mtime on a file still being recorded.
            let newest = [values.contentModificationDate, values.creationDate].compactMap { $0 }.max()
            guard let newest, newest < cutoff else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }
}
