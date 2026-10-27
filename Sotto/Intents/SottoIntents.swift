import AppIntents
import Foundation

/// N15: Shortcuts / Spotlight actions. All local: they call into the running app.
struct SottoIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static let notRunning = SottoIntentError(message: "Sotto isn't running.")
}

@MainActor
private func sotto() throws -> AppState {
    guard let app = AppState.current else { throw SottoIntentError.notRunning }
    return app
}

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Starts a Sotto dictation into the frontmost app. Tap your shortcut or run Stop Dictation to finish.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try sotto().startDictationFromAutomation()
        return .result()
    }
}

struct StopDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription("Stops the current Sotto dictation and pastes the transcript.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try sotto().stopDictationFromAutomation()
        return .result()
    }
}

struct ModeOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        try sotto().modeNames
    }
}

struct SwitchModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Mode"
    static let description = IntentDescription("Sets the App Mode for the current dictation, or for the next one if none is running.")

    @Parameter(title: "Mode", optionsProvider: ModeOptions())
    var mode: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard try sotto().selectMode(named: mode) else {
            throw SottoIntentError(message: "No mode named “\(mode)”.")
        }
        return .result()
    }
}

struct PasteLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Last Transcript"
    static let description = IntentDescription("Pastes the latest transcript into the frontmost app and restores the clipboard.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try sotto().pasteLastTranscript(fromMenu: false)
        return .result()
    }
}

struct GetLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Transcript"
    static let description = IntentDescription("Returns the text of the latest transcript.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let text = try sotto().lastSavedTranscript else {
            throw SottoIntentError(message: "There's no transcript yet.")
        }
        return .result(value: text)
    }
}

struct SottoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDictationIntent(), phrases: ["Start dictation with \(.applicationName)"], shortTitle: "Start Dictation", systemImageName: "mic")
        AppShortcut(intent: StopDictationIntent(), phrases: ["Stop \(.applicationName) dictation"], shortTitle: "Stop Dictation", systemImageName: "stop.circle")
        AppShortcut(intent: PasteLastTranscriptIntent(), phrases: ["Paste last \(.applicationName) transcript"], shortTitle: "Paste Last Transcript", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: GetLastTranscriptIntent(), phrases: ["Get last \(.applicationName) transcript"], shortTitle: "Get Last Transcript", systemImageName: "text.quote")
    }
}
