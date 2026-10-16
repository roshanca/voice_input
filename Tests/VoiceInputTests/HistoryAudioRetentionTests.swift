import XCTest
@testable import VoiceInput

/// Pure retention decision (#25): given a newest-first record list and a
/// cap, which clip file names must be deleted. The cap counts records that
/// carry a clip — records without audio consume no quota.
final class HistoryAudioRetentionTests: XCTestCase {
    private func record(audioFileName: String?) -> DictationRecord {
        DictationRecord(
            date: Date(), durationSeconds: 1,
            rawText: "x", refinedText: nil, outputText: "x",
            language: "en", audioFileName: audioFileName
        )
    }

    func testNoAudioNothingToDelete() {
        let records = [record(audioFileName: nil), record(audioFileName: nil)]
        XCTAssertTrue(HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: 2).isEmpty)
    }

    func testUnderCapKeepsEverything() {
        let records = [
            record(audioFileName: "a.caf"),
            record(audioFileName: "b.caf"),
            record(audioFileName: nil),
        ]
        XCTAssertTrue(HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: 2).isEmpty)
    }

    /// Newest-first ordering: the oldest clips beyond the cap are doomed,
    /// the newest survive.
    func testOverCapDeletesOldest() {
        let records = [
            record(audioFileName: "newest.caf"),
            record(audioFileName: "second.caf"),
            record(audioFileName: "third.caf"),
            record(audioFileName: "oldest.caf"),
        ]
        XCTAssertEqual(
            HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: 2),
            ["third.caf", "oldest.caf"]
        )
    }

    /// Records without clips don't consume quota — three audio-bearing
    /// records with a nil-audio record interleaved still keep the newest
    /// two clips.
    func testRecordsWithoutAudioDontConsumeQuota() {
        let records = [
            record(audioFileName: "one.caf"),
            record(audioFileName: nil),
            record(audioFileName: "two.caf"),
            record(audioFileName: nil),
            record(audioFileName: "three.caf"),
        ]
        XCTAssertEqual(
            HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: 2),
            ["three.caf"]
        )
    }

    func testZeroCapDeletesEverything() {
        let records = [
            record(audioFileName: "a.caf"),
            record(audioFileName: nil),
            record(audioFileName: "b.caf"),
        ]
        XCTAssertEqual(
            HistoryAudioRetention.fileNamesToDelete(records: records, keepNewest: 0),
            ["a.caf", "b.caf"]
        )
    }

    func testEmptyRecords() {
        XCTAssertTrue(HistoryAudioRetention.fileNamesToDelete(records: [], keepNewest: 100).isEmpty)
    }
}
