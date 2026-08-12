import SwiftUI

struct HomeView: View {
    @ObservedObject private var history = HistoryStore.shared

    private var summary: StatsSummary {
        StatsEngine.summarize(history.records)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Speak, don't type")
                    .font(.title2)
                    .fontWeight(.bold)

                if history.records.isEmpty {
                    ContentUnavailableView {
                        Label("Speak, don't type", systemImage: "waveform")
                    } description: {
                        Text("Hold Fn and start dictating — your stats will appear here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    statCards
                    streakCard
                }
            }
            .padding(24)
        }
    }

    // MARK: - Stat cards

    private var statCards: some View {
        let s = summary
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatCard(symbol: "clock", value: Self.formatHours(s.totalDuration), caption: "Total dictation time")
            StatCard(symbol: "mic", value: s.totalWords.formatted(.number.notation(.compactName)), caption: "Words dictated")
            StatCard(symbol: "hourglass", value: Self.formatHours(s.timeSaved), caption: "Time saved")
            StatCard(symbol: "bolt", value: "\(Int(s.averageWPM.rounded())) WPM", caption: "Average dictation speed")
        }
    }

    private static func formatHours(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 {
            return String(format: "%.1f hr", seconds / 3600)
        }
        return String(format: "%.0f min", seconds / 60)
    }

    // MARK: - Streaks + heatmap

    private var streakCard: some View {
        let s = summary
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                StreakItem(value: "\(s.activeDays)", caption: "Active days")
                Spacer()
                StreakItem(value: "\(s.currentStreak)", caption: "Current streak")
                Spacer()
                StreakItem(value: "\(s.longestStreak)", caption: "Longest streak")
            }
            .padding(.horizontal, 8)

            ContributionHeatmapView(dailyCounts: s.dailyCounts)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StatCard: View {
    let symbol: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 34, weight: .bold))
            Text(caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StreakItem: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// GitHub-style contribution grid: 7 rows (days) × N week columns, recent at right.
struct ContributionHeatmapView: View {
    let dailyCounts: [Date: Int]

    private static let weekCount = 26
    private static let cellSize: CGFloat = 12
    private static let spacing: CGFloat = 3

    private struct Week: Identifiable {
        let id: Int
        let start: Date
        let monthLabel: String
    }

    private var weeks: [Week] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(Self.weekCount - 1), to: thisWeekStart) else {
            return []
        }
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"

        var result: [Week] = []
        var previousMonth = -1
        for index in 0..<Self.weekCount {
            guard let start = calendar.date(byAdding: .weekOfYear, value: index, to: firstWeekStart) else { continue }
            let month = calendar.component(.month, from: start)
            let label = month != previousMonth ? monthFormatter.string(from: start) : ""
            previousMonth = month
            result.append(Week(id: index, start: start, monthLabel: label))
        }
        return result
    }

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(weeks) { week in
                    VStack(spacing: Self.spacing) {
                        // Zero-width frame: the label overflows to the right without
                        // widening the column; fixed height keeps columns aligned.
                        Text(week.monthLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: 0, height: 14, alignment: .leading)
                        ForEach(0..<7, id: \.self) { weekday in
                            cell(for: calendar.date(byAdding: .day, value: weekday, to: week.start), today: today)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([0.0, 0.3, 0.55, 0.8, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(opacity == 0 ? Color(nsColor: .separatorColor).opacity(0.35) : Color.accentColor.opacity(opacity))
                        .frame(width: Self.cellSize, height: Self.cellSize)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cell(for date: Date?, today: Date) -> some View {
        if let date, date <= today {
            let count = dailyCounts[Calendar.current.startOfDay(for: date)] ?? 0
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: count))
                .frame(width: Self.cellSize, height: Self.cellSize)
                .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(count) dictation\(count == 1 ? "" : "s")")
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(width: Self.cellSize, height: Self.cellSize)
        }
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: return Color(nsColor: .separatorColor).opacity(0.35)
        case 1: return Color.accentColor.opacity(0.3)
        case 2...3: return Color.accentColor.opacity(0.55)
        case 4...6: return Color.accentColor.opacity(0.8)
        default: return Color.accentColor
        }
    }
}
