import Foundation
import SQLite3
import XCTest
@testable import Sotto

final class LegacyMeetingCleanupTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let name = "com.sotto.cleanup-tests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: name)
        }
        return (root, defaults)
    }

    private func entry(_ method: TranscriptionEntry.OutputMethod = .paste) -> TranscriptionEntry {
        TranscriptionEntry(text: "Preserved dictation", duration: 3, sourceApp: "TextEdit",
                           sourceWebsite: "https://example.com", outputMethod: method,
                           rawText: "preserved dictation", cleanedText: "Preserved dictation",
                           modeName: "Test mode", audioFileName: "kept.m4a")
    }

    private func legacyJSON(keeping entries: [TranscriptionEntry]) throws -> Data {
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? [[String: Any]])
        var meeting = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry())) as? [String: Any])
        meeting["id"] = UUID().uuidString
        meeting["outputMethod"] = "meeting"
        meeting["text"] = "Retired meeting words"
        objects.append(meeting)
        return try JSONSerialization.data(withJSONObject: objects)
    }

    private func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA foreign_keys = ON; " + sql, nil, nil, nil), SQLITE_OK)
    }

    private func count(_ url: URL, _ query: String) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, query, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }

    func testSQLiteUpgradePreservesOtherHistoryNotesAndVersions() throws {
        let (root, defaults) = try fixture()
        let url = root.appendingPathComponent("history.sqlite")
        let store = try XCTUnwrap(HistoryStore(url: url))
        let kept = [entry(.paste), entry(.imported), entry(.scratchpad), entry(.agentReply)]
        for item in kept {
            XCTAssertTrue(store.save(item))
            store.addVersion(of: item, reason: "kept version")
        }
        let meeting = TranscriptionEntry(text: "Retired meeting words", duration: 8, outputMethod: .paste)
        XCTAssertTrue(store.save(meeting))
        store.addVersion(of: meeting, reason: "retired version")
        try sql(url, "UPDATE transcripts SET output_method = 'meeting' WHERE id = '\(meeting.id.uuidString)'")
        let note = Note(text: "Preserved note", pinned: true)
        XCTAssertTrue(store.saveNote(note))

        let manager = TranscriptionHistoryManager(directory: root, defaults: defaults)
        XCTAssertEqual(Set(manager.entries), Set(kept))
        XCTAssertEqual(store.loadNotes(), [note])
        XCTAssertEqual(try count(url, "SELECT count(*) FROM transcripts WHERE output_method = 'meeting'"), 0)
        XCTAssertEqual(store.versions(of: meeting.id).count, 0)
        XCTAssertEqual(store.searchIDs("Retired"), [])
        for item in kept {
            XCTAssertEqual(store.versions(of: item.id).count, 1)
            XCTAssertTrue(manager.search("Preserved").contains(item))
        }
        XCTAssertTrue(store.removeLegacyMeetings())
        XCTAssertEqual(Set(store.loadAll()), Set(kept))
    }

    func testFailedSQLiteDeleteRollsBackAndDoesNotLoadAsClipboard() throws {
        let (root, _) = try fixture()
        let url = root.appendingPathComponent("history.sqlite")
        let store = try XCTUnwrap(HistoryStore(url: url))
        let kept = entry()
        XCTAssertTrue(store.save(kept))
        let meeting = entry()
        XCTAssertTrue(store.save(meeting))
        store.addVersion(of: meeting, reason: "retired version")
        try sql(url, """
            UPDATE transcripts SET output_method = 'meeting' WHERE id = '\(meeting.id.uuidString)';
            CREATE TRIGGER reject_delete BEFORE DELETE ON transcripts BEGIN SELECT RAISE(ABORT, 'test failure'); END;
            """)
        XCTAssertFalse(store.removeLegacyMeetings())
        XCTAssertEqual(try count(url, "SELECT count(*) FROM transcripts"), 2)
        XCTAssertEqual(store.versions(of: meeting.id).count, 1)
        XCTAssertEqual(store.loadAll(), [kept])
        try sql(url, "DROP TRIGGER reject_delete")
        XCTAssertTrue(store.removeLegacyMeetings())
        XCTAssertEqual(store.versions(of: meeting.id).count, 0)
    }

    func testJSONOnlyUpgradeFiltersBeforeDecodeAndBackup() throws {
        let (root, defaults) = try fixture()
        let kept = [entry(.paste), entry(.imported)]
        try legacyJSON(keeping: kept).write(to: root.appendingPathComponent("history.json"))
        let manager = TranscriptionHistoryManager(directory: root, defaults: defaults)
        XCTAssertEqual(Set(manager.entries), Set(kept))
        let backup = try Data(contentsOf: root.appendingPathComponent("history.json.bak"))
        XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: backup), kept)
        let reopened = TranscriptionHistoryManager(directory: root, defaults: defaults)
        XCTAssertEqual(Set(reopened.entries), Set(kept))
    }

    func testJSONFallbackStillLoadsSurvivors() throws {
        let (root, defaults) = try fixture()
        // A directory where the database belongs forces the existing JSON fallback path.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("history.sqlite"), withIntermediateDirectories: true)
        let kept = entry(.imported)
        try legacyJSON(keeping: [kept]).write(to: root.appendingPathComponent("history.json"))
        let manager = TranscriptionHistoryManager(directory: root, defaults: defaults)
        XCTAssertEqual(manager.entries, [kept])
        XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: Data(contentsOf: root.appendingPathComponent("history.json"))), [kept])
    }

    func testMeetingOnlyHistoryAndFreshInstall() throws {
        let (root, defaults) = try fixture()
        XCTAssertTrue(TranscriptionHistoryManager(directory: root, defaults: defaults).entries.isEmpty)
        try legacyJSON(keeping: []).write(to: root.appendingPathComponent("history.json"))
        XCTAssertTrue(TranscriptionHistoryManager(directory: root, defaults: defaults).entries.isEmpty)
        let backup = try Data(contentsOf: root.appendingPathComponent("history.json.bak"))
        XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: backup), [])
    }

    func testBackupsFilesAndPreferencesAreCleanedSelectively() throws {
        let (root, defaults) = try fixture()
        let kept = entry()
        let data = try legacyJSON(keeping: [kept])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        objects[0]["futureField"] = ["preserve": true]
        let withFutureField = try JSONSerialization.data(withJSONObject: objects)
        let histories = ["history.json", "history.json.bak", "history-123.json.bak", "history-unreadable-456.json"]
        for name in histories { try withFutureField.write(to: root.appendingPathComponent(name)) }
        let unrelated = ["history-export.json", "history-789.json"]
        for name in unrelated { try data.write(to: root.appendingPathComponent(name)) }
        for name in ["Meetings", "SpeakerKit", "Audio", "SpeechModels", "LLM"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("marker"))
        }
        let keys = ["meetingSystemAudio", "meetingDetection", "meetingSpeakerCount"]
        for key in keys { defaults.set(1, forKey: key) }
        defaults.set("cohere", forKey: "speechEngine")

        XCTAssertTrue(LegacyMeetingCleanup.run(directory: root, defaults: defaults))
        XCTAssertTrue(LegacyMeetingCleanup.run(directory: root, defaults: defaults))
        for name in histories {
            let filtered = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: filtered), [kept])
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: filtered) as? [[String: Any]])
            XCTAssertEqual((values[0]["futureField"] as? [String: Bool])?["preserve"], true)
        }
        for name in ["Meetings", "SpeakerKit"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        for name in ["Audio", "SpeechModels", "LLM"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("marker")), Data([1]))
        }
        for name in unrelated { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), data) }
        for key in keys { XCTAssertNil(defaults.object(forKey: key)) }
        XCTAssertEqual(defaults.string(forKey: "speechEngine"), "cohere")
    }

    func testMalformedJSONAndFailedWritesArePreservedAndRetried() throws {
        let (root, defaults) = try fixture()
        let validURL = root.appendingPathComponent("history.json.bak")
        let valid = try legacyJSON(keeping: [entry()])
        try valid.write(to: validURL)
        let malformedURL = root.appendingPathComponent("history-unreadable-123.json")
        let malformed = Data("{broken".utf8)
        try malformed.write(to: malformedURL)
        let recordings = root.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        XCTAssertFalse(LegacyMeetingCleanup.run(directory: root, defaults: defaults,
            write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            remove: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(try Data(contentsOf: validURL), valid)
        XCTAssertEqual(try Data(contentsOf: malformedURL), malformed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordings.path))

        XCTAssertFalse(LegacyMeetingCleanup.run(directory: root, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path))
        XCTAssertEqual(try Data(contentsOf: malformedURL), malformed)
        XCTAssertEqual(try JSONDecoder().decode([TranscriptionEntry].self, from: Data(contentsOf: validURL)).count, 1)
        XCTAssertThrowsError(try LegacyMeetingCleanup.historyDataWithoutMeetings(Data("{}".utf8)))
    }

    func testUnreadableActiveJSONIsNeverOverwritten() throws {
        let (root, defaults) = try fixture()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("history.sqlite"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.json")
        let original = Data("unreadable".utf8)
        try original.write(to: url)
        let manager = TranscriptionHistoryManager(directory: root, defaults: defaults)
        // Exercise fallback persistence without applyRetention's production AudioArchive.
        manager.clearHistory()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
