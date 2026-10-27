import Foundation
import SQLite3
import os

/// N11: import vocabulary from superwhisper / Wispr Flow, and export or re-import Sotto's own.
/// Always user-initiated, and reads only vocabulary: never history or other settings.
enum VocabularyImportService {
    /// Words, replacements, and snippets, as exported (JSON) or read from another app.
    struct Bundle: Codable, Equatable {
        var words: [String] = []
        var replacements: [TextReplacement] = []
        var snippets: [TextSnippet] = []

        var isEmpty: Bool { words.isEmpty && replacements.isEmpty && snippets.isEmpty }
    }

    enum Source {
        case superwhisper
        case wisprFlow
        case file(URL)

        var displayName: String {
            switch self {
            case .superwhisper: return "superwhisper"
            case .wisprFlow: return "Wispr Flow"
            case .file(let url): return url.lastPathComponent
            }
        }
    }

    enum ImportError: LocalizedError {
        case notFound(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let what): return "\(what) wasn't found on this Mac."
            case .unreadable(let why): return "The file couldn't be read: \(why)"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "VocabularyImport")

    static let superwhisperURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/superwhisper/settings/settings.json")
    static let wisprFlowURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")

    static func load(_ source: Source) throws -> Bundle {
        let bundle: Bundle
        switch source {
        case .superwhisper: bundle = try loadSuperwhisper(from: superwhisperURL)
        case .wisprFlow: bundle = try loadWisprFlow(from: wisprFlowURL)
        case .file(let url): bundle = try loadSottoExport(from: url)
        }
        logger.notice("read \(source.displayName, privacy: .public): words=\(bundle.words.count, privacy: .public) replacements=\(bundle.replacements.count, privacy: .public) snippets=\(bundle.snippets.count, privacy: .public)")
        return bundle
    }

    static var current: Bundle {
        let settings = AppSettings.shared
        return Bundle(words: settings.vocabularyList, replacements: settings.replacements, snippets: settings.snippets)
    }

    // MARK: - superwhisper

