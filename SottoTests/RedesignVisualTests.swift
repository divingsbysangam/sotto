import AppKit
import SwiftUI
import XCTest
@testable import Sotto

/// Opt-in captures of actual product views, using the app's fully isolated test environment.
/// No microphone capture, startup services, real history or general clipboard operations.
final class RedesignVisualTests: XCTestCase {
    @MainActor func testCaptureWorkflowReviewMatrix() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOTTO_REDESIGN_CAPTURE_DIR"],
              !path.isEmpty, !path.contains("$(") else { throw XCTSkip("UI review captures are opt-in") }
        XCTAssertEqual(ProcessInfo.processInfo.environment["SOTTO_TESTING"], "1")
        XCTAssertTrue(AudioArchive.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        guard NSScreen.main != nil else { throw XCTSkip("Window Server is unavailable") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState()
        let settings = AppSettings.shared
        let history = TranscriptionHistoryManager.shared
        settings.customVocabulary = "Sotto, Core ML, Telugu"
        settings.recordingUIStyle = .dot
        settings.languageMode = .auto
        let entry = TranscriptionEntry(text: "Please send the revised outline after lunch.", duration: 4,
            sourceApp: "Notes", outputMethod: .clipboard, rawText: "please send revised outline after lunch",
            cleanedText: "Please send the revised outline after lunch.", modeName: "Default")
        let second = TranscriptionEntry(text: "A quieter workspace starts with knowing what needs your attention.", duration: 5,
            sourceApp: "Scratchpad", outputMethod: .scratchpad)
        try FileManager.default.createDirectory(at: AudioArchive.directory, withIntermediateDirectories: true)
        let audioName = "redesign-review.wav"
        try silentWAV().write(to: AudioArchive.directory.appendingPathComponent(audioName))
        let failed = TranscriptionEntry(text: "", duration: 1, sourceApp: "Imported recording", outputMethod: .notPasted,
            audioFileName: audioName, failureReason: "The speech model could not finish this synthetic transcript.")
        [entry, second, failed].forEach(history.addEntry)
        history.replaceResult(for: entry.id, text: entry.text, rawText: entry.rawText, cleanedText: entry.cleanedText,
                              modeName: "Default", timings: nil, reason: "Re-cleaned sample")
        let note = NotesManager.shared.create()
        NotesManager.shared.setText("Today's ideas\n\nMake the next step easy to see.", for: note.id)
        NotesManager.shared.flush()
        defer {
            [entry, second, failed].forEach(history.deleteEntry)
            NotesManager.shared.delete(note.id)
        }

        func main(_ route: SottoRoute) -> AnyView {
            let navigation = SottoNavigation()
            navigation.open(route)
            return AnyView(MainWindowView(appState: state, settings: settings, onSave: nil, navigation: navigation))
        }
        let meter = CapsuleLevel(value: 0.65)
        let floating = FloatingDictationModel()
        let cases: [(String, AnyView, CGSize, Bool)] = [
            ("dashboard-500-light", main(.destination(.dashboard)), .init(width: 500, height: 400), false),
            ("dashboard-700-light", main(.destination(.dashboard)), .init(width: 700, height: 500), false),
            ("dashboard-1100-dark", main(.destination(.dashboard)), .init(width: 1100, height: 750), true),
            ("transcripts-selected", AnyView(HistoryTab(appState: state, selectedID: entry.id)), .init(width: 700, height: 620), false),
            ("transcripts-failed-retry", AnyView(HistoryTab(appState: state, selectedID: failed.id)), .init(width: 700, height: 620), true),
            ("transcript-details", AnyView(TranscriptDetailView(entryID: entry.id, historyManager: history, appState: state)), .init(width: 600, height: 680), false),
            ("app-modes", main(.destination(.appModes)), .init(width: 700, height: 650), false),
            ("mode-editor", AnyView(ModeEditorSheet(mode: settings.appModes[0], isNew: false, onSave: { _ in })), .init(width: 560, height: 650), true),
            ("vocabulary", main(.destination(.vocabulary)), .init(width: 700, height: 500), false),
            ("settings-general", main(.settings(.general)), .init(width: 700, height: 650), false),
            ("settings-speech", main(.settings(.transcription)), .init(width: 700, height: 650), true),
            ("settings-system", main(.settings(.system)), .init(width: 700, height: 650), false),
            ("help", main(.destination(.help)), .init(width: 700, height: 500), false),
            ("scratchpad", AnyView(ScratchpadView(appState: state)), .init(width: 760, height: 480), true),
            ("onboarding-microphone", AnyView(OnboardingView(appState: state, onFinish: {})), .init(width: 520, height: 500), false),
            ("onboarding-screen-context", AnyView(OnboardingView(appState: state, initialStep: 4, onFinish: {})), .init(width: 520, height: 500), true),
            ("bottom-listener", AnyView(NotchCapsuleView(level: meter, isProcessing: false, modeName: "Default", liveText: "Let’s keep the first version small…").padding(24)), .init(width: 520, height: 220), true),
            ("dot-listener", AnyView(CursorIndicatorView(isProcessing: false).frame(maxWidth: .infinity, maxHeight: .infinity)), .init(width: 180, height: 100), false),
            ("floating-listener", AnyView(FloatingDictationView(model: floating, level: meter, onCancel: {}, onPasteNow: {}).padding(20)), .init(width: 380, height: 340), false),
            ("menu-bar", AnyView(MenuBarView(appState: state, onOpenSettings: {}, onOpenHistory: {}, onNavigate: { _ in })), .init(width: 340, height: 740), false)
        ]
        for (name, view, size, dark) in cases {
            try await capture(view, named: name, size: size, dark: dark, directory: directory)
        }
        TranscriptionEngineManager.shared.select(.parakeet)
        try await capture(main(.settings(.transcription)), named: "settings-fallback", size: .init(width: 700, height: 650), dark: false, directory: directory)
        TranscriptionEngineManager.shared.select(.whisper)
    }

    @MainActor private func capture(_ view: AnyView, named name: String, size: CGSize, dark: Bool, directory: URL) async throws {
        let host = NSHostingController(rootView: view.preferredColorScheme(dark ? .dark : .light).tint(SottoDesign.accent).groupBoxStyle(SottoGroupBoxStyle()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = host
        window.title = "Sotto · Synthetic UI review"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setContentSize(size)
        window.center()
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 700_000_000)
        // Render our own view tree. Never call screencapture/ScreenCaptureKit here: a hosted
        // XCTest app has a different signing requirement and must not ask for new TCC grants.
        host.view.layoutSubtreeIfNeeded()
        host.view.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func silentWAV() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(32_036)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000)); number(UInt32(32_000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(32_000))
        data.append(Data(count: 32_000))
        return data
    }
}
