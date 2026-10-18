import Foundation

/// Why a recording could not be created or the directory rejected.
enum RecordingTempStoreError: LocalizedError, Equatable {
    /// The directory is a symlink, not a directory, or owned by someone
    /// else — or a path resolved outside the pinned directory: the store
    /// refuses to act on anything it can't prove is inside.
    case insecureDirectory
    /// mkdir/open/rename failed (carries errno for diagnostics).
    case directoryUnavailable(Int32)
    /// The recording file's exclusive lock is held — a live session owns
    /// it (only possible on a name collision).
    case recordingLocked

    var errorDescription: String? {
        switch self {
        case .insecureDirectory:
            return "Recording directory failed security checks"
        case .directoryUnavailable(let code):
            return "Recording directory unavailable (errno \(code))"
        case .recordingLocked:
            return "Recording is locked by another session"
        }
    }
}

/// Filesystem home for remote-ASR upload recordings: one WAV per session
/// under `NSTemporaryDirectory()/VoiceInput-ASR/`, named
/// `voiceinput-asr-<sessionID>.wav`. A dedicated directory — not the shared
/// temp root — so the launch sweep owns everything matching its naming
/// convention, created 0700 because it holds raw microphone audio.
///
/// Security contract (#35): the directory is opened once with
/// O_NOFOLLOW|O_DIRECTORY and validated (real directory, owned by us,
/// mode repaired to 0700). open/openat are variadic and invisible to
/// Swift, so "fd-relative" is enforced by construction instead: stat and
/// delete run through fstatat/unlinkat on the pinned directory
/// descriptor, file creation goes through mkstemp+renameat inside it,
/// and every path-opened fd must verify as the same inode the directory
/// binds — a swapped path can never redirect a write or a delete.
/// Each recording is held under an exclusive flock for the writer's
/// lifetime; the sweep deletes a candidate only after taking the same
/// lock non-blockingly, which is what proves no live session still owns
/// the file — age is only a secondary gate.
///
/// The writer carries that verified inode end-to-end: AVAudioFile opens
/// `/dev/fd/<lockFD>` (vnode-bound, no directory-path resolution) for
/// writes and the upload reads the same descriptor path, while deletion
/// goes through `removeRecordingFile`'s inode-checked `unlinkat`. A
/// directory rename or a planted lookalike can neither pull audio out
/// of the pinned dir nor make cleanup unlink the wrong file.
final class RecordingTempStore {
    static let shared = RecordingTempStore()

    /// Both halves of the naming convention sweeps match on — a recording
    /// is by definition `voiceinput-asr-<uuid>.wav`.
    static let filePrefix = "voiceinput-asr-"
    static let fileExtension = "wav"

    /// Launch sweeps remove only recordings older than this — a secondary
    /// condition on top of the lock check, guarding files whose holder
    /// died without unlinking (crash, kill, process suspended past it).
    static let orphanMaxAge: TimeInterval = 60 * 60

    /// Owner-only — temp roots are per-user, but explicit permissions make
    /// the privacy guarantee independent of umask and inherited modes.
    static let directoryPermissions: mode_t = 0o700
    /// mkstemp creates recordings 0600 already; documented for callers.
    static let filePermissions: Int32 = 0o600

    let directoryURL: URL
    /// Where builds before #35 leaked recordings: the shared temp root
    /// itself. Swept with the same strict checks so upgrades clean up
    /// after the old code.
    let legacyDirectoryURL: URL

    /// Validated directory descriptor, opened on first ensure and held for
    /// the store's life — every subsequent file op is relative to it.
    private var dirFD: Int32 = -1

    init(directoryURL: URL? = nil, legacyDirectoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInput-ASR", isDirectory: true)
        self.legacyDirectoryURL = legacyDirectoryURL ?? FileManager.default.temporaryDirectory
    }

    deinit {
        if dirFD >= 0 { close(dirFD) }
    }

    /// Pure mapping — session id → recording file name. Static so the
    /// convention is usable without a store instance.
    static func fileName(forSessionID id: UUID) -> String {
        "\(filePrefix)\(id.uuidString).\(fileExtension)"
    }

    /// Full convention check for sweep eligibility: prefix + extension AND
    /// a real UUID in between — `voiceinput-asr-notes.wav` is not ours.
    static func isRecordingFileName(_ name: String) -> Bool {
        guard name.hasPrefix(filePrefix), name.hasSuffix(".\(fileExtension)") else { return false }
        let middle = name.dropFirst(filePrefix.count).dropLast(fileExtension.count + 1)
        return UUID(uuidString: String(middle)) != nil
    }

