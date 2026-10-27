import Foundation
import SQLite3
import os

/// SQLite storage for transcript history (N8), using the system libsqlite3 (no package).
/// - `transcripts`: one row per entry.
/// - `transcripts_fts`: FTS5 index over the text columns, kept in sync by triggers.
/// - `transcript_versions`: earlier results of re-transcribed / re-cleaned entries (N2).
/// Deleting a transcript cascades to every derived table (foreign keys + triggers), so no
/// orphaned rows are left behind. Main thread only.
final class HistoryStore {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "HistoryStore")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    struct Version: Identifiable {
        let id: Int64
        let createdAt: Date
        let text: String
        let reason: String
    }

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            Self.logger.error("could not open history database")
            sqlite3_close(db)
            return nil
        }
        let schema = """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS transcripts (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,  -- seconds since 2001 (Date's own reference), exact round trip
                text TEXT NOT NULL,
                raw_text TEXT,
                cleaned_text TEXT,
                duration REAL NOT NULL,
                source_app TEXT,
                window_title TEXT,
                source_website TEXT,
                output_method TEXT NOT NULL,
                transcription_mode TEXT NOT NULL,
                mode_name TEXT,
                timings TEXT,
                audio_file_name TEXT,
                failure_reason TEXT
            );
            CREATE INDEX IF NOT EXISTS transcripts_timestamp ON transcripts(timestamp);
            CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                text, raw_text, source_app, window_title, source_website,
                content='transcripts', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
                INSERT INTO transcripts_fts(rowid, text, raw_text, source_app, window_title, source_website)
                VALUES (new.rowid, new.text, new.raw_text, new.source_app, new.window_title, new.source_website);
            END;
            CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
                INSERT INTO transcripts_fts(transcripts_fts, rowid, text, raw_text, source_app, window_title, source_website)
                VALUES ('delete', old.rowid, old.text, old.raw_text, old.source_app, old.window_title, old.source_website);
            END;
            CREATE TRIGGER IF NOT EXISTS transcripts_au AFTER UPDATE ON transcripts BEGIN
                INSERT INTO transcripts_fts(transcripts_fts, rowid, text, raw_text, source_app, window_title, source_website)
                VALUES ('delete', old.rowid, old.text, old.raw_text, old.source_app, old.window_title, old.source_website);
                INSERT INTO transcripts_fts(rowid, text, raw_text, source_app, window_title, source_website)
                VALUES (new.rowid, new.text, new.raw_text, new.source_app, new.window_title, new.source_website);
            END;
            CREATE TABLE IF NOT EXISTS transcript_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                transcript_id TEXT NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
                created_at REAL NOT NULL,
                text TEXT NOT NULL,
                raw_text TEXT,
                cleaned_text TEXT,
                mode_name TEXT,
                reason TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS transcript_versions_transcript ON transcript_versions(transcript_id);
            CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY,
                created REAL NOT NULL,  -- seconds since 2001, like transcripts.timestamp
                updated REAL NOT NULL,
                text TEXT NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                text, content='notes', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
                INSERT INTO notes_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
                INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
                INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
                INSERT INTO notes_fts(rowid, text) VALUES (new.rowid, new.text);
            END;
            """
        guard exec(schema) else { return nil }
    }

    deinit {
        sqlite3_close(db)
    }

    var isEmpty: Bool {
        var empty = true
        query("SELECT 1 FROM transcripts LIMIT 1") { _ in empty = false }
        return empty
    }

    // MARK: - Entries

    /// Retired output types are removed using their stored value before model decoding.
    /// Cascades remove versions; the delete trigger updates FTS. Retry on the next launch.
    @discardableResult
    func removeLegacyMeetings() -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }
        guard exec("DELETE FROM transcripts WHERE output_method = 'meeting'"), exec("COMMIT") else {
            _ = exec("ROLLBACK")
            return false
        }
        return true
    }

    /// Newest first.
    func loadAll() -> [TranscriptionEntry] {
        var entries: [TranscriptionEntry] = []
        query("""
            SELECT id, timestamp, text, raw_text, cleaned_text, duration, source_app, window_title, source_website,
                   output_method, transcription_mode, mode_name, timings, audio_file_name, failure_reason
            FROM transcripts WHERE output_method != 'meeting' ORDER BY timestamp DESC
            """) { row in
            guard let idText = row.text(0), let id = UUID(uuidString: idText) else { return }
            // Meeting recording was removed; leave old meeting rows untouched but out of the list and the stats.
            guard row.text(9) != "meeting" else { return }
            entries.append(TranscriptionEntry(
                id: id,
                text: row.text(2) ?? "",
                timestamp: Date(timeIntervalSinceReferenceDate: row.double(1)),
                duration: row.double(5),
                sourceApp: row.text(6),
                windowTitle: row.text(7),
                sourceWebsite: row.text(8),
                outputMethod: row.text(9).flatMap(TranscriptionEntry.OutputMethod.init(rawValue:)) ?? .clipboard,
                transcriptionMode: row.text(10).flatMap(TranscriptionEntry.TranscriptionMode.init(rawValue:)) ?? .local,
                rawText: row.text(3),
                cleanedText: row.text(4),
                modeName: row.text(11),
                timings: row.text(12).flatMap { try? self.decoder.decode(TranscriptionEntry.StageTimings.self, from: Data($0.utf8)) },
                audioFileName: row.text(13),
                failureReason: row.text(14)
            ))
        }
        return entries
    }

    /// Insert or replace (same id).
    @discardableResult
    func save(_ entry: TranscriptionEntry) -> Bool {
        let timings = entry.timings.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return run("""
            INSERT INTO transcripts (id, timestamp, text, raw_text, cleaned_text, duration, source_app, window_title,
                source_website, output_method, transcription_mode, mode_name, timings, audio_file_name, failure_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text = excluded.text, raw_text = excluded.raw_text, cleaned_text = excluded.cleaned_text,
                duration = excluded.duration, mode_name = excluded.mode_name, timings = excluded.timings,
                output_method = excluded.output_method, audio_file_name = excluded.audio_file_name,
                failure_reason = excluded.failure_reason
            """, [
            .text(entry.id.uuidString), .double(entry.timestamp.timeIntervalSinceReferenceDate), .text(entry.text),
            .optionalText(entry.rawText), .optionalText(entry.cleanedText), .double(entry.duration),
            .optionalText(entry.sourceApp), .optionalText(entry.windowTitle), .optionalText(entry.sourceWebsite),
            .text(entry.outputMethod.rawValue), .text(entry.transcriptionMode.rawValue), .optionalText(entry.modeName),
            .optionalText(timings), .optionalText(entry.audioFileName), .optionalText(entry.failureReason)
        ])
    }

    /// One transaction (migration from history.json).
    func saveAll(_ entries: [TranscriptionEntry]) -> Bool {
        guard exec("BEGIN") else { return false }
        for entry in entries where !save(entry) {
            _ = exec("ROLLBACK")
            return false
        }
        return exec("COMMIT")
    }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        _ = exec("BEGIN")
        for id in ids {
            run("DELETE FROM transcripts WHERE id = ?", [.text(id.uuidString)])
        }
        _ = exec("COMMIT")
    }

    func deleteAll() {
        _ = exec("DELETE FROM transcripts")
    }

    /// FTS5 search: every word must match (prefix match, accents ignored). Newest first.
    /// Nil if the query can't be run (the caller falls back to substring search).
    func searchIDs(_ text: String) -> [UUID]? {
        let terms = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !terms.isEmpty else { return nil }
        var ids: [UUID] = []
        let ok = query("""
            SELECT t.id FROM transcripts_fts JOIN transcripts t ON t.rowid = transcripts_fts.rowid
            WHERE transcripts_fts MATCH ? ORDER BY t.timestamp DESC
            """, [.text(terms.joined(separator: " "))]) { row in
            if let id = row.text(0).flatMap(UUID.init(uuidString:)) { ids.append(id) }
        }
        return ok ? ids : nil
    }

    // MARK: - Versions (N2)

    func addVersion(of entry: TranscriptionEntry, reason: String) {
        run("""
            INSERT INTO transcript_versions (transcript_id, created_at, text, raw_text, cleaned_text, mode_name, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.text(entry.id.uuidString), .double(Date().timeIntervalSince1970), .text(entry.text),
                  .optionalText(entry.rawText), .optionalText(entry.cleanedText), .optionalText(entry.modeName), .text(reason)])
    }

    func versions(of id: UUID) -> [Version] {
        var versions: [Version] = []
        query("SELECT id, created_at, text, reason FROM transcript_versions WHERE transcript_id = ? ORDER BY created_at DESC",
              [.text(id.uuidString)]) { row in
            versions.append(Version(id: row.int(0), createdAt: Date(timeIntervalSince1970: row.double(1)), text: row.text(2) ?? "", reason: row.text(3) ?? ""))
        }
        return versions
    }

    // MARK: - Notes (L7 Scratchpad)

    /// Pinned first, then most recently edited.
    func loadNotes() -> [Note] {
        var notes: [Note] = []
        query("SELECT id, created, updated, text, pinned FROM notes ORDER BY pinned DESC, updated DESC") { row in
            guard let id = row.text(0).flatMap(UUID.init(uuidString:)) else { return }
            notes.append(Note(
                id: id,
                created: Date(timeIntervalSinceReferenceDate: row.double(1)),
                updated: Date(timeIntervalSinceReferenceDate: row.double(2)),
                text: row.text(3) ?? "",
                pinned: row.int(4) != 0
            ))
        }
        return notes
    }

    @discardableResult
    func saveNote(_ note: Note) -> Bool {
        run("""
            INSERT INTO notes (id, created, updated, text, pinned) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET updated = excluded.updated, text = excluded.text, pinned = excluded.pinned
            """, [.text(note.id.uuidString), .double(note.created.timeIntervalSinceReferenceDate),
                  .double(note.updated.timeIntervalSinceReferenceDate), .text(note.text), .int(note.pinned ? 1 : 0)])
    }

    func deleteNote(id: UUID) {
        run("DELETE FROM notes WHERE id = ?", [.text(id.uuidString)])
    }

    /// FTS5 search over notes (prefix match per word, accents ignored). Nil if it can't run.
    func searchNoteIDs(_ text: String) -> [UUID]? {
        let terms = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !terms.isEmpty else { return nil }
        var ids: [UUID] = []
        let ok = query("""
            SELECT n.id FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
            WHERE notes_fts MATCH ? ORDER BY n.pinned DESC, n.updated DESC
            """, [.text(terms.joined(separator: " "))]) { row in
            if let id = row.text(0).flatMap(UUID.init(uuidString:)) { ids.append(id) }
        }
        return ok ? ids : nil
    }

    // MARK: - SQLite

    enum Value {
        case text(String)
        case optionalText(String?)
        case double(Double)
        case int(Int64)
    }

    struct Row {
        let statement: OpaquePointer
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            Self.logger.error("sqlite exec failed: \(error.map { String(cString: $0) } ?? "?", privacy: .public)")
            sqlite3_free(error)
            return false
        }
        return true
    }

    @discardableResult
    private func run(_ sql: String, _ values: [Value]) -> Bool {
        query(sql, values) { _ in }
    }

    @discardableResult
    private func query(_ sql: String, _ values: [Value] = [], _ each: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Self.logger.error("sqlite prepare failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .optionalText(let text):
                if let text { sqlite3_bind_text(statement, index, text, -1, Self.transient) } else { sqlite3_bind_null(statement, index) }
            case .double(let number): sqlite3_bind_double(statement, index, number)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                each(Row(statement: statement))
            } else if result == SQLITE_DONE {
                return true
            } else {
                Self.logger.error("sqlite step failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                return false
            }
        }
    }
}
