import AppKit
import Observation
import XCTest
@testable import Sotto

final class DictationPresentationTests: XCTestCase {
    private func presentation(
        recording: RecordingState = .idle,
        phase: SpeechEnginePhase = .ready,
        microphone: Bool = true,
        accessibility: Bool = true,
        error: String? = nil,
        output: DictationOutput? = nil
    ) -> DictationPresentation {
        .make(recording: recording, processingStatus: "Cleaning…", microphoneAllowed: microphone,
              accessibilityAllowed: accessibility, engineName: "Whisper Turbo", enginePhase: phase,
              progress: 0.4, fallbackNotice: nil, error: error, output: output)
    }

    func testActiveOperationWinsOverOldFeedbackAndReadiness() {
        let listening = presentation(recording: .recording, phase: .failed("Model error"), microphone: false, error: "Previous failure", output: .output(.pasted))
        XCTAssertEqual(listening.primary.status.title, "Listening")
        XCTAssertNil(listening.readiness)
        let processing = presentation(recording: .processing, phase: .notInstalled, microphone: false, output: .output(.copied))
        XCTAssertEqual(processing.primary.status.detail, "Cleaning…")
        XCTAssertNil(processing.readiness)
    }

    func testReadinessSeparatesEveryModelPhaseAndPermissionRecovery() {
        let cases: [(SpeechEnginePhase, String)] = [
            (.notInstalled, "Speech model not installed"), (.idle, "Speech model not loaded"),
            (.downloading, "Downloading speech model"), (.verifying, "Verifying speech model"),
            (.loading, "Loading speech model"), (.failed("Corrupt model"), "Speech model needs attention"),
            (.ready, "Ready to dictate")
        ]
        for (phase, title) in cases { XCTAssertEqual(presentation(phase: phase).primary.status.title, title) }
        XCTAssertEqual(presentation(microphone: false).primary.route, .settings(.system))
        XCTAssertEqual(presentation(phase: .failed("Corrupt model")).primary.route, .settings(.transcription))
        XCTAssertEqual(presentation(phase: .downloading).primary.status.progress, 0.4)
        let fallback = presentation(accessibility: false)
        XCTAssertEqual(fallback.primary.status.title, "Ready to dictate")
        XCTAssertTrue(fallback.primary.status.detail.contains("Clipboard output is available"))
        XCTAssertEqual(fallback.primary.route, .settings(.system))
    }

    func testActualOutcomesDoNotClaimPasteOrPersistenceAfterFailure() {
        for outcome in [OutputService.Outcome.copied, .copiedMissingAccessibility, .copiedAppChanged, .copiedPasteFailed] {
            XCTAssertEqual(presentation(output: .output(outcome)).primary.status.title, "Copied to clipboard")
        }
        XCTAssertEqual(presentation(output: .output(.pasted)).primary.status.title, "Pasted")
        XCTAssertEqual(presentation(output: .output(.failed)).primary.route, .destination(.transcripts))
        XCTAssertEqual(presentation(output: .output(.cancelled)).primary.status.title, "Ready to dictate")
        XCTAssertEqual(presentation(output: .scratchpadSaved).primary.status.title, "Saved to Scratchpad")
        XCTAssertEqual(presentation(output: .scratchpadUnsaved).primary.status.title, "Scratchpad could not save")
        XCTAssertNotNil(presentation(output: .output(.pasted)).readiness)
    }

    func testFailureShowsRecoveryBeforeReadiness() {
        let failure = presentation(phase: .loading, error: "Recording interrupted")
        XCTAssertEqual(failure.primary.status.detail, "Recording interrupted")
        XCTAssertEqual(failure.primary.route, .destination(.transcripts))
        XCTAssertEqual(failure.readiness?.status.title, "Loading speech model")
    }

    func testFeedbackClearsAtStartAndRejectsLateCompletions() {
        let feedback = DictationFeedback()
        let first = feedback.begin()
        XCTAssertTrue(feedback.complete(.output(.copied), for: first))
        let second = feedback.begin()
        XCTAssertNil(feedback.result)
        XCTAssertFalse(feedback.complete(.output(.pasted), for: first))
        XCTAssertNil(feedback.result)
        XCTAssertTrue(feedback.complete(.scratchpadSaved, for: second))
        XCTAssertEqual(feedback.result, .scratchpadSaved)
    }

    func testDestinationRequestsPersistBeforeOpeningAndChangeSettingsWhileVisible() {
        let navigation = SottoNavigation()
        navigation.open(.destination(.transcripts))
        XCTAssertEqual(navigation.destination, .transcripts)
        navigation.open(.settings(.system))
        XCTAssertEqual(navigation.destination, .settings)
        XCTAssertEqual(navigation.settingsSection, .system)
        navigation.open(.settings(.transcription))
        XCTAssertEqual(navigation.settingsSection, .transcription)
        navigation.open(.destination(.dashboard))
        navigation.open(.destination(.settings))
        XCTAssertEqual(navigation.settingsSection, .transcription)
        XCTAssertEqual(SottoDestination.allCases.count, 6)
    }