    func fileURL(forSessionID id: UUID) -> URL {
        directoryURL.appendingPathComponent(Self.fileName(forSessionID: id))
    }

    /// Creates or validates the recording directory and returns its fd for
    /// relative operations. A symlink (O_NOFOLLOW), non-directory, foreign
    /// owner, or a mode that can't be tightened to 0700 is rejected —
    /// recording fails honestly rather than writing audio somewhere else.
    @discardableResult
    func ensureDirectory() throws -> Int32 {
        if dirFD >= 0 { return dirFD }
        if mkdir(directoryURL.path, Self.directoryPermissions) != 0, errno != EEXIST {
            throw RecordingTempStoreError.directoryUnavailable(errno)
        }
        let fd = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            // ELOOP: the path is a symlink — refused. ENOTDIR: a symlink
            // or a plain file where a directory is required (macOS reports
            // the O_DIRECTORY mismatch before the link is even followed).
            throw errno == ELOOP || errno == ENOTDIR
                ? RecordingTempStoreError.insecureDirectory
                : .directoryUnavailable(errno)
        }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else {
            close(fd)
            throw RecordingTempStoreError.insecureDirectory
        }
        if st.st_mode & 0o777 != Self.directoryPermissions, fchmod(fd, Self.directoryPermissions) != 0 {
            close(fd)
            throw RecordingTempStoreError.insecureDirectory
        }
        dirFD = fd
        return fd
    }

    /// Creates the session's recording inside the validated directory and
    /// returns an fd holding it under an exclusive flock — released when
    /// the fd closes or the process dies, which is exactly the signal the
    /// sweep uses to tell orphans from live captures.
    func openRecordingFileDescriptor(forSessionID id: UUID) throws -> Int32 {
        let directory = try ensureDirectory()
        let name = Self.fileName(forSessionID: id)
        let path = "\(livePath(forDirectoryFD: directory, fallback: directoryURL))/\(name)"

        // File already there: open without following a planted symlink,
        // then prove it is the same regular inode the pinned directory
        // binds under `name` before locking it.
        let existing = open(path, O_RDWR | O_NOFOLLOW)
        if existing >= 0 {
            do {
                try verifySameFile(directoryFD: directory, name: name, fd: existing)
            } catch {
                close(existing)
                throw error
            }
            guard flock(existing, LOCK_EX | LOCK_NB) == 0 else {
                close(existing)
                throw RecordingTempStoreError.recordingLocked
            }
            return existing
        }

        let openError = errno
        if openError == ELOOP {
            // A symlink at `name`: remove the link fd-relatively, then
            // fall through to create. Anything else that made open fail
            // with ELOOP is rejected.
            var st = stat()
            guard fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  (st.st_mode & S_IFMT) == S_IFLNK else {
                throw RecordingTempStoreError.insecureDirectory
            }
            unlinkat(directory, name, 0)
        } else if openError != ENOENT {
            throw RecordingTempStoreError.directoryUnavailable(openError)
        }

        // Create fd-relatively: mkstemp inside the pinned directory (a
        // fresh, unguessable name no symlink can be planted at) then
        // renameat onto `name` — the create lands inside the validated
        // inode no matter what the target name currently binds.
        var template = "\(livePath(forDirectoryFD: directory, fallback: directoryURL))/.viasr-create-XXXXXX".utf8CString
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw RecordingTempStoreError.directoryUnavailable(errno) }
        let tmpName = template.withUnsafeBufferPointer {
            (String(cString: $0.baseAddress!) as NSString).lastPathComponent
        }
        guard renameat(directory, tmpName, directory, name) == 0 else {
            let code = errno
            close(fd)
            unlinkat(directory, tmpName, 0)
            throw RecordingTempStoreError.directoryUnavailable(code)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            unlinkat(directory, name, 0)
            throw RecordingTempStoreError.recordingLocked
        }
        return fd
    }

    /// Unlinks `name` from the pinned directory — only while `name` still
    /// binds the exact inode `lockedFD` is open on. A planted replacement
    /// at that name (different inode, symlink, or missing) fails the match
    /// and is left alone: deleting it would unlink somebody else's file
    /// while the real recording stays behind.
    @discardableResult
    func removeRecordingFile(named name: String, lockedFD: Int32) -> Bool {
        guard dirFD >= 0 else { return false }
        var want = stat()
        var have = stat()
        guard fstat(lockedFD, &want) == 0,
              fstatat(dirFD, name, &have, AT_SYMLINK_NOFOLLOW) == 0,
              (have.st_mode & S_IFMT) == S_IFREG,
              want.st_dev == have.st_dev,
              want.st_ino == have.st_ino else {
            return false
        }
        return unlinkat(dirFD, name, 0) == 0
    }

    /// Deletes recordings orphaned by a previous process — crash, kill, or
    /// an exit path that predates terminate-time discard — from both the
    /// dedicated directory and the pre-#35 legacy location (the temp root
    /// itself). Returns how many files were removed. A candidate is
    /// deleted only when every check passes: strict naming with a real
    /// UUID, a non-symlink regular file, older than `maxAge`, and — the
    /// decisive one — its flock free for the taking: a live session holds
    /// it, so failure to lock means the file is still owned and skipped.
    @discardableResult
    func sweepOrphans(now: Date = Date(), maxAge: TimeInterval = RecordingTempStore.orphanMaxAge) -> Int {
        let cutoff = now.addingTimeInterval(-maxAge)
        var removed = 0
        for url in [directoryURL, legacyDirectoryURL] {
            if let fd = openExistingDirectory(url) {
                removed += sweep(directoryFD: fd, directory: url, names: recordingFileNames(in: url), cutoff: cutoff)
                close(fd)
            }
        }
        return removed
    }

    /// Names under `directory` matching the full recording convention —
    /// listing only; every name is re-validated under the directory fd
    /// before anything happens to it.
    private func recordingFileNames(in directory: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter(Self.isRecordingFileName)
    }

    /// Opens a directory only if it is a real directory owned by this
    /// user — a symlink at the path fails O_NOFOLLOW and returns nil, so
    /// neither the sweep nor anything else ever works through it.
    private func openExistingDirectory(_ url: URL) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else {
            close(fd)
            return nil
        }
        return fd
    }

    /// fd-relative sweep of one directory: stat and delete run through
    /// fstatat/unlinkat against the pinned directory descriptor, and the
    /// delete only ever touches a convention-named entry inside it.
    private func sweep(directoryFD: Int32, directory: URL, names: [String], cutoff: Date) -> Int {
        let dirPath = livePath(forDirectoryFD: directoryFD, fallback: directory)
        var removed = 0
        for name in names {
            var st = stat()
            guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG else { continue }

            // Age gate (secondary): the newest timestamp decides, so a
            // just-created file is never mistaken for an orphan.
            let newest = max(Self.date(from: st.st_mtimespec), Self.date(from: st.st_birthtimespec))
            guard newest < cutoff else { continue }

            // openat is variadic — invisible to Swift — so the file is
            // opened by path, then REQUIRED to be the same inode fstatat
            // reports inside the pinned directory. A path that resolved
            // anywhere else fails the match before the lock is tried.
            let fd = open("\(dirPath)/\(name)", O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }

            // Ownership check (decisive): a live capture holds an
            // exclusive flock; not getting it non-blockingly means the
            // file still belongs to a session — even an expired one.
            guard (try? verifySameFile(directoryFD: directoryFD, name: name, fd: fd)) != nil,
                  flock(fd, LOCK_EX | LOCK_NB) == 0,
                  unlinkat(directoryFD, name, 0) == 0 else { continue }
            removed += 1
        }
        return removed
    }

    /// The fd `open` reached must be the same regular-file inode `name`
    /// binds inside the pinned directory — otherwise the path was swapped
    /// between resolution and open, and the caller must not act on it.
    private func verifySameFile(directoryFD: Int32, name: String, fd: Int32) throws {
        var expected = stat()
        var actual = stat()
        guard fstatat(directoryFD, name, &expected, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(fd, &actual) == 0,
              (expected.st_mode & S_IFMT) == S_IFREG,
              (actual.st_mode & S_IFMT) == S_IFREG,
              expected.st_dev == actual.st_dev,
              expected.st_ino == actual.st_ino else {
            throw RecordingTempStoreError.insecureDirectory
        }
    }

    /// The pinned directory's live path: F_GETPATH follows the inode
    /// wherever it moved, so opens land in the directory we validated
    /// rather than whatever the original path now binds. Falls back to
    /// the URL path when the fcntl is unavailable.
    private func livePath(forDirectoryFD fd: Int32, fallback: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return fallback.path }
        return String(cString: buffer)
    }

    private static func date(from ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
    }
}
