import Foundation
import AppKit
import Carbon.HIToolbox

enum RecordingUIStyle: String, CaseIterable {
    case minimal = "minimal"
    case dot = "dot"
    case floating = "floating"

    var displayName: String {
        switch self {
        case .minimal: return "Bottom capsule + dot"
        case .dot: return "Dot near writing"
        case .floating: return "Floating window"
        }
    }
}

enum OutputMode: String, Codable, CaseIterable {
    case clipboard = "clipboard"
    case autoPaste = "autoPaste"
}

/// Sotto ships exactly one WhisperKit model: OpenAI Whisper Large v3 Turbo
/// (the Sept 2024 `v20240930` release — 4 decoder layers) from `argmaxinc/whisperkit-coreml`.
///
/// Note: the similarly named `openai_whisper-large-v3_turbo` folder in that repo is Argmax's
/// older full large-v3 build (~3.2GB), not OpenAI's Turbo model.
enum WhisperModel: String, CaseIterable {
    case largev3Turbo = "openai_whisper-large-v3-v20240930_turbo"

    var displayName: String {
        switch self {
        case .largev3Turbo: return "Whisper Large v3 Turbo (~1.6GB)"
        }
    }
}

/// N10: which language(s) dictation expects.
enum DictationLanguageMode: String, CaseIterable {
    /// English only (the default; fastest and most accurate for English).
    case english
    /// Whisper detects the language for each stretch of speech (mixed-language dictation).
    case auto
    /// One to three chosen languages: the likeliest of them is used for each dictation.
    case chosen
}

/// How long history keeps something. `maxAge`: nil = forever, 0 = nothing is kept.
enum RetentionPeriod: String, CaseIterable {
    case off
    case day
    case week
    case month
    case forever

    static let audioChoices: [RetentionPeriod] = [.off, .day, .week, .forever]
    static let transcriptChoices: [RetentionPeriod] = [.day, .week, .month, .forever]

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .day: return "1 day"
        case .week: return "1 week"
        case .month: return "1 month"
        case .forever: return "Forever"
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .off: return 0
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

enum HotkeyOption: String, CaseIterable {
    case cmdShiftSpace = "cmd_shift_space"
    case cmdShiftD = "cmd_shift_d"
    case cmdShiftR = "cmd_shift_r"
    case optionSpace = "option_space"
    case ctrlShiftSpace = "ctrl_shift_space"
    case fnF5 = "fn_f5"

    var displayName: String {
        switch self {
        case .cmdShiftSpace: return "⌘ ⇧ Space"
        case .cmdShiftD: return "⌘ ⇧ D"
        case .cmdShiftR: return "⌘ ⇧ R"
        case .optionSpace: return "⌥ Space"
        case .ctrlShiftSpace: return "⌃ ⇧ Space"
        case .fnF5: return "F5"
        }
    }
}

@Observable
final class AppSettings {
    static let shared: AppSettings = {
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" {
            let domain = "com.sotto.test-settings.\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            return AppSettings(defaults: defaults)
        }
        return AppSettings()
    }()

    private let defaults: UserDefaults

    var outputMode: OutputMode {
        get {
            guard let raw = defaults.string(forKey: "outputMode"),
                  let mode = OutputMode(rawValue: raw) else {
                return .clipboard
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: "outputMode") }
    }

    var recordingUIStyle: RecordingUIStyle {
        get {
            guard let raw = defaults.string(forKey: "recordingUIStyle"),
                  let style = RecordingUIStyle(rawValue: raw) else {
                return .minimal
            }
            return style
        }
        set { defaults.set(newValue.rawValue, forKey: "recordingUIStyle") }
    }

    var enableScreenContext: Bool {
        get { defaults.bool(forKey: "enableScreenContext") }
        set { defaults.set(newValue, forKey: "enableScreenContext") }
    }

