import SwiftUI

struct HistoryView: View {
    @State private var historyManager = TranscriptionHistoryManager.shared
    @State private var searchText = ""
    @State private var selectedEntry: TranscriptionEntry?

    private var filteredEntries: [TranscriptionEntry] {
        historyManager.search(searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.bar)

            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView {
                    Label("No transcripts yet", systemImage: "waveform")
                } description: {
                    Text(searchText.isEmpty ? "Your transcripts will appear here" : "No results for \"\(searchText)\"")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedEntry) {
                    ForEach(filteredEntries) { entry in
                        HistoryRowView(entry: entry)
                            .tag(entry)
                            .contextMenu {
                                Button("Copy Text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    historyManager.deleteEntry(entry)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Footer
            HStack {
                Text("\(filteredEntries.count) transcript\(filteredEntries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !historyManager.entries.isEmpty {
                    Button("Clear All") {
                        historyManager.clearHistory()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.bar)
        }
        .frame(width: 400, height: 500)
    }
}

struct HistoryRowView: View {
    let entry: TranscriptionEntry
    var isReprocessing = false

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.timestamp, relativeTo: Date())
    }

    private var formattedDuration: String {
        let seconds = Int(entry.duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    private var outputIcon: String {
        switch entry.outputMethod {
        case .paste: return "doc.on.clipboard"
        case .clipboard: return "clipboard"
        case .imported: return "square.and.arrow.down"
        case .scratchpad: return "note.text"
        case .agentReply: return "arrowshape.turn.up.left"
        case .notPasted: return "tray"
        }
    }

    private var outputHelp: String {
        switch entry.outputMethod {
        case .paste: return "Auto-pasted"
        case .clipboard: return "Copied to clipboard"
        case .imported: return "Transcribed from a file"
        case .scratchpad: return "Dictated into the Scratchpad"
        case .agentReply: return "Sent to a coding agent"
        case .notPasted: return "Not pasted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main text
            if entry.isFailed {
                Label("Dictation failed: \(entry.failureReason ?? "unknown error")", systemImage: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(entry.text)
                    .font(.body)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }

            // Metadata row
            HStack(spacing: 12) {
                // Timestamp
                Label(formattedDate, systemImage: "clock")

                // Duration
                Label(formattedDuration, systemImage: "waveform")

                // Source app
                if let app = entry.sourceApp {
                    Label(app, systemImage: "app")
                }

                if entry.isShowingRaw {
                    Label("Raw", systemImage: "arrow.uturn.backward")
                        .help("AI edit undone: showing the raw transcript")
                }

                Spacer()

                if isReprocessing {
                    ProgressView()
                        .controlSize(.small)
                        .help("Re-processing…")
                }

                if entry.existingAudioURL != nil {
                    Image(systemName: "speaker.wave.2")
                        .help("Audio kept")
                }

                // Mode indicator
                Image(systemName: entry.transcriptionMode == .local ? "laptopcomputer" : "cloud")
                    .help(entry.transcriptionMode == .local ? "Local transcription" : "Cloud transcription")

                // Output method
                Image(systemName: outputIcon)
                    .help(outputHelp)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

/// Context-menu actions for a transcript.
struct TranscriptActions: View {
    let entry: TranscriptionEntry
    let historyManager: TranscriptionHistoryManager
    var appState: AppState? = nil
    let showDetails: () -> Void

    var body: some View {
        if let appState {
            if entry.existingAudioURL != nil {
                Button(entry.isFailed ? "Retry" : "Re-transcribe") {
                    Task { await appState.retranscribe(entry) }
                }
                .disabled(appState.reprocessingEntryID != nil)
            }
            if !entry.isFailed {
                Menu("Re-clean With") {
                    ForEach(appState.recleanChoices, id: \.label) { choice in
                        Button(choice.label) {
                            Task { await appState.reclean(entry, with: choice) }
                        }
                    }
                }
                .disabled(appState.reprocessingEntryID != nil)
            }
            Divider()
        }
        Button("Copy Text") {
            if let appState { appState.copyTranscript(entry.text) }
            else { copyToPasteboard(entry.text) }
        }.disabled(entry.isFailed || entry.text.isEmpty)
        ReadAloudButton(text: entry.text)
        if entry.hasAIEdit, let raw = entry.rawText {
            Button("Copy Raw Transcript") { copyToPasteboard(raw) }
            if entry.isShowingRaw {
                Button("Restore AI Edit") { historyManager.setShowsRaw(false, for: entry) }
            } else {
                Button("Undo AI Edit") { historyManager.setShowsRaw(true, for: entry) }
            }
        }
        Button(entry.hasAIEdit ? "View Raw & Details…" : "View Details…", action: showDetails)
        if let audio = entry.existingAudioURL {
            Divider()
            Button("Play Audio") { NSWorkspace.shared.open(audio) }
            Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
        }
        Divider()
        Button("Delete", role: .destructive) { historyManager.deleteEntry(entry) }
    }
}

/// Raw vs cleaned text, App Mode, per-stage timings, and kept audio for one transcript.
struct TranscriptDetailView: View {
    let entryID: UUID
    let historyManager: TranscriptionHistoryManager
    var appState: AppState? = nil
    @Environment(\.dismiss) private var dismiss

    /// Looked up live so Undo / Restore AI Edit show immediately.
    private var entry: TranscriptionEntry? {
        historyManager.entries.first { $0.id == entryID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let entry {
                content(for: entry)
            } else {
                Text("This transcript was deleted.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func content(for entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcript")
                .font(.title2)
                .fontWeight(.semibold)
            Text(metadata(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        textBlock(entry.isShowingRaw ? "In use (raw, AI edit undone)" : "In use", entry.text)
        ReadAloudButton(text: entry.text)

        if entry.hasAIEdit, let raw = entry.rawText, let cleaned = entry.cleanedText {
            textBlock(entry.isShowingRaw ? "AI-cleaned" : "Raw (before AI cleanup)", entry.isShowingRaw ? cleaned : raw)
            HStack {
                Button("Copy Raw") { copyToPasteboard(raw) }
                if entry.isShowingRaw {
                    Button("Restore AI Edit") { historyManager.setShowsRaw(false, for: entry) }
                } else {
                    Button("Undo AI Edit") { historyManager.setShowsRaw(true, for: entry) }
                }
            }
        } else if entry.rawText == nil {
            note("Raw text wasn't recorded for this transcript (made before Sotto kept it).")
        } else if entry.cleanedText == nil {
            note("AI Enhancement was off, so this is the raw transcript.")
        } else {
            note("AI cleanup didn't change this transcript.")
        }

        if let timings = entry.timings {
            VStack(alignment: .leading, spacing: 6) {
                Text("Timings")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    timingRow("Recording", timings.record)
                    timingRow("Transcribe", timings.transcribe)
                    if let cleanup = timings.cleanup {
                        timingRow("Cleanup", cleanup)
                    }
                    timingRow("Paste", timings.paste)
                    timingRow("After key-up", timings.transcribe + (timings.cleanup ?? 0) + timings.paste)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }

        if let audio = entry.existingAudioURL {
            HStack {
                Button("Play Audio") { NSWorkspace.shared.open(audio) }
                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                if let appState {
                    Button(entry.isFailed ? "Retry" : "Re-transcribe") {
                        Task { await appState.retranscribe(entry) }
                    }
                    .disabled(appState.reprocessingEntryID != nil)
                }
            }
        } else if entry.audioFileName != nil {
            note("The audio is no longer kept, so it can't be re-transcribed.")
        }

        if let appState, !entry.isFailed {
            HStack {
                Menu("Re-clean With") {
                    ForEach(appState.recleanChoices, id: \.label) { choice in
                        Button(choice.label) { Task { await appState.reclean(entry, with: choice) } }
                    }
                }
                .fixedSize()
                .disabled(appState.reprocessingEntryID != nil)
                if appState.reprocessingEntryID == entry.id {
                    ProgressView().controlSize(.small)
                }
            }
        }

        let versions = historyManager.versions(of: entry.id)
        if !versions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Earlier Versions")
                    .font(.headline)
                ForEach(versions) { version in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.text)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text("\(version.reason) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") { copyToPasteboard(version.text) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func metadata(for entry: TranscriptionEntry) -> String {
        var parts = [entry.timestamp.formatted(date: .abbreviated, time: .shortened)]
        if let app = entry.sourceApp { parts.append(app) }
        if let website = entry.sourceWebsite { parts.append(website) }
        parts.append(entry.modeName.map { "\($0) mode" } ?? "No App Mode")
        return parts.joined(separator: " · ")
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func timingRow(_ label: String, _ seconds: TimeInterval) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f s", seconds))
        }
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

#if DEBUG
#Preview { RedesignPrototype(destination: .transcripts) }
#endif

/// L13: "Read Aloud" that turns into "Stop Reading" while speech plays.
struct ReadAloudButton: View {
    let text: String
    private var speech: SpeechService { .shared }

    var body: some View {
        if speech.isSpeaking {
            Button("Stop Reading") { speech.stop() }
        } else {
            Button("Read Aloud") { speech.speak(text) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
