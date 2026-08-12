import SwiftUI

struct DictionaryView: View {
    @ObservedObject private var store = DictionaryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var term = ""
    @State private var replacement = ""
    @State private var reading = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle(isOn: $settings.dictionaryDirectReplacement) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apply replacements directly")
                            Text("Replace terms in the recognized text even before LLM refinement.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextField("Term (as misrecognized or intended)", text: $term)
                    TextField("Replacement (optional)", text: $replacement)
                    TextField("Reading hint (optional)", text: $reading)
                } header: {
                    Text("Add Entry")
                } footer: {
                    Text("Terms are added to the LLM prompt as preferred vocabulary. With a replacement set, the text is also corrected directly after recognition.")
                }
            }
            .formStyle(.grouped)
            .frame(height: 280)

            HStack {
                Spacer()
                Button("Add") {
                    let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTerm.isEmpty else { return }
                    let entry = DictionaryEntry(
                        term: trimmedTerm,
                        replacement: readingOrNil(replacement),
                        reading: readingOrNil(reading)
                    )
                    store.add(entry)
                    term = ""
                    replacement = ""
                    reading = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Entries", systemImage: "character.book.closed")
                } description: {
                    Text("Add names, jargon, or homophone-prone words to improve recognition.")
                }
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HStack {
                            Text(entry.term)
                                .fontWeight(.medium)
                            if let replacement = entry.replacement {
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(replacement)
                            }
                            if let reading = entry.reading {
                                Text("(\(reading))")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                store.delete(id: entry.id)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.delete(id: store.entries[index].id)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Dictionary")
    }

    private func readingOrNil(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
