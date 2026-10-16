import Foundation

struct DictationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    /// Raw speech-recognition output, before dictionary replacement or LLM refinement.
    let rawText: String
    /// LLM-refined text, nil when refinement was disabled or failed.
    let refinedText: String?
    /// The text actually committed — injected into the target or parked for manual paste.
    let outputText: String
    let wordCount: Int
    let language: String
    /// Clip file name inside HistoryAudioStore's directory (`<id>.caf`).
    /// Nil for records predating audio capture, for sessions that produced
    /// no clip, and once retention prunes it — var so pruning can clear it.
    var audioFileName: String?

    init(id: UUID = UUID(), date: Date, durationSeconds: Double, rawText: String, refinedText: String?, outputText: String, language: String, audioFileName: String? = nil) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.rawText = rawText
        self.refinedText = refinedText
        self.outputText = outputText
        self.wordCount = DictationRecord.countWords(rawText)
        self.language = language
        self.audioFileName = audioFileName
    }

    /// Records written before `outputText` existed committed `refinedText ?? rawText`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        rawText = try container.decode(String.self, forKey: .rawText)
        refinedText = try container.decodeIfPresent(String.self, forKey: .refinedText)
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText) ?? refinedText ?? rawText
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? DictationRecord.countWords(rawText)
        language = try container.decode(String.self, forKey: .language)
        // Records written before audio capture decode to nil — the row
        // simply shows no playback control.
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
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
    /// Only the newest `maxAudioRecords` audio-bearing records keep their
    /// clip. Bounds disk at ~100 CAFs (~64 KB/s of 16 kHz Float32 PCM ≈
    /// tens of MB worst case) while retaining every recent clip.
    private static let maxAudioRecords = 100

    @Published private(set) var records: [DictationRecord] = []  // newest first

    private let audioStore = HistoryAudioStore.shared

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
        reconcileAudioFiles()
    }

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            // Records dropped by the record cap take their clips with them —
            // a record no longer in the store can never reference the file.
            for removed in records.suffix(from: Self.maxRecords) {
                if let name = removed.audioFileName {
                    audioStore.delete(fileName: name)
                }
            }
            records.removeLast(records.count - Self.maxRecords)
        }
        pruneAudio()
        scheduleSave()
    }

    func delete(id: UUID) {
        // The record's clip goes with its row — e.g. a delivery canceled by
        // Esc rolls back the record and must not leave the audio behind.
        let doomed = records.filter { $0.id == id }.compactMap(\.audioFileName)
        records.removeAll { $0.id == id }
        for name in doomed {
            audioStore.delete(fileName: name)
        }
        scheduleSave()
    }

    func clearAll() {
        records.removeAll()
        audioStore.deleteAll()
        scheduleSave()
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }

    // MARK: - Audio clips

    /// Newest-first cap on clips: audio survives only on the first
    /// `maxAudioRecords` records that carry one. Doomed files are deleted
    /// and their record's `audioFileName` cleared, so the row stops
    /// offering playback instead of pointing at a missing file.
    private func pruneAudio() {
        let doomed = HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: Self.maxAudioRecords)
        guard !doomed.isEmpty else { return }
        for name in doomed {
            audioStore.delete(fileName: name)
        }
        for index in records.indices where records[index].audioFileName.map(doomed.contains) == true {
            records[index].audioFileName = nil
        }
        scheduleSave()
    }

    /// Deletes clips no record references — leftovers from sessions killed
    /// mid-write — then applies the retention cap to records restored from
    /// disk. Init-only: later sweeps could race a live session's
    /// still-unreferenced clip.
    private func reconcileAudioFiles() {
        let referenced = Set(records.compactMap(\.audioFileName))
        for name in audioStore.audioFileNames() where !referenced.contains(name) {
            audioStore.delete(fileName: name)
        }
        pruneAudio()
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
