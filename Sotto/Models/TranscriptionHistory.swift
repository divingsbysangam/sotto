import Foundation

struct TranscriptionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    /// The version in use: shown, searched, counted, and used by "Paste last transcript".
    /// Normally the cleaned text; the raw text after "Undo AI Edit".
    var text: String
    let timestamp: Date
    let duration: TimeInterval
    let sourceApp: String?
    let windowTitle: String?
    /// Page origin ("https://host") when dictating into a browser tab; never the path or query.
    let sourceWebsite: String?
    let outputMethod: OutputMethod
    let transcriptionMode: TranscriptionMode

    // Added later, so optional: older history.json entries decode with these as nil.
    /// Transcriber output (vocabulary corrections applied) before cleanup.
    var rawText: String?
    /// Cleanup output; nil when AI Enhancement was off.
    var cleanedText: String?
    /// App Mode whose prompt applied, if any.
    var modeName: String?
    var timings: StageTimings?
    /// Kept recording in `AudioArchive` (M4A); the file may since have been pruned.
    let audioFileName: String?
    /// N2: set when the dictation failed; its audio is kept so it can be retried.
    var failureReason: String?

    var isFailed: Bool { failureReason != nil }

    struct StageTimings: Codable, Hashable {
        /// Key-down to end of capture (includes the audio tail).
        let record: TimeInterval
        /// Includes waiting for the model if it was still loading.
        let transcribe: TimeInterval
        /// Nil when AI Enhancement was off.
        let cleanup: TimeInterval?
        let paste: TimeInterval
    }

    /// Cleanup changed the text, so there is something to undo.
    var hasAIEdit: Bool {
        guard let rawText, let cleanedText else { return false }
        return rawText != cleanedText
    }

    var isShowingRaw: Bool {
        hasAIEdit && text == rawText
    }

    var audioURL: URL? {
        audioFileName.map { AudioArchive.directory.appendingPathComponent($0) }
    }

    /// The kept audio, if it's still on disk (it may have been pruned or not finished encoding).
    var existingAudioURL: URL? {
        audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    enum OutputMethod: String, Codable {
        case clipboard
        case paste
        /// N13: transcribed from a file; saved to history only.
        case imported
        /// A failed dictation, or one retried from history: nothing was output.
        case notPasted
        /// L7: dictated into a Scratchpad note instead of an app.
        case scratchpad
        /// L6: sent to a coding agent as a follow-up.
        case agentReply
        /// An unknown kind (for example from a newer or older build) must not make the whole history unreadable.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: raw) ?? .clipboard
        }
    }

    enum TranscriptionMode: String, Codable {
        case cloud
        case local
    }

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        duration: TimeInterval,
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        sourceWebsite: String? = nil,
        outputMethod: OutputMethod,
        transcriptionMode: TranscriptionMode = .local,
        rawText: String? = nil,
        cleanedText: String? = nil,
        modeName: String? = nil,
        timings: StageTimings? = nil,
        audioFileName: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.sourceWebsite = sourceWebsite
        self.outputMethod = outputMethod
        self.transcriptionMode = transcriptionMode
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.modeName = modeName
        self.timings = timings
        self.audioFileName = audioFileName
        self.failureReason = failureReason
    }
}

@Observable
final class TranscriptionHistoryManager {
    static let shared: TranscriptionHistoryManager = {
        // AppState's stored properties initialize before its test-mode guard. Keep even that
        // initialization away from personal history and preferences in hosted XCTest runs.
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" {
            let name = "com.sotto.history-tests.\(UUID().uuidString)"
            return TranscriptionHistoryManager(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(name),
                defaults: UserDefaults(suiteName: name)!
            )
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return TranscriptionHistoryManager(directory: appSupport.appendingPathComponent("Sotto", isDirectory: true))
    }()

    /// Newest first. Loaded from SQLite at launch and kept in sync with every change.
    private(set) var entries: [TranscriptionEntry] = []
    private let jsonURL: URL
    /// Nil if the database can't be opened or the one-time migration failed; history then uses
    /// history.json for this launch (and the migration is tried again next launch).
    private var store: HistoryStore?
    private var jsonIsReadable = true

    /// History in `sottoDir` (history.sqlite, plus history.json when migrating). Tests pass a temporary folder.
    init(directory sottoDir: URL, defaults: UserDefaults = .standard) {
        try? FileManager.default.createDirectory(at: sottoDir, withIntermediateDirectories: true)

        LegacyMeetingCleanup.run(directory: sottoDir, defaults: defaults)
        jsonURL = sottoDir.appendingPathComponent("history.json")
        store = HistoryStore(url: sottoDir.appendingPathComponent("history.sqlite"))
        if let store, !store.removeLegacyMeetings() {
            print("Legacy meeting history cleanup failed; will retry next launch")
        }
        if let store, !migrateJSONIfNeeded(into: store) {
            self.store = nil
        }
        if let store {
            entries = store.loadAll()
        } else {
            entries = loadJSON() ?? []
        }
    }