    @MainActor func testEffectiveEngineReadinessUsesFallbackRatherThanSelectedModel() {
        let (settings, _) = isolatedSettings()
        settings.speechEngine = .parakeet
        settings.languageMode = .auto
        let whisper = FakeSpeechEngine(.whisper)
        whisper.phase = .ready
        let parakeet = FakeSpeechEngine(.parakeet)
        parakeet.phase = .notInstalled
        let manager = TranscriptionEngineManager(settings: settings, engines: [.whisper: whisper, .parakeet: parakeet])
        let shown = DictationPresentation.make(recording: .idle, processingStatus: "", microphoneAllowed: true, accessibilityAllowed: true,
                                              engineName: manager.effectiveID.displayName, enginePhase: manager.engine(for: manager.effectiveID).phase,
                                              progress: 0, fallbackNotice: manager.fallbackNotice, error: nil, output: nil)
        XCTAssertEqual(shown.primary.status.title, "Ready to dictate")
        XCTAssertTrue(shown.primary.status.detail.contains("Whisper"))
        whisper.phase = .failed("Missing fallback")
        XCTAssertEqual(manager.engine(for: manager.effectiveID).phase, .failed("Missing fallback"))
    }

    @MainActor func testCopyOutputAndFeedbackUseRealIsolatedPasteboard() async {
        let (settings, _) = isolatedSettings()
        settings.outputMode = .clipboard
        let board = NSPasteboard(name: .init("com.sotto.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let service = OutputService(settings: settings, pasteboard: board)
        let feedback = DictationFeedback()
        let generation = feedback.begin()
        let outcome = await service.output(text: "Synthetic output")
        XCTAssertTrue(feedback.complete(.output(outcome), for: generation))
        XCTAssertEqual(board.string(forType: .string), "Synthetic output")
        XCTAssertEqual(presentation(output: feedback.result).primary.status.title, "Copied to clipboard")
        let cancelled = await service.output(text: "Must not be written", shouldProceed: { false })
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(board.string(forType: .string), "Synthetic output")
    }

    @MainActor func testHistoryObservationAndStatisticsTrackRealStoreMutations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, defaults) = isolatedSettings()
        let entry = TranscriptionEntry(text: "three sample words", duration: 3, outputMethod: .clipboard)
        let store = try XCTUnwrap(HistoryStore(url: root.appendingPathComponent("history.sqlite")))
        XCTAssertTrue(store.saveAll([entry]))
        let history = TranscriptionHistoryManager(directory: root, defaults: defaults)
        var changed = false
        withObservationTracking {
            _ = history.entries
            _ = history.getStatistics()
        } onChange: { changed = true }
        // Reprocessing exercises Observation, SQLite, FTS and statistics without running the
        // live audio-retention job (which intentionally operates on the user's audio folder).
        history.replaceResult(for: entry.id, text: "five clean synthetic sample words", rawText: nil,
                              cleanedText: nil, modeName: nil, timings: nil, reason: "Test")
        XCTAssertTrue(changed)
        XCTAssertEqual(history.entries.first?.id, entry.id)
        XCTAssertEqual(history.getStatistics().totalWords, 5)
        history.deleteEntry(entry)
        XCTAssertEqual(history.getStatistics().totalWords, 0)
        XCTAssertTrue(TranscriptionHistoryManager(directory: root, defaults: defaults).entries.isEmpty)
    }

    @MainActor func testScratchpadSuccessRequiresRealSQLiteWriteAndFailureKeepsText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(HistoryStore(url: root.appendingPathComponent("notes.sqlite")))
        let notes = NotesManager(store: store)
        let id = notes.dictationTarget()
        XCTAssertTrue(notes.append("First sentence.", to: id))
        XCTAssertTrue(notes.append("Second sentence.", to: id))
        XCTAssertEqual(store.loadNotes().first?.text, "First sentence.\n\nSecond sentence.")
        let unavailable = NotesManager(store: nil)
        let unsavedID = unavailable.dictationTarget()
        let saved = unavailable.append("Still available in memory.", to: unsavedID)
        XCTAssertFalse(saved)
        XCTAssertEqual(unavailable.note(unsavedID)?.text, "Still available in memory.")
        XCTAssertEqual(presentation(output: saved ? .scratchpadSaved : .scratchpadUnsaved).primary.status.title, "Scratchpad could not save")
    }

    private func isolatedSettings() -> (AppSettings, UserDefaults) {
        let name = "com.sotto.presentation-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (AppSettings(defaults: defaults), defaults)
    }
}
