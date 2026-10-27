import SwiftUI
import AppKit

/// L7: the Scratchpad window. AppKit-owned so a hotkey can open it even when the main window
/// has never been shown (the app can run from the menu bar only).
final class ScratchpadWindowController: NSObject, NSWindowDelegate {
    static let shared = ScratchpadWindowController()

    private var window: NSWindow?

    /// The Scratchpad is the window the user is typing in: dictation goes into its note.
    var isKeyWindow: Bool { NSApp.isActive && window?.isKeyWindow == true }

    @MainActor
    func show(selecting id: UUID? = nil) {
        if window == nil, let appState = AppState.current {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Scratchpad"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ScratchpadView(appState: appState))
            window.setContentSize(NSSize(width: 760, height: 480))
            window.minSize = NSSize(width: 520, height: 320)
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("SottoScratchpad")
            self.window = window
        }
        if let id { NotesManager.shared.selectedID = id }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NotesManager.shared.flush()
    }
}

struct ScratchpadView: View {
    var appState: AppState

    @State private var search = ""
    private var notes: NotesManager { .shared }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
        } detail: {
            editor
                .frame(minWidth: 300)
        }
        .tint(SottoDesign.accent)
        .toolbar {
            ToolbarItemGroup {
                Button("New Note", systemImage: "square.and.pencil") { search = ""; notes.create() }
                    .help("Create a note")
                dictateButton
                Button("Copy Note", systemImage: SottoSymbol.copy.rawValue) {
                    if let note = notes.note(notes.selectedID) { copy(note.text) }
                }.disabled(notes.note(notes.selectedID) == nil).help("Copy note")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search notes", text: $search)
                    .textFieldStyle(.plain)
                Button {
                    search = ""
                    notes.create()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New Note")
                .accessibilityLabel("New note")
            }
            .padding(8)

            Divider()

            let shown = notes.filtered(search)
            if shown.isEmpty {
                Text(search.isEmpty ? "No notes yet" : "No matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { notes.selectedID }, set: { notes.selectedID = $0 })) {
                    ForEach(shown) { note in
                        row(note)
                            .tag(note.id)
                            .contextMenu {
                                Button(note.pinned ? "Unpin" : "Pin") { notes.togglePin(note.id) }
                                Button("Copy") { copy(note.text) }
                                Divider()
                                Button("Delete", role: .destructive) { notes.delete(note.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func row(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text(note.title)
                    .lineLimit(1)
            }
            Text(note.updated.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let note = notes.note(notes.selectedID) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        notes.togglePin(note.id)
                    } label: {
                        Image(systemName: note.pinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(note.pinned ? "Unpin" : "Pin")
                    .accessibilityLabel(note.pinned ? "Unpin note" : "Pin note")
                    Button {
                        copy(note.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Note")
                    .accessibilityLabel("Copy note")
                    Button {
                        notes.delete(note.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete Note")
                    .accessibilityLabel("Delete note")
                }
                .padding(8)

                Divider()

                TextEditor(text: Binding(
                    get: { notes.note(note.id)?.text ?? "" },
                    set: { notes.setText($0, for: note.id) }
                ))
                .font(.body)
                .sottoEditor()
                .padding(12)
                .accessibilityLabel("Note text")
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Think out loud")
                    .font(.headline)
                Text("Dictate into a note instead of an app. Press \(AppSettings.shared.scratchpadDisplayName) anywhere, or your dictation shortcut while this window is in front.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("New Note") { notes.create() }
                    .sottoPrimaryAction()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isDictatingHere: Bool { appState.isScratchpadDictation }

    private var dictateButton: some View {
        Button {
            appState.toggleScratchpadDictation()
        } label: {
            Label(isDictatingHere && appState.isRecording ? "Stop" : "Dictate",
                  systemImage: isDictatingHere && appState.isRecording ? "stop.circle.fill" : "mic.fill")
        }
        .disabled(appState.isProcessing || (appState.isRecording && !isDictatingHere))
    }

    private var statusText: String {
        if isDictatingHere && appState.isRecording { return "Listening… press again (or your dictation key) to stop" }
        if isDictatingHere && appState.isProcessing { return appState.processingStatus.isEmpty ? "Transcribing…" : appState.processingStatus }
        switch notes.saveState {
        case .saved: return "Saved on this Mac · Dictation is added at the end"
        case .pending: return "Saving…"
        case .failed: return "Could not save. Copy this note before quitting."
        }
    }

    private func copy(_ text: String) {
        appState.copyTranscript(text)
    }
}
