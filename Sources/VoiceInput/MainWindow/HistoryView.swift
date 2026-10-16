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
                                // Deleting the row removes its clip from
                                // disk; stop playback first so the player
                                // isn't left holding a deleted file.
                                HistoryAudioPlayer.shared.stopIfPlaying(fileName: record.audioFileName)
                                history.delete(id: record.id)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $showClearConfirmation) {
            Button("Clear All", role: .destructive) {
                HistoryAudioPlayer.shared.stop()
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
    /// Shared single-slot player — the row only needs to know whether ITS
    /// clip is the one currently loaded and playing.
    @ObservedObject private var audioPlayer = HistoryAudioPlayer.shared

    private var isPlayingThis: Bool {
        audioPlayer.isPlaying && audioPlayer.playingFileName == record.audioFileName
    }

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
                // Records predating audio capture (or sessions that captured
                // none) have no clip — no button, same look as before.
                if let audioFileName = record.audioFileName {
                    Button {
                        audioPlayer.toggle(fileName: audioFileName)
                    } label: {
                        Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(isPlayingThis ? "Pause recording" : "Play recording")
                }
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
