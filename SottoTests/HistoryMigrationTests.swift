import SQLite3
import XCTest
@testable import Sotto

/// History moved from a JSON file to SQLite (one-time migration at launch). These tests run it
/// against temporary folders, so they never touch the real Application Support data.
final class HistoryMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var jsonURL: URL { directory.appendingPathComponent("history.json") }
    private var backupURL: URL { directory.appendingPathComponent("history.json.bak") }
    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }

    private func entry(_ text: String, minutesAgo: Double, method: TranscriptionEntry.OutputMethod = .paste) -> TranscriptionEntry {
        TranscriptionEntry(
            text: text,
            timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 - minutesAgo * 60),
            duration: 3.5,
            sourceApp: "Notes",
            sourceWebsite: "https://example.com",
            outputMethod: method,
            rawText: text.lowercased(),
            cleanedText: text,
            modeName: "Notes"
        )
    }

    private func writeLegacyJSON(_ entries: [TranscriptionEntry]) throws {
        try JSONEncoder().encode(entries).write(to: jsonURL)
    }

    private func files(matching prefix: String, suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
    }

    // MARK: - JSON → SQLite

    func testLegacyJSONMigratesToSQLiteAndIsKeptAsBackup() throws {
        let older = entry("Older note", minutesAgo: 30)
        let newer = entry("Newer note", minutesAgo: 5)
        try writeLegacyJSON([older, newer])

        let manager = TranscriptionHistoryManager(directory: directory)

        XCTAssertEqual(manager.entries, [newer, older], "newest first, every field preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL.path), "history.json is moved aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "and kept as history.json.bak")

        // The data really is in SQLite: read it back with a fresh connection.
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        XCTAssertEqual(store.loadAll(), [newer, older])
    }

    func testMigrationRunsOnlyOnce() throws {
        let saved = entry("Keep me", minutesAgo: 1)
        try writeLegacyJSON([saved])
        _ = TranscriptionHistoryManager(directory: directory)

        let second = TranscriptionHistoryManager(directory: directory)

        XCTAssertEqual(second.entries, [saved])
        XCTAssertEqual(files(matching: "history", suffix: ".bak"), ["history.json.bak"])
    }

    func testExistingBackupIsNeverOverwritten() throws {
        try Data("old backup".utf8).write(to: backupURL)
        try writeLegacyJSON([entry("New data", minutesAgo: 1)])

        _ = TranscriptionHistoryManager(directory: directory)

        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "old backup")
        XCTAssertEqual(files(matching: "history-", suffix: ".json.bak").count, 1, "a timestamped backup is written instead")
    }

    func testEntriesWrittenByOlderVersionsStillDecode() throws {
        // No rawText, cleanedText, modeName, timings, audioFileName or failureReason: added in later versions.
        let id = UUID()
        let legacy = """
        [{"id":"\(id.uuidString)","text":"hello","timestamp":800000000,"duration":2,
          "outputMethod":"paste","transcriptionMode":"local"}]
        """
        try Data(legacy.utf8).write(to: jsonURL)

        let manager = TranscriptionHistoryManager(directory: directory)

        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries[0].id, id)
        XCTAssertEqual(manager.entries[0].text, "hello")
        XCTAssertNil(manager.entries[0].rawText)
        XCTAssertNil(manager.entries[0].failureReason)
        XCTAssertFalse(manager.entries[0].isFailed)
    }

    func testAnUnknownOutputKindDoesNotMakeTheHistoryUnreadable() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","text":"future","timestamp":800000000,"duration":1,
          "outputMethod":"somethingFromANewerBuild","transcriptionMode":"local"}]
        """
        try Data(legacy.utf8).write(to: jsonURL)

        let manager = TranscriptionHistoryManager(directory: directory)

        XCTAssertEqual(manager.entries.map(\.text), ["future"])
        XCTAssertEqual(manager.entries[0].outputMethod, .clipboard)
    }

    func testUnreadableJSONIsNotDestroyed() throws {
        let garbage = "this is not json {"
        try Data(garbage.utf8).write(to: jsonURL)

        let manager = TranscriptionHistoryManager(directory: directory)

        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), garbage, "the original is untouched")
        XCTAssertFalse(files(matching: "history-unreadable-", suffix: ".json").isEmpty, "and a copy is kept")
    }

    func testFreshInstallStartsEmpty() {
        let manager = TranscriptionHistoryManager(directory: directory)
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    // MARK: - HistoryStore

    func testStoreRoundTripsEveryField() throws {
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        let full = TranscriptionEntry(
            text: "Cleaned text",
            timestamp: Date(timeIntervalSinceReferenceDate: 812_345_678.25),
            duration: 12.75,
            sourceApp: "Mail",
            windowTitle: "Draft",
            sourceWebsite: "https://mail.example.com",
            outputMethod: .imported,
            rawText: "raw text",
            cleanedText: "Cleaned text",
            modeName: "Email",
            timings: .init(record: 1, transcribe: 2, cleanup: nil, paste: 0.5),
            audioFileName: "a.m4a",
            failureReason: "boom"
        )
        XCTAssertTrue(store.save(full))
        XCTAssertEqual(store.loadAll(), [full])
    }

    func testSavingTheSameIDReplacesTheRow() throws {
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        var item = entry("first", minutesAgo: 1)
        XCTAssertTrue(store.save(item))
        item.text = "second"
        XCTAssertTrue(store.save(item))
        XCTAssertEqual(store.loadAll().map(\.text), ["second"])
    }

    func testSearchMatchesPrefixesAndIgnoresAccents() throws {
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        let match = entry("Deploy to Kubernetes tonight", minutesAgo: 1)
        let other = entry("Buy milk and eggs", minutesAgo: 2)
        XCTAssertTrue(store.saveAll([match, other]))

        XCTAssertEqual(store.searchIDs("kubern"), [match.id])
        XCTAssertEqual(store.searchIDs("deploy tonight"), [match.id], "every word must match")
        XCTAssertEqual(store.searchIDs("café"), [])
        XCTAssertNil(store.searchIDs("   "), "nothing to search for")
    }

    func testDeletingATranscriptRemovesItsVersionsAndSearchEntries() throws {
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        let item = entry("Searchable words", minutesAgo: 1)
        XCTAssertTrue(store.save(item))
        store.addVersion(of: item, reason: "re-cleaned")
        XCTAssertEqual(store.versions(of: item.id).count, 1)

        store.delete(ids: [item.id])

        XCTAssertTrue(store.loadAll().isEmpty)
        XCTAssertTrue(store.versions(of: item.id).isEmpty, "versions cascade")
        XCTAssertEqual(store.searchIDs("searchable"), [], "and the search index is cleaned up")
    }

    func testRetiredMeetingRowsAreHiddenButNotDeleted() throws {
        let store = try XCTUnwrap(HistoryStore(url: databaseURL))
        let normal = entry("Normal dictation", minutesAgo: 1)
        XCTAssertTrue(store.save(normal))

        // Meeting recording was removed, but an older build may have left rows with that kind.
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let insert = """
            INSERT INTO transcripts (id, timestamp, text, duration, output_method, transcription_mode)
            VALUES ('\(UUID().uuidString)', 700000000, 'old meeting', 600, 'meeting', 'local')
            """
        XCTAssertEqual(sqlite3_exec(raw, insert, nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(store.loadAll().map(\.text), ["Normal dictation"])
        var count: Int32 = 0
        var statement: OpaquePointer?
        sqlite3_prepare_v2(raw, "SELECT COUNT(*) FROM transcripts", -1, &statement, nil)
        if sqlite3_step(statement) == SQLITE_ROW { count = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        XCTAssertEqual(count, 2, "the legacy row is still on disk")
    }
}
