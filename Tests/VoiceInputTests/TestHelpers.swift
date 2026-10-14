import Foundation

/// Unique UserDefaults suite so tests never touch the app's real preferences.
/// The persistent domain is removed from disk on deinit.
final class IsolatedDefaults {
    let defaults: UserDefaults
    let suiteName: String

    init() {
        suiteName = "VoiceInputTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Unique temporary directory for file-backed tests, removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