    /// `vocabulary`: [String]; `replacements`: [{ "original", "with" }] (older keys tolerated).
    static func loadSuperwhisper(from url: URL) throws -> Bundle {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.notFound("superwhisper's settings") }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ImportError.unreadable("not a settings file")
        }
        var bundle = Bundle()
        for item in object["vocabulary"] as? [Any] ?? [] {
            if let word = item as? String {
                bundle.words.append(word)
            } else if let dict = item as? [String: Any], let word = (dict["word"] ?? dict["text"] ?? dict["value"]) as? String {
                bundle.words.append(word)
            }
        }
        for item in object["replacements"] as? [[String: Any]] ?? [] {
            let spoken = (item["original"] ?? item["from"] ?? item["find"]) as? String
            let written = (item["with"] ?? item["replacement"] ?? item["to"]) as? String
            if let spoken, let written {
                bundle.replacements.append(TextReplacement(spoken: spoken, written: written))
            }
        }
        return clean(bundle)
    }

    // MARK: - Wispr Flow

    /// `SELECT phrase, replacement, isSnippet FROM Dictionary WHERE isDeleted = 0`, from a copy so
    /// a running Wispr Flow isn't disturbed. Opened read-only.
    static func loadWisprFlow(from url: URL) throws -> Bundle {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw ImportError.notFound("Wispr Flow's dictionary") }
        let tempDir = fm.temporaryDirectory.appendingPathComponent("sotto-wispr-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let copy = tempDir.appendingPathComponent("flow.sqlite")
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ImportError.unreadable("the database couldn't be opened")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT phrase, replacement, isSnippet FROM Dictionary WHERE isDeleted = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var bundle = Bundle()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let phrase = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let replacement = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let isSnippet = sqlite3_column_int(statement, 2) != 0
            if let replacement, !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if isSnippet {
                    bundle.snippets.append(TextSnippet(cue: phrase, text: replacement))
                } else {
                    bundle.replacements.append(TextReplacement(spoken: phrase, written: replacement))
                }
            } else if !isSnippet {
                bundle.words.append(phrase)
            }
        }
        return clean(bundle)
    }

    // MARK: - Sotto export (JSON / CSV)

    static func exportJSON(_ bundle: Bundle, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ExportFile(sotto: 1, words: bundle.words, replacements: bundle.replacements.map { .init(spoken: $0.spoken, written: $0.written) }, snippets: bundle.snippets.map { .init(cue: $0.cue, text: $0.text) }))
            .write(to: url, options: .atomic)
    }

    /// `type,spoken,written` rows: type is word, replacement, or snippet (spoken = cue).
    static func exportCSV(_ bundle: Bundle, to url: URL) throws {
        var rows = [["type", "spoken", "written"]]
        rows += bundle.words.map { ["word", $0, ""] }
        rows += bundle.replacements.map { ["replacement", $0.spoken, $0.written] }
        rows += bundle.snippets.map { ["snippet", $0.cue, $0.text] }
        let csv = rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    static func loadSottoExport(from url: URL) throws -> Bundle {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "csv" {
            guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unreadable("not UTF-8 text") }
            var bundle = Bundle()
            for row in parseCSV(text).dropFirst() where row.count >= 2 {
                let written = row.count > 2 ? row[2] : ""
                switch row[0].lowercased() {
                case "word": bundle.words.append(row[1])
                case "replacement": bundle.replacements.append(TextReplacement(spoken: row[1], written: written))
                case "snippet": bundle.snippets.append(TextSnippet(cue: row[1], text: written))
                default: continue
                }
            }
            return clean(bundle)
        }
        guard let file = try? JSONDecoder().decode(ExportFile.self, from: data) else {
            throw ImportError.unreadable("not a Sotto vocabulary export")
        }
        return clean(Bundle(
            words: file.words,
            replacements: file.replacements.map { TextReplacement(spoken: $0.spoken, written: $0.written) },
            snippets: file.snippets.map { TextSnippet(cue: $0.cue, text: $0.text) }
        ))
    }

    /// Stable, id-free JSON so exports diff cleanly and re-import anywhere.
    private struct ExportFile: Codable {
        struct Replacement: Codable { let spoken: String; let written: String }
        struct Snippet: Codable { let cue: String; let text: String }
        let sotto: Int
        let words: [String]
        let replacements: [Replacement]
        let snippets: [Snippet]
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180: quoted fields may hold commas, quotes ("") and line breaks.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    /// Trims, drops empties, and (for words) drops pieces Vocabulary can't store (commas split it).
    private static func clean(_ bundle: Bundle) -> Bundle {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Bundle(
            words: bundle.words.flatMap { $0.split(separator: ",").map { trim(String($0)) } }.filter { !$0.isEmpty },
            replacements: bundle.replacements.map { TextReplacement(spoken: trim($0.spoken), written: $0.written) }.filter { !$0.spoken.isEmpty && !$0.written.isEmpty },
            snippets: bundle.snippets.map { TextSnippet(cue: trim($0.cue), text: $0.text) }.filter { !$0.cue.isEmpty && !$0.text.isEmpty }
        )
    }

    // MARK: - Preview and apply

    struct PreviewItem: Identifiable {
        enum Kind: String { case word = "Word", replacement = "Replacement", snippet = "Snippet" }
        let id = UUID()
        let kind: Kind
        let key: String
        let value: String
        /// Already in Sotto with the same content (unchecked by default).
        let isDuplicate: Bool
        /// Same spoken phrase/cue but different content: importing replaces Sotto's.
        let updatesExisting: Bool
    }

    static func preview(_ incoming: Bundle, against existing: Bundle = current) -> [PreviewItem] {
        let words = Set(existing.words.map { $0.lowercased() })
        let replacements = Dictionary(existing.replacements.map { ($0.spoken.lowercased(), $0.written) }, uniquingKeysWith: { a, _ in a })
        let snippets = Dictionary(existing.snippets.map { ($0.cue.lowercased(), $0.text) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var items: [PreviewItem] = []
        for word in incoming.words where seen.insert("w:" + word.lowercased()).inserted {
            items.append(PreviewItem(kind: .word, key: word, value: "", isDuplicate: words.contains(word.lowercased()), updatesExisting: false))
        }
        for r in incoming.replacements where seen.insert("r:" + r.spoken.lowercased()).inserted {
            let current = replacements[r.spoken.lowercased()]
            items.append(PreviewItem(kind: .replacement, key: r.spoken, value: r.written, isDuplicate: current == r.written, updatesExisting: current != nil && current != r.written))
        }
        for s in incoming.snippets where seen.insert("s:" + s.cue.lowercased()).inserted {
            let current = snippets[s.cue.lowercased()]
            items.append(PreviewItem(kind: .snippet, key: s.cue, value: s.text, isDuplicate: current == s.text, updatesExisting: current != nil && current != s.text))
        }
        return items
    }

    /// Adds the chosen items; a replacement/snippet with an existing phrase replaces it.
    @discardableResult
    static func apply(_ items: [PreviewItem]) -> Int {
        let settings = AppSettings.shared
        settings.addToVocabulary(items.filter { $0.kind == .word }.map(\.key))
        var replacements = settings.replacements
        for item in items where item.kind == .replacement {
            replacements.removeAll { $0.spoken.caseInsensitiveCompare(item.key) == .orderedSame }
            replacements.append(TextReplacement(spoken: item.key, written: item.value))
        }
        settings.replacements = replacements
        var snippets = settings.snippets
        for item in items where item.kind == .snippet {
            snippets.removeAll { $0.cue.caseInsensitiveCompare(item.key) == .orderedSame }
            snippets.append(TextSnippet(cue: item.key, text: item.value))
        }
        settings.snippets = snippets
        logger.notice("imported \(items.count, privacy: .public) vocabulary item(s)")
        return items.count
    }
}
