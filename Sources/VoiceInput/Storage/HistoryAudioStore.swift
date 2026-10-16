import Foundation

/// Filesystem home for recorded dictation audio: one CAF clip per session
/// under `Application Support/VoiceInput/History Audio/`, named
/// `<sessionID>.caf`. The session id doubles as the record id, so a
/// record's `audioFileName` field links file ↔ record by convention — no
/// lookup table. Stateless path math + FileManager calls; the directory is
/// injectable so tests can point the store at a temp dir instead of the
/// app's real data.
final class HistoryAudioStore {
    static let shared = HistoryAudioStore()

    /// Also the extension clips are filtered by everywhere — a clip is by
    /// definition a `.caf` in this directory.
    static let clipExtension = "caf"

    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceInput", isDirectory: true)
            .appendingPathComponent("History Audio", isDirectory: true)
    }

    /// Pure mapping — session/record id → clip file name. Static so the
    /// convention is usable without a store instance.
    static func fileName(forSessionID id: UUID) -> String {
        "\(id.uuidString).\(clipExtension)"
    }

    func fileURL(forSessionID id: UUID) -> URL {
        fileURL(forFileName: Self.fileName(forSessionID: id))
    }

    /// Only the last path component is honored: a stored or handed-in name
    /// must never let a delete/write escape the audio directory.
    func fileURL(forFileName name: String) -> URL {
        directoryURL.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// The session's clip name when a file is actually on disk — nil when
    /// the session captured nothing (writer failed, canceled, or produced
    /// an empty file that finish() already removed). `recordHistory` uses
    /// this so a record only claims audio that exists.
    func existingFileName(forSessionID id: UUID) -> String? {
        let name = Self.fileName(forSessionID: id)
        return FileManager.default.fileExists(atPath: fileURL(forFileName: name).path) ? name : nil
    }

    /// Clip names currently in the directory — reconciliation input for the
    /// launch-time orphan sweep.
    func audioFileNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return contents.filter { $0.hasSuffix(".\(Self.clipExtension)") }
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(forFileName: fileName))
    }

    func deleteAudio(forSessionID id: UUID) {
        delete(fileName: Self.fileName(forSessionID: id))
    }

    /// Clears every clip — used by History's clear-all so disk state matches
    /// the emptied record list. Only `.<clipExtension>` files are touched.
    func deleteAll() {
        for name in audioFileNames() {
            delete(fileName: name)
        }
    }
}
