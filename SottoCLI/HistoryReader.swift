import Foundation
import SQLite3

/// Read-only access to Sotto's history database. Opens it with SQLITE_OPEN_READONLY and never
/// writes; the app owns the schema (Sotto/Models/HistoryStore.swift).
final class HistoryReader {
    struct Entry: Encodable {
        let id: String
        let date: Date
        let text: String
        let rawText: String?
        let app: String?
        let website: String?
        let mode: String?
        let durationSeconds: Double
    }

    enum ReaderError: Error, CustomStringConvertible {
        case notFound(String)
        case openFailed(String)
        case queryFailed(String)

        var description: String {
            switch self {
            case .notFound(let path): return "No Sotto history at \(path). Dictate once in Sotto first."
            case .openFailed(let why): return "Couldn't open the history database: \(why)"
            case .queryFailed(let why): return "History query failed: \(why)"
            }
        }
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sotto/history.sqlite")
    }

    private var db: OpaquePointer?

    init(url: URL = HistoryReader.defaultURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReaderError.notFound(url.path) }
        try open(url.path, flags: SQLITE_OPEN_READONLY)
        // The database is in WAL mode. A read-only connection can't create the -shm file, so
        // with Sotto quit (no -wal/-shm left) the first read fails. With no -wal nothing is
        // mid-write, so reading the file as immutable is safe.
        if !canRead(), !FileManager.default.fileExists(atPath: url.path + "-wal") {
            sqlite3_close(db)
            db = nil
            var components = URLComponents()
            components.scheme = "file"
            components.path = url.path
            components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            try open(components.string ?? url.absoluteString, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
        }
        sqlite3_busy_timeout(db, 2000)
    }

    private func open(_ path: String, flags: Int32) throws {
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw ReaderError.openFailed(message)
        }
    }

    private func canRead() -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    deinit {
        sqlite3_close(db)
    }

    private static let columns = "t.id, t.timestamp, t.text, t.raw_text, t.source_app, t.source_website, t.mode_name, t.duration"

    /// Newest first; failed dictations (no text) are skipped.
    func last(_ limit: Int) throws -> [Entry] {
        try query("SELECT \(Self.columns) FROM transcripts t WHERE t.text != '' ORDER BY t.timestamp DESC LIMIT ?", [.int(limit)])
    }

    /// Full-text search over text, raw text, app, window title and website (prefix match per word).
    func search(_ terms: String, limit: Int) throws -> [Entry] {
        let words = terms
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        return try query("""
            SELECT \(Self.columns) FROM transcripts_fts f JOIN transcripts t ON t.rowid = f.rowid
            WHERE transcripts_fts MATCH ? AND t.text != '' ORDER BY t.timestamp DESC LIMIT ?
            """, [.text(match), .int(limit)])
    }

    private enum Value { case text(String), int(Int) }

    private func query(_ sql: String, _ values: [Value]) throws -> [Entry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, position, Int64(number))
            }
        }
        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
        var entries: [Entry] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReaderError.queryFailed(String(cString: sqlite3_errmsg(db))) }
            entries.append(Entry(
                id: text(0) ?? "",
                // The app stores seconds since 2001 (Date's reference date).
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                text: text(2) ?? "",
                rawText: text(3),
                app: text(4),
                website: text(5),
                mode: text(6),
                durationSeconds: sqlite3_column_double(statement, 7)
            ))
        }
        return entries
    }
}
