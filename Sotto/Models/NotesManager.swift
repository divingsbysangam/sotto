import Foundation
import Observation
import os

/// L7: one Scratchpad note. The first line is its title.
struct Note: Identifiable, Equatable {
    let id: UUID
    let created: Date
    var updated: Date
    var text: String
    var pinned: Bool

    init(id: UUID = UUID(), created: Date = Date(), updated: Date = Date(), text: String = "", pinned: Bool = false) {
        self.id = id
        self.created = created
        self.updated = updated
        self.text = text
        self.pinned = pinned
    }

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "New Note" : String(first.prefix(80))
    }

    /// `dictation` added on a new paragraph (or as the whole text of an empty note).
    static func appending(_ dictation: String, to text: String) -> String {
        let addition = dictation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return text }
        let existing = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return existing.isEmpty ? addition : existing + "\n\n" + addition
    }
}

/// L7: Scratchpad notes, stored locally in the history database (notes + notes_fts tables).
/// Main thread only.
@Observable
final class NotesManager {
    enum SaveState { case saved, pending, failed }
    private(set) var saveState: SaveState = .saved
    static let shared = NotesManager()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Notes")

    /// Pinned first, then most recently edited.
    private(set) var notes: [Note] = []
    /// The note shown in the Scratchpad, and the one dictation goes into.
    var selectedID: UUID?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var unsavedIDs: Set<UUID> = []

    init(store: HistoryStore? = TranscriptionHistoryManager.shared.notesStore) {
        self.store = store
        notes = store?.loadNotes() ?? []
        selectedID = notes.first?.id
    }

    var isPersistent: Bool { store != nil }

    func note(_ id: UUID?) -> Note? {
        id.flatMap { id in notes.first { $0.id == id } }
    }

    /// Search results (FTS), or every note for an empty query.
    func filtered(_ query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }
        if let ids = store?.searchNoteIDs(trimmed) {
            let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            return notes.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    @discardableResult
    func create() -> Note {
        let note = Note()
        notes.insert(note, at: firstUnpinnedIndex)
        selectedID = note.id
        persist(note)
        return note
    }

    /// The selected note, or the id a new note will get when the dictation's text arrives, so a
    /// cancelled or failed first dictation doesn't leave an empty note behind.
    func dictationTarget() -> UUID {
        if let selectedID, note(selectedID) != nil { return selectedID }
        return UUID()
    }

    /// Edits from the editor: kept in memory at once, saved after typing pauses.
    func setText(_ text: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        scheduleSave(id)
    }

    /// Dictation lands here: appended as a new paragraph and saved right away.
    @discardableResult func append(_ dictation: String, to id: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            // A new note (see dictationTarget), or the note was deleted while dictating.
            let note = Note(id: id, text: Note.appending(dictation, to: ""))
            notes.insert(note, at: firstUnpinnedIndex)
            selectedID = note.id
            return persist(note)
        }
        notes[index].text = Note.appending(dictation, to: notes[index].text)
        notes[index].updated = Date()
        let saved = saveNow(id)
        resort()
        Self.logger.notice("dictation added to note chars=\(dictation.count, privacy: .public)")
        return saved
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        saveNow(id)
        resort()
    }

    func delete(_ id: UUID) {
        pendingSaves.removeValue(forKey: id)?.cancel()
        unsavedIDs.remove(id)
        notes.removeAll { $0.id == id }
        store?.deleteNote(id: id)
        if selectedID == id { selectedID = notes.first?.id }
        saveState = unsavedIDs.isEmpty ? (pendingSaves.isEmpty ? .saved : .pending) : .failed
    }

    /// Writes any pending edits (window closing, app quitting).
    func flush() {
        for id in Set(pendingSaves.keys).union(unsavedIDs) { saveNow(id) }
    }

    private var firstUnpinnedIndex: Int {
        notes.firstIndex { !$0.pinned } ?? notes.count
    }

    private func scheduleSave(_ id: UUID) {
        saveState = .pending
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow(id) }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    @discardableResult private func saveNow(_ id: UUID) -> Bool {
        pendingSaves.removeValue(forKey: id)?.cancel()
        guard let note = note(id) else { return false }
        return persist(note)
    }

    @discardableResult private func persist(_ note: Note) -> Bool {
        let saved = store?.saveNote(note) ?? false
        if saved { unsavedIDs.remove(note.id) }
        else { unsavedIDs.insert(note.id) }
        saveState = unsavedIDs.isEmpty ? (pendingSaves.isEmpty ? .saved : .pending) : .failed
        return saved
    }

    private func resort() {
        notes.sort { a, b in a.pinned != b.pinned ? a.pinned : a.updated > b.updated }
    }
}