    var soundEffectsEnabled: Bool {
        get { defaults.object(forKey: "soundEffectsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "soundEffectsEnabled") }
    }

    var hotkeyOption: HotkeyOption {
        get {
            guard let raw = defaults.string(forKey: "hotkeyOption"),
                  let option = HotkeyOption(rawValue: raw) else {
                return .cmdShiftSpace
            }
            return option
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkeyOption") }
    }

    /// "Keep audio for": off by default, so recordings are deleted right after each dictation.
    var audioRetention: RetentionPeriod {
        get { defaults.string(forKey: "audioRetention").flatMap(RetentionPeriod.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "audioRetention") }
    }

    /// "Keep transcripts for" (history is also capped at the newest 500).
    var transcriptRetention: RetentionPeriod {
        get { defaults.string(forKey: "transcriptRetention").flatMap(RetentionPeriod.init) ?? .forever }
        set { defaults.set(newValue.rawValue, forKey: "transcriptRetention") }
    }

    /// Audio kept after the key comes up so the last word isn't clipped. No UI; tune with
    /// `defaults write com.divingsbysangam.sotto recordingTailMs -int 400`.
    var recordingTail: TimeInterval {
        let ms = defaults.object(forKey: "recordingTailMs") as? Int ?? 250
        return TimeInterval(min(max(ms, 0), 1000)) / 1000
    }

    /// N9: microphone by CoreAudio device UID; nil = system default.
    var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }

    /// N9: pause Music/Spotify while dictating (off by default; asks for Automation once).
    var pauseMediaWhileDictating: Bool {
        get { defaults.bool(forKey: "pauseMediaWhileDictating") }
        set { defaults.set(newValue, forKey: "pauseMediaWhileDictating") }
    }

    /// N6: the first-run setup was finished (or skipped). Re-runnable from Help.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// N7: one-time feature tips in the capsule.
    var tipsEnabled: Bool {
        get { defaults.object(forKey: "tipsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tipsEnabled") }
    }

    /// Tips already shown (each appears once).
    var shownTips: Set<String> {
        get { Set(defaults.stringArray(forKey: "shownTips") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "shownTips") }
    }

    var languageMode: DictationLanguageMode {
        get { defaults.string(forKey: "languageMode").flatMap(DictationLanguageMode.init(rawValue:)) ?? .english }
        set { defaults.set(newValue.rawValue, forKey: "languageMode") }
    }

    /// Whisper language codes ("en", "es", …), at most 3, used when `languageMode == .chosen`.
    var dictationLanguages: [String] {
        get { Array((defaults.stringArray(forKey: "dictationLanguages") ?? ["en"]).prefix(3)) }
        set { defaults.set(Array(newValue.prefix(3)), forKey: "dictationLanguages") }
    }

    /// N3: a lone modifier (Fn, right ⌥/⌘) as the dictation key. When set, it replaces the
    /// key-combo shortcut below. Fn also accepts ⌃⌥ for keyboards without Fn.
    var hotkeyModifierKey: ModifierKey? {
        get { defaults.string(forKey: "hotkeyModifierKey").flatMap(ModifierKey.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "hotkeyModifierKey") }
    }

    /// N4: tap this key while recording to switch the mode for that dictation. Nil = off.
    var modeCycleKey: ModifierKey? {
        get {
            guard let raw = defaults.string(forKey: "modeCycleKey") else { return .rightShift }
            return ModifierKey(rawValue: raw)  // "off" → nil
        }
        set { defaults.set(newValue?.rawValue ?? "off", forKey: "modeCycleKey") }
    }

    /// N1 Command mode: hold this shortcut with text selected, say an edit, release.
    var commandModeEnabled: Bool {
        get { defaults.object(forKey: "commandModeEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "commandModeEnabled") }
    }

    static let defaultCommandKeyCode = UInt32(kVK_Space)
    static let defaultCommandModifiers = NSEvent.ModifierFlags([.control, .shift]).rawValue

    var commandKeyCode: UInt32 {
        get { (defaults.object(forKey: "commandKeyCode") as? Int).map(UInt32.init) ?? Self.defaultCommandKeyCode }
        set { defaults.set(Int(newValue), forKey: "commandKeyCode") }
    }

    var commandModifiers: UInt {
        get { (defaults.object(forKey: "commandModifiers") as? Int).map(UInt.init) ?? Self.defaultCommandModifiers }
        set { defaults.set(Int(newValue), forKey: "commandModifiers") }
    }

    /// A lone modifier as the Command key instead of the combo above.
    var commandModifierKey: ModifierKey? {
        get { defaults.string(forKey: "commandModifierKey").flatMap(ModifierKey.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "commandModifierKey") }
    }

    var commandDisplayName: String {
        commandModifierKey?.displayName ?? Self.shortcutDisplayName(keyCode: commandKeyCode, modifiers: commandModifiers)
    }

    // Custom hotkey storage (key code and modifiers)
    var hotkeyKeyCode: UInt32 {
        get {
            let value = defaults.integer(forKey: "hotkeyKeyCode")
            // Default to Space (49) if not set
            return value == 0 ? 49 : UInt32(value)
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt {
        get {
            let value = defaults.integer(forKey: "hotkeyModifiers")
            // Default to Cmd+Shift if not set
            if value == 0 {
                return NSEvent.ModifierFlags([.command, .shift]).rawValue
            }
            return UInt(value)
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyModifiers") }
    }

    // "Paste last transcript" / "Copy last transcript" hotkeys. Defaults match Wispr Flow (⌃⌘V / ⌃⌘C).
    static let defaultPasteLastKeyCode = UInt32(kVK_ANSI_V)
    static let defaultCopyLastKeyCode = UInt32(kVK_ANSI_C)
    static let defaultTranscriptActionModifiers = NSEvent.ModifierFlags([.control, .command]).rawValue

    var pasteLastKeyCode: UInt32 {
        get { (defaults.object(forKey: "pasteLastKeyCode") as? Int).map(UInt32.init) ?? Self.defaultPasteLastKeyCode }
        set { defaults.set(Int(newValue), forKey: "pasteLastKeyCode") }
    }

    var pasteLastModifiers: UInt {
        get { (defaults.object(forKey: "pasteLastModifiers") as? Int).map(UInt.init) ?? Self.defaultTranscriptActionModifiers }
        set { defaults.set(Int(newValue), forKey: "pasteLastModifiers") }
    }

    var copyLastKeyCode: UInt32 {
        get { (defaults.object(forKey: "copyLastKeyCode") as? Int).map(UInt32.init) ?? Self.defaultCopyLastKeyCode }
        set { defaults.set(Int(newValue), forKey: "copyLastKeyCode") }
    }

    var copyLastModifiers: UInt {
        get { (defaults.object(forKey: "copyLastModifiers") as? Int).map(UInt.init) ?? Self.defaultTranscriptActionModifiers }
        set { defaults.set(Int(newValue), forKey: "copyLastModifiers") }
    }

    var customVocabulary: String {
        get { defaults.string(forKey: "customVocabulary") ?? "" }
        set { defaults.set(newValue, forKey: "customVocabulary") }
    }

    var vocabularyList: [String] {
        customVocabulary
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Vocabulary words from a text selection: split on commas and line breaks (commas separate
    /// stored words), whitespace collapsed, surrounding quotes/punctuation trimmed. Paragraph-
    /// sized pieces (over 4 words or 40 characters) are dropped: Vocabulary is for terms.
    static func vocabularyEntries(from selection: String) -> [String] {
        var seen = Set<String>()
        return selection
            .components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { piece in
                piece.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces).subtracting(CharacterSet(charactersIn: "+#")))
            }
            .filter { !$0.isEmpty && $0.count <= 40 && $0.split(separator: " ").count <= 4 }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Adds words that aren't already in Vocabulary (case-insensitive). Returns the ones added.
    @discardableResult
    func addToVocabulary(_ words: [String]) -> [String] {
        var existing = Set(vocabularyList.map { $0.lowercased() })
        let added = words.filter { existing.insert($0.lowercased()).inserted }
        if !added.isEmpty {
            customVocabulary = (vocabularyList + added).joined(separator: ", ")
        }
        return added
    }

    /// Vocabulary → Replacements, applied to every transcript before cleanup.
    var replacements: [TextReplacement] {
        get { decoded([TextReplacement].self, forKey: "vocabularyReplacements") ?? [] }
        set { encode(newValue, forKey: "vocabularyReplacements") }
    }

    /// Vocabulary → Snippets, expanded after cleanup so it never rewords them.
    var snippets: [TextSnippet] {
        get { decoded([TextSnippet].self, forKey: "vocabularySnippets") ?? [] }
        set { encode(newValue, forKey: "vocabularySnippets") }
    }

    /// Q10: fit the pasted text to the text around the cursor (casing, spacing, period).
    var matchCaretFormatting: Bool {
        get { defaults.object(forKey: "matchCaretFormatting") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "matchCaretFormatting") }
    }

    /// Q11: give cleanup the selected text and recently copied text as reference.
    var useSelectionAndClipboardContext: Bool {
        get { defaults.object(forKey: "useSelectionAndClipboardContext") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useSelectionAndClipboardContext") }
    }

    /// Spoken commands ("new line", "comma", "scratch that", spoken lists…). On by default.
    var voiceCommandsEnabled: Bool {
        get { defaults.object(forKey: "voiceCommandsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "voiceCommandsEnabled") }
    }

    private func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// Whisper fallback is always Turbo; optional engines have their own pinned models.
    var whisperModel: WhisperModel { .largev3Turbo }

    var speechEngine: SpeechEngineID {
        get { SpeechEngineID(rawValue: defaults.string(forKey: "speechEngine") ?? "") ?? .whisper }
        set { defaults.set(newValue.rawValue, forKey: "speechEngine") }
    }

    // MARK: - AI Enhancement (LLM Post-Processing)

    var enableLLMProcessing: Bool {
        get { defaults.object(forKey: "enableLLMProcessing") as? Bool ?? true }  // Enabled by default
        set { defaults.set(newValue, forKey: "enableLLMProcessing") }
    }

    var defaultInstructions: String {
        get {
            defaults.string(forKey: "defaultInstructions") ?? """
            Clean up the dictated text with minimal edits:
            - Fix punctuation and capitalization
            - Remove pure filler sounds (um, uh, erm) and obvious stutters
            - Keep every other word; do not paraphrase or reword
            - Keep the original meaning and tone
            """
        }
        set { defaults.set(newValue, forKey: "defaultInstructions") }
    }

    // MARK: - App-Specific Modes

    var appModes: [AppMode] {
        get {
            guard let data = defaults.data(forKey: "appModes"),
                  let modes = try? JSONDecoder().decode([AppMode].self, from: data) else {
                return AppMode.defaults
            }
            return modes
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: "appModes")
        }
    }

    /// Match order, each across all modes: exact app name, then the page URL's host (browsers, and
    /// web apps that expose an http(s) page), then loose app name. Exact first so a mode naming
    /// "Discord" beats the discord.com URL the Discord app exposes, and isn't shadowed by an
    /// earlier mode whose entry is merely a substring.
    func getMode(for app: SourceAppIdentity?, url: URL? = nil) -> AppMode? {
        let aiAvailable = LLMService.foundationModelsAvailable
        let enabled = appModes.filter { $0.isEnabled && (aiAvailable || !$0.requiresAppleIntelligence) }
        if let app, let mode = enabled.first(where: { $0.matchesApp(app, exact: true) }) {
            return mode
        }
        if let mode = enabled.first(where: { $0.matchesWebsite(url: url) }) {
            return mode
        }
        if let app, let mode = enabled.first(where: { $0.matchesApp(app, exact: false) }) {
            return mode
        }
        // N12: fall back to the bundled catalog's category for this site or app.
        if let category = AppCatalog.shared.category(for: app, url: url) {
            return enabled.first { $0.catalogCategories.contains(category.rawValue) }
        }
        return nil
    }

    func resetModesToDefaults() {
        defaults.removeObject(forKey: "appModes")
    }

    // MARK: - Later section (L1–L16)

    /// L16: apps where the caret dot is hidden (the capsule still shows). App names or bundle IDs,
    /// matched like App Modes' Matched Apps. Empty by default.
    var caretDotHiddenApps: [String] {
        get { defaults.stringArray(forKey: "caretDotHiddenApps") ?? [] }
        set { defaults.set(newValue, forKey: "caretDotHiddenApps") }
    }

    func hidesCaretDot(for app: SourceAppIdentity?) -> Bool {
        guard let app else { return false }
        return caretDotHiddenApps.contains { app.matches($0, exact: true) }
    }

    /// L13 read aloud: an AVSpeechSynthesisVoice identifier (nil = system default) and a 0.5×–2× rate.
    var readAloudVoiceID: String? {
        get { defaults.string(forKey: "readAloudVoiceID") }
        set { defaults.set(newValue, forKey: "readAloudVoiceID") }
    }

    var readAloudRate: Double {
        get { defaults.object(forKey: "readAloudRate") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "readAloudRate") }
    }

    /// L12: an extra dictation trigger on a mouse button (2 = middle, 3 = back, 4 = forward);
    /// nil = off. Click = hands-free toggle, hold = push-to-talk. The button's own click is consumed.
    var dictationMouseButton: Int? {
        get { defaults.object(forKey: "dictationMouseButton") as? Int }
        set { defaults.set(newValue, forKey: "dictationMouseButton") }
    }

    static let mouseButtonChoices: [(number: Int, name: String)] = [(2, "Middle button"), (3, "Back button"), (4, "Forward button")]

    static func mouseButtonName(_ number: Int) -> String {
        mouseButtonChoices.first { $0.number == number }?.name ?? "Button \(number + 1)"
    }

    /// L15: count typed characters per day (two numbers, nothing else) for the Dashboard's
    /// voice-vs-keyboard comparison. Off by default; needs Input Monitoring.
    var countTypingEnabled: Bool {
        get { defaults.bool(forKey: "countTypingEnabled") }
        set { defaults.set(newValue, forKey: "countTypingEnabled") }
    }

    /// L7: open the Scratchpad and dictate into a note (press again to stop). Default ⌃⌥N.
    static let defaultScratchpadKeyCode = UInt32(kVK_ANSI_N)
    static let defaultScratchpadModifiers = NSEvent.ModifierFlags([.control, .option]).rawValue

    var scratchpadKeyCode: UInt32 {
        get { (defaults.object(forKey: "scratchpadKeyCode") as? Int).map(UInt32.init) ?? Self.defaultScratchpadKeyCode }
        set { defaults.set(Int(newValue), forKey: "scratchpadKeyCode") }
    }

    var scratchpadModifiers: UInt {
        get { (defaults.object(forKey: "scratchpadModifiers") as? Int).map(UInt.init) ?? Self.defaultScratchpadModifiers }
        set { defaults.set(Int(newValue), forKey: "scratchpadModifiers") }
    }

    /// L2: after a paste, notice words fixed by hand and offer them for Vocabulary. Off by default.
    var learnFromCorrections: Bool {
        get { defaults.bool(forKey: "learnFromCorrections") }
        set { defaults.set(newValue, forKey: "learnFromCorrections") }
    }

    /// L2: fixes the user dismissed ("original→Corrected"); not offered again. Newest 200.
    var ignoredCorrections: [String] {
        get { defaults.stringArray(forKey: "ignoredCorrections") ?? [] }
        set { defaults.set(Array(newValue.suffix(200)), forKey: "ignoredCorrections") }
    }

    /// Adds a replacement, or updates the one with the same spoken phrase.
    func upsertReplacement(spoken: String, written: String) {
        let key = spoken.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !written.isEmpty else { return }
        var list = replacements
        if let index = list.firstIndex(where: { $0.spoken.caseInsensitiveCompare(key) == .orderedSame }) {
            list[index].written = written
        } else {
            list.append(TextReplacement(spoken: key, written: written))
        }
        replacements = list
    }

    /// L11: in Xcode / VS Code / Cursor / Windsurf, write spoken file names from the open
    /// project exactly ("app state dot swift" → AppState.swift). On by default.
    var resolveFileNamesInEditors: Bool {
        get { defaults.object(forKey: "resolveFileNamesInEditors") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "resolveFileNamesInEditors") }
    }

    /// L1: show the words heard so far in the capsule while recording. Off by default: the
    /// preview shares the model with the final pass (see CLAUDE.md for measured cost).
    var liveTextEnabled: Bool {
        get { defaults.bool(forKey: "liveTextEnabled") }
        set { defaults.set(newValue, forKey: "liveTextEnabled") }
    }

    /// L5: use the downloaded local cleanup model when Apple Intelligence isn't available.
    var localLLMEnabled: Bool {
        get { defaults.object(forKey: "localLLMEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "localLLMEnabled") }
    }

    /// L6: the coding-agent voice relay (off by default). Turning it off is the kill switch.
    var agentRelayEnabled: Bool {
        get { defaults.bool(forKey: "agentRelayEnabled") }
        set { defaults.set(newValue, forKey: "agentRelayEnabled") }
    }

    /// How long a finished agent waits for a spoken reply before it just stops.
    var agentRelayTimeout: TimeInterval {
        get { defaults.object(forKey: "agentRelayTimeout") as? Double ?? AgentRelay.defaultReplyTimeout }
        set { defaults.set(newValue, forKey: "agentRelayTimeout") }
    }

    static let defaultReadLastKeyCode = UInt32(kVK_ANSI_R)

    var readLastKeyCode: UInt32 {
        get { (defaults.object(forKey: "readLastKeyCode") as? Int).map(UInt32.init) ?? Self.defaultReadLastKeyCode }
        set { defaults.set(Int(newValue), forKey: "readLastKeyCode") }
    }

    var readLastModifiers: UInt {
        get { (defaults.object(forKey: "readLastModifiers") as? Int).map(UInt.init) ?? Self.defaultTranscriptActionModifiers }
        set { defaults.set(Int(newValue), forKey: "readLastModifiers") }
    }

    // MARK: - System Settings

    var launchAtLogin: Bool {
        get { defaults.object(forKey: "launchAtLogin") as? Bool ?? true }  // Default on: always-on app
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    var showDockIcon: Bool {
        get { defaults.object(forKey: "showDockIcon") as? Bool ?? true }  // Default to showing dock icon
        set { defaults.set(newValue, forKey: "showDockIcon") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default OFF: screen OCR is optional and has crashed dictation in the past.
        if defaults.object(forKey: "enableScreenContext") == nil {
            defaults.set(false, forKey: "enableScreenContext")
        }

        // One-time migration: turn screen context off for existing installs after the
        // OCR continuation crash fix so stop→transcribe→paste works without opting in.
        let ocrCrashFixMigrationKey = "didDisableScreenContextAfterOCRCrashFix"
        if defaults.object(forKey: ocrCrashFixMigrationKey) == nil {
            defaults.set(false, forKey: "enableScreenContext")
            defaults.set(true, forKey: ocrCrashFixMigrationKey)
        }

        // Single-model migration: earlier versions stored a WhisperKit model choice, a
        // SwiftWhisper engine/model choice, and a download flag. The model is now fixed and
        // readiness is checked on disk, so drop the stale keys.
        if let stored = defaults.string(forKey: "whisperModel"),
           stored != WhisperModel.largev3Turbo.rawValue {
            NSLog("[AppSettings] Migrating stored Whisper model %@ -> %@", stored, WhisperModel.largev3Turbo.rawValue)
        }
        for key in ["whisperModel", "localEngine", "swiftWhisperModel", "isLocalModelDownloaded"] {
            defaults.removeObject(forKey: key)
        }

        // Hold vs Hands-free is no longer a setting: one hotkey handles hold, double-tap, and
        // hold+Space (HotkeyGestureClassifier). Both old modes' gestures still work.
        defaults.removeObject(forKey: "shortcutMode")

        // Meeting recording was removed.
        for key in ["meetingSystemAudio", "meetingDetection", "meetingSpeakerCount"] {
            defaults.removeObject(forKey: key)
        }

        // One-time migration: saved built-in modes predate URL matching and its expanded website
        // lists (e.g. mail.google.com); modes saved before websites existed have none at all.
        // Add every missing default entry, keeping the user's own entries.
        let websiteDefaultsMigrationKey = "didAddURLMatchingWebsiteDefaults"
        if defaults.object(forKey: websiteDefaultsMigrationKey) == nil {
            if defaults.data(forKey: "appModes") != nil {
                var modes = appModes
                for index in modes.indices where modes[index].isBuiltIn {
                    guard let builtIn = AppMode.defaults.first(where: { $0.displayName == modes[index].displayName }) else { continue }
                    let existing = Set(modes[index].matchedWebsites.map { $0.lowercased() })
                    let added = builtIn.matchedWebsites.filter { !existing.contains($0.lowercased()) }
                    modes[index].matchedWebsites.append(contentsOf: added)
                }
                appModes = modes
            }
            defaults.set(true, forKey: websiteDefaultsMigrationKey)
        }

        // One-time migration: add the built-in Prompt mode at the top (so it wins Cursor over
        // Code) for installs with saved modes, keeping every existing and custom mode.
        let promptModeMigrationKey = "didAddPromptMode"
        if defaults.object(forKey: promptModeMigrationKey) == nil {
            if defaults.data(forKey: "appModes") != nil {
                var modes = appModes
                if !modes.contains(where: { $0.isBuiltIn && $0.displayName == AppMode.promptMode.displayName }) {
                    modes.insert(AppMode.promptMode, at: 0)
                    appModes = modes
                }
            }
            defaults.set(true, forKey: promptModeMigrationKey)
        }

        // N6: installs that were already set up (a shortcut or modes were saved) skip the
        // first-run setup; it stays available from Help › Getting Started.
        if defaults.object(forKey: "hasCompletedOnboarding") == nil {
            let alreadySetUp = defaults.object(forKey: "hotkeyKeyCode") != nil || defaults.data(forKey: "appModes") != nil
            defaults.set(alreadySetUp, forKey: "hasCompletedOnboarding")
        }

        // One-time migration (N5/N12): saved built-in modes get the shipped example pairs and
        // catalog categories. Renamed built-ins get a category from the apps they list.
        let examplesMigrationKey = "didAddModeExamplesAndCategories"
        if defaults.object(forKey: examplesMigrationKey) == nil {
            if defaults.data(forKey: "appModes") != nil {
                var modes = appModes
                for index in modes.indices where modes[index].isBuiltIn {
                    let shipped = AppMode.defaults.first { $0.displayName == modes[index].displayName }
                    if modes[index].promptExamples.isEmpty, let shipped {
                        modes[index].promptExamples = shipped.promptExamples
                    }
                    if modes[index].catalogCategories.isEmpty {
                        if let shipped {
                            modes[index].catalogCategories = shipped.catalogCategories
                        } else if let category = AppCatalog.shared.likelyCategory(forAppNames: modes[index].matchedApps) {
                            modes[index].catalogCategories = [category.rawValue]
                        }
                    }
                }
                appModes = modes
            }
            defaults.set(true, forKey: examplesMigrationKey)
        }
    }
}
