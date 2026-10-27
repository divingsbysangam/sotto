import AppKit
import XCTest
@testable import Sotto

final class RedesignLifecycleTests: XCTestCase {
    func testListenerStylePreservesExistingValuesAndPersistsDotChoice() {
        let name = "com.sotto.listener-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.recordingUIStyle, .minimal)
        defaults.set("floating", forKey: "recordingUIStyle")
        XCTAssertEqual(settings.recordingUIStyle, .floating)
        settings.recordingUIStyle = .dot
        XCTAssertEqual(AppSettings(defaults: defaults).recordingUIStyle, .dot)
        XCTAssertEqual(RecordingUIStyle.minimal.rawValue, "minimal")
    }

    func testBottomAndDotPlacementRespectDockEdgesAndNegativeDisplayCoordinates() {
        let bounds = CGRect(x: -1440, y: 60, width: 1440, height: 840)
        let bottom = RecordingIndicatorPlacement.bottomOrigin(in: bounds, size: .init(width: 320, height: 80))
        XCTAssertEqual(bottom.y, 80)
        XCTAssertEqual(bottom.x + 160, bounds.midX)
        let dot = RecordingIndicatorPlacement.dotOrigin(at: .init(x: -1, y: 61), visibleFrame: bounds, size: .init(width: 24, height: 24))
        XCTAssertGreaterThanOrEqual(dot.y, bounds.minY + 4)
        XCTAssertLessThanOrEqual(dot.x + 24, bounds.maxX - 4)
        let top = RecordingIndicatorPlacement.dotOrigin(at: .init(x: -1440, y: 1000), visibleFrame: bounds, size: .init(width: 24, height: 24))
        XCTAssertGreaterThanOrEqual(top.x, bounds.minX + 4)
        XCTAssertLessThanOrEqual(top.y + 24, bounds.maxY - 4)
    }
    func testVocabularyInputPreservesSpellingAndOrderWithoutDuplicateRows() {
        XCTAssertEqual(VocabularyInput.additions(from: "  Sotto, Core ML,\nCore ML, Telugu, ", existing: ["sotto"]), ["Core ML", "Telugu"])
        XCTAssertTrue(VocabularyInput.additions(from: " , \n", existing: []).isEmpty)
        XCTAssertTrue(VocabularyInput.additions(from: "SOTTO", existing: ["Sotto"]).isEmpty)
    }

    @MainActor func testNoteEditorFlushPersistsPendingTextAndReportsFailureWithoutLosingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(HistoryStore(url: root.appendingPathComponent("notes.sqlite")))
        let notes = NotesManager(store: store)
        let note = notes.create()
        notes.setText("Synthetic editor draft", for: note.id)
        XCTAssertEqual(notes.saveState, .pending)
        notes.flush()
        XCTAssertEqual(notes.saveState, .saved)
        XCTAssertEqual(store.loadNotes().first?.text, "Synthetic editor draft")
        let unavailable = NotesManager(store: nil)
        let unsaved = unavailable.create()
        unavailable.setText("Keep this text in memory", for: unsaved.id)
        unavailable.flush()
        unavailable.flush()
        XCTAssertEqual(unavailable.saveState, .failed)
        XCTAssertEqual(unavailable.note(unsaved.id)?.text, "Keep this text in memory")
    }

    @MainActor func testTranscriptRawCleanedAndVersionActionsRemainLiveAfterReprocessing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "com.sotto.redesign-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try XCTUnwrap(HistoryStore(url: root.appendingPathComponent("history.sqlite")))
        let entry = TranscriptionEntry(text: "Cleaned sample.", duration: 2, outputMethod: .notPasted,
                                       rawText: "raw sample", cleanedText: "Cleaned sample.")
        XCTAssertTrue(store.saveAll([entry]))
        let history = TranscriptionHistoryManager(directory: root, defaults: defaults)
        history.setShowsRaw(true, for: entry)
        XCTAssertEqual(history.entries.first?.text, "raw sample")
        XCTAssertEqual(history.entries.first?.isShowingRaw, true)
        history.replaceResult(for: entry.id, text: "Reprocessed sample.", rawText: "new raw", cleanedText: "Reprocessed sample.", modeName: "Default", timings: nil, reason: "Re-transcribed")
        XCTAssertFalse(history.versions(of: entry.id).isEmpty)
        XCTAssertEqual(history.entries.first?.text, "Reprocessed sample.")
        XCTAssertEqual(history.search("Reprocessed").first?.id, entry.id)
        let reloaded = TranscriptionHistoryManager(directory: root, defaults: defaults)
        XCTAssertEqual(reloaded.entries.first?.text, "Reprocessed sample.")
    }

    func testRecordingStatusDoesNotTurnWarningsOrProcessingIntoSuccess() {
        XCTAssertEqual(RecordingOverlayStatus.make(isProcessing: false, message: "✓ Old outcome").title, "Listening")
        XCTAssertEqual(RecordingOverlayStatus.make(isProcessing: true, message: "").title, "Preparing your transcript…")
        XCTAssertEqual(RecordingOverlayStatus.make(isProcessing: true, message: "⚠︎ Copied — app changed").symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(RecordingOverlayStatus.make(isProcessing: true, message: "✓ Saved").title, "Saved")
    }

    @MainActor func testOldHideCompletionsCannotDismissNewCapsuleOrCursor() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Window Server is unavailable") }
        let capsule = NotchCapsuleWindow()
        let cursor = CursorIndicatorWindow()
        defer { capsule.orderOut(nil); cursor.orderOut(nil) }
        capsule.show()
        capsule.hide()
        capsule.showPrompt(.init(icon: "checkmark.circle", text: "Synthetic newer notice", actions: []))
        cursor.show(at: .init(x: 100, y: 100))
        cursor.hide()
        cursor.show(at: .init(x: 100, y: 100))
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(capsule.isShowingPrompt)
        XCTAssertTrue(cursor.isVisible)
        XCTAssertFalse(capsule.canBecomeKey)
        XCTAssertFalse(cursor.canBecomeKey)
        XCTAssertTrue(capsule.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor func testFloatingCountdownSurvivesAudioUpdatesAndDeliversExactlyOnce() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Window Server is unavailable") }
        let window = FloatingDictationWindow()
        defer { window.hide() }
        var pasted = 0
        window.configure(onCancel: {}, onPasteNow: { pasted += 1 })
        window.show(state: .readyToPaste(text: "Synthetic countdown"))
        let originalContent = window.contentView
        for index in 0..<12 {
            window.updateAudioLevel(Float(index) / 12)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertTrue(originalContent === window.contentView)
        try await Task.sleep(nanoseconds: 3_200_000_000)
        XCTAssertEqual(pasted, 1)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor func testFloatingOldCountdownCannotPasteIntoNewRecording() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("Window Server is unavailable") }
        let window = FloatingDictationWindow()
        defer { window.hide() }
        var pasted = 0
        window.configure(onCancel: {}, onPasteNow: { pasted += 1 })
        window.show(state: .readyToPaste(text: "Old synthetic transcript"))
        try await Task.sleep(nanoseconds: 300_000_000)
        window.hide()
        window.show(state: .recording)
        try await Task.sleep(nanoseconds: 3_100_000_000)
        XCTAssertEqual(pasted, 0)
        XCTAssertTrue(window.isVisible)
    }
}
