import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    private var filtered: [DictationRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.records }
        return history.records.filter {
            $0.rawText.localizedCaseInsensitiveContains(query) ||
            ($0.refinedText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView {
                    Label("No History", systemImage: "clock")
                } description: {
                    Text("Your past dictations will appear here.")
                }
            } else {
                List(filtered) { record in
                    HistoryRow(record: record)
                        .contextMenu {
                            Button("Copy") { copy(record.finalText) }
                            Button("Delete", role: .destructive) {
                                history.delete(id: record.id)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search dictations")
        .toolbar {
            ToolbarItem {
                Button("Clear All", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(history.records.isEmpty)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                history.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all \(history.records.count) dictation records.")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct HistoryRow: View {
    let record: DictationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.finalText)
                .lineLimit(3)
            if let refined = record.refinedText, refined != record.rawText {
                Text(record.rawText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(record.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.1fs", record.durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(record.wordCount) words")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
