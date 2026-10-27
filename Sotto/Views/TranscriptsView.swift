import SwiftUI

struct HistoryTab: View {
    var appState: AppState
    @State private var historyManager = TranscriptionHistoryManager.shared
    @State private var searchText = ""
    @State var selectedID: UUID?
    @State private var detailEntry: TranscriptionEntry?

    private var filteredEntries: [TranscriptionEntry] { historyManager.search(searchText) }
    private var selectedEntry: TranscriptionEntry? { historyManager.entries.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcripts", text: $searchText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search transcripts")
                if !searchText.isEmpty { SottoIconButton(symbol: .close, label: "Clear search") { searchText = "" } }
            }.padding(12)
            selectionActions.padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            if filteredEntries.isEmpty {
                SottoEmptyState(symbol: .transcripts,
                                title: searchText.isEmpty ? "No transcripts yet" : "No matching transcripts",
                                detail: searchText.isEmpty ? "Use your shortcut, or drop an audio or video recording here." : "Try another word or clear your search.")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HistoryRowView(entry: entry, isReprocessing: appState.reprocessingEntryID == entry.id)
                            if entry.isFailed, entry.existingAudioURL != nil {
                                Button("Retry", systemImage: SottoSymbol.retry.rawValue) {
                                    Task { await appState.retranscribe(entry) }
                                }
                                .disabled(appState.reprocessingEntryID != nil || appState.recordingState != .idle)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(entry.id)
                        .contextMenu {
                            TranscriptActions(entry: entry, historyManager: historyManager, appState: appState) { detailEntry = entry }
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text("\(filteredEntries.count) transcript\(filteredEntries.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                if !historyManager.entries.isEmpty {
                    Button("Clear All", role: .destructive) { historyManager.clearHistory() }
                }
            }.font(.caption).padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Transcripts")
        .sheet(item: $detailEntry) { entry in
            TranscriptDetailView(entryID: entry.id, historyManager: historyManager, appState: appState)
        }
        .onChange(of: historyManager.entries) {
            if selectedEntry == nil { selectedID = nil }
        }
        .onChange(of: searchText) { selectedID = nil }
    }

    private var selectionActions: some View {
        HStack(spacing: 12) {
            Button("Copy", systemImage: SottoSymbol.copy.rawValue) {
                if let entry = selectedEntry { appState.copyTranscript(entry.text) }
            }.disabled(selectedEntry == nil || selectedEntry?.isFailed == true)
            Button("Details", systemImage: SottoSymbol.details.rawValue) { detailEntry = selectedEntry }
                .disabled(selectedEntry == nil)
            Menu {
                if let entry = selectedEntry {
                    TranscriptActions(entry: entry, historyManager: historyManager, appState: appState) { detailEntry = entry }
                }
            } label: { Label("More", systemImage: SottoSymbol.more.rawValue) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selectedEntry == nil)
                .help("More transcript actions")
            Spacer(minLength: 0)
        }
    }
}
