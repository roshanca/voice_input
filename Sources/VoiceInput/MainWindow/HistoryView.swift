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
            $0.outputText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // No toolbar in this window (hidden titlebar) — header row hosts
            // the search field and Clear All button.
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                TextField("Search dictations", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Clear All", role: .destructive) {
                    showClearConfirmation = true
                }
                .disabled(history.records.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

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
                            Button("Copy") { copy(record.outputText) }
                            Button("Delete", role: .destructive) {
                                history.delete(id: record.id)
                            }
                        }
                }
                .listStyle(.inset)
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
            Text(record.outputText)
                .lineLimit(3)
            if record.outputText != record.rawText {
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
