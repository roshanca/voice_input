import XCTest
@testable import VoiceInput

final class StatsEngineTests: XCTestCase {
    private let now = Date()

    private func record(daysAgo: Int, wordCount: Int = 10, duration: Double = 60) -> DictationRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        let rawText = (0..<wordCount).map { "w\($0)" }.joined(separator: " ")
        return DictationRecord(date: date, durationSeconds: duration, rawText: rawText, refinedText: nil, outputText: rawText, language: "en-US")
    }

    func testEmptyRecordsProduceZeroSummary() {
        let summary = StatsEngine.summarize([], now: now)
        XCTAssertEqual(summary.totalDuration, 0)
        XCTAssertEqual(summary.totalWords, 0)
        XCTAssertEqual(summary.timeSaved, 0)
        XCTAssertEqual(summary.averageWPM, 0)
        XCTAssertEqual(summary.activeDays, 0)
        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 0)
        XCTAssertTrue(summary.dailyCounts.isEmpty)
    }

    func testTotalsAverageWPMAndTimeSaved() {
        // 80 words in 60s → 80 WPM; typing at 40 WPM would take 120s → 60s saved.
        let summary = StatsEngine.summarize([record(daysAgo: 0, wordCount: 80, duration: 60)], now: now)
        XCTAssertEqual(summary.totalWords, 80)
        XCTAssertEqual(summary.totalDuration, 60)
        XCTAssertEqual(summary.averageWPM, 80, accuracy: 0.001)
        XCTAssertEqual(summary.timeSaved, 60, accuracy: 0.001)
    }

    func testTimeSavedClampsAtZero() {
        // 10 words → 15s of typing at baseline, but dictation took an hour.
        let summary = StatsEngine.summarize([record(daysAgo: 0, wordCount: 10, duration: 3600)], now: now)
        XCTAssertEqual(summary.timeSaved, 0)
    }

    func testDailyCountsAndActiveDays() {
        let summary = StatsEngine.summarize([
            record(daysAgo: 0), record(daysAgo: 0), record(daysAgo: 2),
        ], now: now)
        XCTAssertEqual(summary.activeDays, 2)
        let today = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(summary.dailyCounts[today], 2)
        XCTAssertEqual(summary.dailyCounts.values.reduce(0, +), 3)
    }

    func testCurrentStreakIncludesToday() {
        let summary = StatsEngine.summarize([
            record(daysAgo: 0), record(daysAgo: 1), record(daysAgo: 2),
        ], now: now)
        XCTAssertEqual(summary.currentStreak, 3)
        XCTAssertEqual(summary.longestStreak, 3)
    }

    func testCurrentStreakStaysAliveFromYesterday() {
        // A streak whose last active day is yesterday is still alive.
        let summary = StatsEngine.summarize([record(daysAgo: 1), record(daysAgo: 2)], now: now)
        XCTAssertEqual(summary.currentStreak, 2)
        XCTAssertEqual(summary.longestStreak, 2)
    }

    func testCurrentStreakDiesWhenLastActiveDayIsOlderThanYesterday() {
        let summary = StatsEngine.summarize([
            record(daysAgo: 3), record(daysAgo: 4), record(daysAgo: 5),
        ], now: now)
        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 3)
    }

    func testLongestStreakTracksLongestHistoricalRun() {
        // A 4-day run in the past plus a live 2-day run.
        let summary = StatsEngine.summarize([
            record(daysAgo: 0), record(daysAgo: 1),
            record(daysAgo: 4), record(daysAgo: 5), record(daysAgo: 6), record(daysAgo: 7),
        ], now: now)
        XCTAssertEqual(summary.currentStreak, 2)
        XCTAssertEqual(summary.longestStreak, 4)
    }

    func testStreakGapsBreakRuns() {
        // Same-day repeats don't extend a run; a missing day splits it.
        let summary = StatsEngine.summarize([
            record(daysAgo: 0), record(daysAgo: 0), record(daysAgo: 2),
        ], now: now)
        XCTAssertEqual(summary.currentStreak, 1)
        XCTAssertEqual(summary.longestStreak, 1)
    }
}
