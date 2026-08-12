import Foundation

struct StatsSummary {
    let totalDuration: TimeInterval
    let totalWords: Int
    /// Estimated time saved vs. typing at the baseline WPM.
    let timeSaved: TimeInterval
    let averageWPM: Double
    let activeDays: Int
    let currentStreak: Int
    let longestStreak: Int
    /// Day (startOfDay) → number of dictation sessions, for the heatmap.
    let dailyCounts: [Date: Int]
}

/// Pure aggregation over dictation records.
enum StatsEngine {
    /// Assumed typing speed used for the "time saved" estimate.
    static let typingBaselineWPM = 40.0

    static func summarize(_ records: [DictationRecord], now: Date = Date()) -> StatsSummary {
        let calendar = Calendar.current

        let totalDuration = records.reduce(0) { $0 + $1.durationSeconds }
        let totalWords = records.reduce(0) { $0 + $1.wordCount }

        let typingSeconds = Double(totalWords) / typingBaselineWPM * 60
        let timeSaved = max(0, typingSeconds - totalDuration)

        let averageWPM = totalDuration > 0 ? Double(totalWords) / (totalDuration / 60) : 0

        var dailyCounts: [Date: Int] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            dailyCounts[day, default: 0] += 1
        }

        let activeDays = dailyCounts.count

        // Streaks: walk consecutive day runs ending today/yesterday (current)
        // and over all history (longest).
        let days = dailyCounts.keys.sorted()
        var longestStreak = 0
        var runLength = 0
        var previousDay: Date?
        for day in days {
            if let previous = previousDay,
               calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                runLength += 1
            } else {
                runLength = 1
            }
            longestStreak = max(longestStreak, runLength)
            previousDay = day
        }

        var currentStreak = 0
        let today = calendar.startOfDay(for: now)
        // A streak is alive if the most recent active day is today or yesterday.
        if let lastDay = days.last {
            let gap = calendar.dateComponents([.day], from: lastDay, to: today).day ?? .max
            if gap <= 1 {
                currentStreak = runLength  // runLength ends at the most recent active day
            }
        }

        return StatsSummary(
            totalDuration: totalDuration,
            totalWords: totalWords,
            timeSaved: timeSaved,
            averageWPM: averageWPM,
            activeDays: activeDays,
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            dailyCounts: dailyCounts
        )
    }
}
