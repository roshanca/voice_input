import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    /// The word or phrase the recognizer tends to get wrong / should recognize.
    var term: String
    /// If set: direct text replacement AND the preferred form hint for the LLM.
    var replacement: String?
    /// Optional pronunciation hint, used as LLM context only.
    var reading: String?

    init(id: UUID = UUID(), term: String, replacement: String? = nil, reading: String? = nil) {
        self.id = id
        self.term = term
        self.replacement = replacement
        self.reading = reading
    }
}

/// JSON-backed custom vocabulary at ~/Library/Application Support/VoiceInput/dictionary.json.
@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }()

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
    }

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        scheduleSave()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        scheduleSave()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Pipeline integration

    /// Appended to the LLM system prompt when entries exist.
    func promptFragment() -> String {
        DictionaryRules.promptFragment(entries: entries)
    }

    /// Literal case-insensitive term → replacement applied to raw ASR text.
    func applyReplacements(to text: String) -> String {
        DictionaryRules.applyReplacements(to: text, entries: entries)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.error("Failed to save dictionary: \(error.localizedDescription)")
        }
    }
}

/// Pure matching/formatting rules over dictionary entries, kept separate from
/// the persisted store so they can be exercised without touching disk.
enum DictionaryRules {
    /// Appended to the LLM system prompt when entries exist.
    static func promptFragment(entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var lines = ["", "Custom vocabulary (prefer these exact forms when the audio suggests them):"]
        for entry in entries {
            var line = "- \(entry.term)"
            if let replacement = entry.replacement, !replacement.isEmpty, replacement != entry.term {
                line += " → \(replacement)"
            }
            if let reading = entry.reading, !reading.isEmpty {
                line += " (reading: \(reading))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Literal case-insensitive term → replacement applied to raw ASR text.
    static func applyReplacements(to text: String, entries: [DictionaryEntry]) -> String {
        var result = text
        for entry in entries {
            guard let replacement = entry.replacement, !replacement.isEmpty, replacement != entry.term else { continue }
            result = result.replacingOccurrences(of: entry.term, with: replacement, options: .caseInsensitive)
        }
        return result
    }
}
