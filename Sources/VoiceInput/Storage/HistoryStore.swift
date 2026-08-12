import Foundation

struct DictationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    /// Raw speech-recognition output.
    let rawText: String
    /// LLM-refined text, nil when refinement was disabled or failed.
    let refinedText: String?
    let wordCount: Int
    let language: String

    /// The text that was actually inserted.
    var finalText: String { refinedText ?? rawText }

    init(id: UUID = UUID(), date: Date, durationSeconds: Double, rawText: String, refinedText: String?, language: String) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.refinedText = refinedText
        self.wordCount = DictationRecord.countWords(rawText)
        self.language = language
    }

    /// Latin scripts: whitespace-separated words. CJK: non-whitespace characters.
    static func countWords(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let cjkCount = trimmed.unicodeScalars.filter { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||   // CJK unified
            (0x3400...0x4DBF).contains(scalar.value) ||   // CJK extension A
            (0x3040...0x30FF).contains(scalar.value) ||   // Hiragana + Katakana
            (0xAC00...0xD7AF).contains(scalar.value)      // Hangul syllables
        }.count
        if cjkCount > 0 {
            // CJK characters each count as a word; remaining Latin tokens count separately.
            let latinWords = trimmed.unicodeScalars
                .filter { !(0x4E00...0x9FFF).contains($0.value) && !(0x3400...0x4DBF).contains($0.value)
                    && !(0x3040...0x30FF).contains($0.value) && !(0xAC00...0xD7AF).contains($0.value) }
            let latinWordCount = String(String.UnicodeScalarView(latinWords))
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).count
            return cjkCount + latinWordCount
        }
        return trimmed.split(whereSeparator: \.isWhitespace).count
    }
}

/// Append-mostly JSON-backed store at ~/Library/Application Support/VoiceInput/history.json.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    private static let maxRecords = 5000

    @Published private(set) var records: [DictationRecord] = []  // newest first

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
    }

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        scheduleSave()
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearAll() {
        records.removeAll()
        scheduleSave()
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DictationRecord].self, from: data) else {
            return
        }
        records = decoded
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
        guard let data = try? JSONEncoder().encode(records) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.error("Failed to save history: \(error.localizedDescription)")
        }
    }
}