    /// One-time move from history.json to SQLite. The JSON file is kept as history.json.bak.
    /// False when it failed, so this launch keeps using history.json instead of an empty store.
    private func migrateJSONIfNeeded(into store: HistoryStore) -> Bool {
        guard store.isEmpty, FileManager.default.fileExists(atPath: jsonURL.path) else { return true }
        guard let old = loadJSON() else { return false }
        guard store.saveAll(old) else {
            print("History migration to SQLite failed; using history.json for now")
            return false
        }
        var backup = jsonURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            backup = jsonURL.deletingLastPathComponent().appendingPathComponent("history-\(Int(Date().timeIntervalSince1970)).json.bak")
        }
        try? FileManager.default.moveItem(at: jsonURL, to: backup)
        print("Migrated \(old.count) transcripts to SQLite; kept \(backup.lastPathComponent)")
        return true
    }

    /// L7: notes share the history database (their own tables). Nil when it couldn't be opened.
    var notesStore: HistoryStore? { store }

    /// Adds the entry, then applies the retention settings (so an always-on app still prunes).
    func addEntry(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        persist(entry)
        applyRetention()
    }

    /// Transcripts older than "Keep transcripts for" are deleted along with their audio; kept
    /// audio older than "Keep audio for" is deleted too (never a failed entry's, which is needed
    /// to retry it). Runs at launch and after each dictation.
    func applyRetention() {
        let settings = AppSettings.shared
        var removed: [TranscriptionEntry] = []
        if let maxAge = settings.transcriptRetention.maxAge {
            let cutoff = Date().addingTimeInterval(-maxAge)
            removed = entries.filter { $0.timestamp < cutoff }
            entries.removeAll { $0.timestamp < cutoff }
        }
        store?.delete(ids: removed.map(\.id))
        if store == nil { saveJSON() }
        AudioArchive.delete(fileNames: removed.compactMap(\.audioFileName))
        AudioArchive.prune(
            olderThan: settings.audioRetention.maxAge,
            keeping: Set(entries.compactMap(\.audioFileName)),
            protecting: Set(entries.filter(\.isFailed).compactMap(\.audioFileName))
        )
    }

    func deleteEntry(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        store?.delete(ids: [entry.id])
        if store == nil { saveJSON() }
        AudioArchive.delete(fileNames: [entry.audioFileName].compactMap { $0 })
    }

    func clearHistory() {
        let fileNames = entries.compactMap(\.audioFileName)
        entries.removeAll()
        store?.deleteAll()
        if store == nil { saveJSON() }
        AudioArchive.delete(fileNames: fileNames)
    }

    /// "Undo AI Edit" (raw) / "Restore AI Edit" (cleaned).
    func setShowsRaw(_ showRaw: Bool, for entry: TranscriptionEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }),
              let raw = entries[index].rawText,
              let cleaned = entries[index].cleanedText else { return }
        entries[index].text = showRaw ? raw : cleaned
        persist(entries[index])
    }

    /// N2: a re-transcribe / re-clean result. The previous text is kept as a version.
    func replaceResult(
        for id: UUID,
        text: String,
        rawText: String?,
        cleanedText: String?,
        modeName: String?,
        timings: TranscriptionEntry.StageTimings?,
        reason: String
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[index].isFailed {
            store?.addVersion(of: entries[index], reason: reason)
        }
        entries[index].text = text
        entries[index].rawText = rawText
        entries[index].cleanedText = cleanedText
        entries[index].modeName = modeName
        entries[index].timings = timings ?? entries[index].timings
        entries[index].failureReason = nil
        persist(entries[index])
    }

    /// Earlier results of a re-transcribed / re-cleaned entry, newest first.
    func versions(of id: UUID) -> [HistoryStore.Version] {
        store?.versions(of: id) ?? []
    }

    /// Full-text search (SQLite FTS5: each word matches as a prefix, accents ignored) over the
    /// text, raw text, app, window title, and site. Substring search if FTS isn't available.
    func search(_ query: String) -> [TranscriptionEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        if let ids = store?.searchIDs(trimmed) {
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
        let lowercased = trimmed.lowercased()
        return entries.filter { entry in
            entry.text.lowercased().contains(lowercased) ||
            (entry.sourceApp?.lowercased().contains(lowercased) ?? false) ||
            (entry.windowTitle?.lowercased().contains(lowercased) ?? false) ||
            (entry.sourceWebsite?.lowercased().contains(lowercased) ?? false)
        }
    }

    private func persist(_ entry: TranscriptionEntry) {
        if let store {
            store.save(entry)
        } else {
            saveJSON()
        }
    }

    // MARK: - JSON (migration source and fallback)

    private func loadJSON() -> [TranscriptionEntry]? {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }
        do {
            let data = try LegacyMeetingCleanup.historyDataWithoutMeetings(Data(contentsOf: jsonURL))
            return try JSONDecoder().decode([TranscriptionEntry].self, from: data)
        } catch {
            jsonIsReadable = false
            // Keep the unreadable file so nothing can overwrite it.
            let backup = jsonURL.deletingLastPathComponent()
                .appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: jsonURL, to: backup)
            print("Failed to load history (copied to \(backup.lastPathComponent))")
            return nil
        }
    }

    private func saveJSON() {
        guard jsonIsReadable else {
            print("History JSON is unreadable; refusing to overwrite it")
            return
        }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: jsonURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    // MARK: - Statistics

    /// `typingWPM`: the user's measured typing speed (L15), used for time saved instead of 40 WPM.
    func getStatistics(days: Int = 30, typingWPM: Double? = nil) -> UsageStatistics {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let entries = self.entries
        let recentEntries = entries.filter { $0.timestamp >= cutoffDate }

        let totalWords = recentEntries.reduce(0) { $0 + wordCount(for: $1.text) }
        let lifetimeWords = entries.reduce(0) { $0 + wordCount(for: $1.text) }
        let totalDuration = recentEntries.reduce(0) { $0 + $1.duration }

        let averageWPM: Double = totalDuration > 0
            ? Double(totalWords) / (totalDuration / 60.0)
            : 0

        // Time saved: typing (measured speed, else 40 WPM) vs speaking
        let typingTime = Double(totalWords) / max(typingWPM ?? 40.0, 1) * 60.0
        let timeSaved = max(0, typingTime - totalDuration)

        // Top sources by word count
        var sourceCounts: [String: Int] = [:]
        for entry in recentEntries {
            let app = entry.sourceApp ?? "Unknown"
            sourceCounts[app, default: 0] += wordCount(for: entry.text)
        }
        let topSources = sourceCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { AppUsage(appName: $0.key, wordCount: $0.value) }

        // Daily activity for last 7 days
        var dailyActivity: [DailyActivity] = []
        for dayOffset in (0..<7).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let startOfDay = calendar.startOfDay(for: date)
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { continue }

            let dayEntries = entries.filter { $0.timestamp >= startOfDay && $0.timestamp < endOfDay }
            let dayWords = dayEntries.reduce(0) { $0 + wordCount(for: $1.text) }
            dailyActivity.append(DailyActivity(date: startOfDay, wordCount: dayWords, transcriptCount: dayEntries.count))
        }

        return UsageStatistics(
            totalWords: totalWords,
            lifetimeWords: lifetimeWords,
            totalDuration: totalDuration,
            timeSaved: timeSaved,
            averageWPM: averageWPM,
            transcriptCount: recentEntries.count,
            topSources: topSources,
            dailyActivity: dailyActivity,
            currentStreak: calculateStreak()
        )
    }

    /// L15: dictated characters and recording time per dictation (not file imports or failures).
    var dictationVolume: [(date: Date, chars: Int, duration: TimeInterval)] {
        entries
            .filter { !$0.isFailed && $0.outputMethod != .imported }
            .map { ($0.timestamp, $0.text.count, $0.duration) }
    }

    func wordCount(for text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func calculateStreak() -> Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        let todayEntries = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: checkDate) }
        if todayEntries.isEmpty {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else { return 0 }
            checkDate = yesterday
        }

        while true {
            let dayEntries = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: checkDate) }
            if dayEntries.isEmpty { break }
            streak += 1
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prevDay
        }

        return streak
    }
}

// MARK: - Statistics Models

struct UsageStatistics {
    let totalWords: Int
    let lifetimeWords: Int
    let totalDuration: TimeInterval
    let timeSaved: TimeInterval
    let averageWPM: Double
    let transcriptCount: Int
    let topSources: [AppUsage]
    let dailyActivity: [DailyActivity]
    let currentStreak: Int

    static let empty = UsageStatistics(
        totalWords: 0, lifetimeWords: 0, totalDuration: 0, timeSaved: 0,
        averageWPM: 0, transcriptCount: 0, topSources: [], dailyActivity: [], currentStreak: 0
    )
}

struct AppUsage: Identifiable {
    let id = UUID()
    let appName: String
    let wordCount: Int
}

struct DailyActivity: Identifiable {
    let id = UUID()
    let date: Date
    let wordCount: Int
    let transcriptCount: Int
}
