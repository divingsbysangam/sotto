import SwiftUI

struct HistoryTab: View {
    var appState: AppState
    @State private var historyManager = TranscriptionHistoryManager.shared
    @State private var searchText = ""
    @State var selectedID: UUID?
    @State private var detailEntry: TranscriptionEntry?
    @State private var confirmsClearAll = false

    private var filteredEntries: [TranscriptionEntry] { historyManager.search(searchText) }
    private var selectedEntry: TranscriptionEntry? { historyManager.entries.first { $0.id == selectedID } }
    private var visibleWordCount: Int {
        filteredEntries.reduce(0) { $0 + historyManager.wordCount(for: $1.text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            SottoPageHeader(title: "Transcripts",
                            subtitle: "\(historyManager.entries.count) transcripts · stored on this Mac") {
                EmptyView()
            }

            HStack(spacing: SottoDesign.spacing / 2) {
                HStack(spacing: SottoDesign.spacing / 2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcripts", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search transcripts")
                    if !searchText.isEmpty {
                        SottoIconButton(symbol: .close, label: "Clear search") { searchText = "" }
                    }
                }
                .padding(.horizontal, SottoDesign.spacing / 2)
                .frame(height: 32)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                selectionActions
            }

            transcriptList

            HStack {
                Text("\(filteredEntries.count) transcript\(filteredEntries.count == 1 ? "" : "s") · \(visibleWordCount) words")
                    .foregroundStyle(.secondary)
                Spacer()
                if !historyManager.entries.isEmpty {
                    Button("Clear All") { confirmsClearAll = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(SottoDesign.spacing)
        .background(SottoDesign.charcoal)
        .sheet(item: $detailEntry) { entry in
            TranscriptDetailView(entryID: entry.id, historyManager: historyManager, appState: appState)
        }
        .confirmationDialog("Delete all transcripts?", isPresented: $confirmsClearAll) {
            Button("Delete All Transcripts", role: .destructive) { historyManager.clearHistory() }
        } message: {
            Text("This removes every saved transcript from this Mac.")
        }
        .onChange(of: historyManager.entries) {
            if selectedEntry == nil { selectedID = nil }
        }
        .onChange(of: searchText) { selectedID = nil }
    }

    @ViewBuilder private var transcriptList: some View {
        if filteredEntries.isEmpty {
            SottoEmptyState(symbol: .transcripts,
                            title: searchText.isEmpty ? "No transcripts yet" : "No matching transcripts",
                            detail: searchText.isEmpty ? "Use your shortcut, or drop an audio or video recording here." : "Try another word or clear your search.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SottoDesign.cornerRadius))
        } else {
            VStack(spacing: 0) {
                Text("RECENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SottoDesign.spacing)
                    .padding(.top, SottoDesign.spacing / 2)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            transcriptRow(entry)
                            if entry.id != filteredEntries.last?.id {
                                Divider().padding(.horizontal, SottoDesign.spacing)
                            }
                        }
                    }
                    .padding(.horizontal, SottoDesign.spacing / 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SottoDesign.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: SottoDesign.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    private func transcriptRow(_ entry: TranscriptionEntry) -> some View {
        Button { selectedID = entry.id } label: {
            HStack(spacing: SottoDesign.spacing / 2) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(SottoDesign.cream.opacity(0.08))
                    .frame(width: 24, height: 24)
                    .overlay(Text(String((entry.sourceApp ?? "S").prefix(1))).font(.caption2.weight(.semibold)))
                    .accessibilityHidden(true)
                Text(entry.isFailed ? "Dictation needs attention" : entry.text.isEmpty ? "No transcript text" : entry.text)
                    .font(.caption)
                    .foregroundStyle(entry.isFailed ? SottoDesign.accent : SottoDesign.cream)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text([entry.sourceApp, entry.isFailed ? nil : "\(historyManager.wordCount(for: entry.text)) words"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(minWidth: 100, alignment: .trailing)
                Text(entry.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .trailing)
            }
            .padding(.horizontal, SottoDesign.spacing / 2)
            .padding(.vertical, SottoDesign.spacing / 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(selectedID == entry.id ? SottoDesign.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            TranscriptActions(entry: entry, historyManager: historyManager, appState: appState) { detailEntry = entry }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: SottoDesign.spacing / 2) {
            Button("Copy", systemImage: SottoSymbol.copy.rawValue) {
                if let entry = selectedEntry { appState.copyTranscript(entry.text) }
            }
            .disabled(selectedEntry == nil || selectedEntry?.isFailed == true)
            Button("Details", systemImage: SottoSymbol.details.rawValue) { detailEntry = selectedEntry }
                .disabled(selectedEntry == nil)
            Menu {
                if let entry = selectedEntry {
                    TranscriptActions(entry: entry, historyManager: historyManager, appState: appState) { detailEntry = entry }
                }
            } label: { Label("More", systemImage: SottoSymbol.more.rawValue) }
                .disabled(selectedEntry == nil)
        }
        .buttonStyle(.bordered)
        .tint(SottoDesign.cream.opacity(0.7))
    }
}
