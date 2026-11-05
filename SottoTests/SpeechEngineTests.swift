import AppKit
import AVFoundation
import XCTest
@testable import Sotto

final class SpeechEngineTests: XCTestCase {
    private func isolatedSettings() -> AppSettings {
        let name = "com.divingsbysangam.sotto.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppSettings(defaults: defaults)
    }

    func testRemovedEnginePreferenceMigratesToWhisper() {
        let name = "com.divingsbysangam.sotto.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cohere", forKey: "speechEngine")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.speechEngine, .whisper)
        _ = TranscriptionEngineManager(settings: settings, engines: [.whisper: FakeSpeechEngine()])
        XCTAssertEqual(defaults.string(forKey: "speechEngine"), "whisper")
    }

    @MainActor func testOperationKeepsWhisperUntilCompletion() async throws {
        let engine = FakeSpeechEngine()
        let manager = TranscriptionEngineManager(settings: isolatedSettings(), engines: [.whisper: engine])
        let operation = manager.beginOperation()
        XCTAssertEqual(operation.engineID, .whisper)
        XCTAssertEqual(manager.operationCount, 1)
        _ = try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused"), engineID: operation.engineID)
        XCTAssertEqual(engine.calls, 1)
        manager.endOperation(operation)
        XCTAssertEqual(manager.operationCount, 0)
    }

    @MainActor func testCancellationDiscardsLateResultAndReleasesGate() async throws {
        let engine = FakeSpeechEngine()
        engine.suspend = true
        let manager = TranscriptionEngineManager(settings: isolatedSettings(), engines: [.whisper: engine])
        let task = Task { try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused")) }
        while engine.continuation == nil { await Task.yield() }
        task.cancel()
        engine.continuation?.resume()
        do { _ = try await task.value; XCTFail("A cancelled result escaped") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(ModelWorkGate.shared.isBusy)
    }

    @MainActor func testCancelledQueuedWorkDoesNotRun() async throws {
        let engine = FakeSpeechEngine()
        let manager = TranscriptionEngineManager(settings: isolatedSettings(), engines: [.whisper: engine])
        await ModelWorkGate.shared.acquire()
        let task = Task { try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused")) }
        await Task.yield()
        task.cancel()
        ModelWorkGate.shared.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.calls, 0)
        XCTAssertFalse(ModelWorkGate.shared.isBusy)
    }

    @MainActor func testVocabularyRunsBeforeSingleReplacementPass() async throws {
        let settings = isolatedSettings()
        settings.customVocabulary = "Sotto"
        settings.replacements = [TextReplacement(spoken: "Sotto", written: "Ready"), TextReplacement(spoken: "Ready", written: "Twice")]
        let engine = FakeSpeechEngine()
        engine.output = "soto is ready"
        let manager = TranscriptionEngineManager(settings: settings, engines: [.whisper: engine])
        let text = try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(text, "Ready is Twice")
    }

    @MainActor func testWhisperDoesNotInventSpeechOnDigitalSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(samples: [Float](repeating: 0, count: 32_000), to: url)
        let hasSignal = try await SpeechAudio.hasSignal(url)
        XCTAssertFalse(hasSignal)
        let text = try await WhisperTranscriptionEngine().transcribe(audioURL: url, translate: false)
        XCTAssertEqual(text, "")
    }

    func testAudioReaderAccumulatesPacketAlignedReadsWithoutTinyTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(samples: [Float](repeating: 0.1, count: 60 * 16_000), to: url)
        let reader = try AudioSampleReader(url: url)
        XCTAssertEqual(try reader.read(seconds: 30)?.count, 480_000)
        XCTAssertEqual(try reader.read(seconds: 30)?.count, 480_000)
        XCTAssertNil(try reader.read(seconds: 30))
    }

    @MainActor func testClipboardOutputRestoresFixtureAfterCheck() {
        let pasteboard = NSPasteboard.general
        let snapshot = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
        }
        OutputService().copyToClipboard("Sotto local engine verification")
        XCTAssertEqual(pasteboard.string(forType: .string), "Sotto local engine verification")
        XCTAssertTrue(OutputService.isOwnWrite(changeCount: pasteboard.changeCount))
    }

    private static func write(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

final class FakeSpeechEngine: TranscriptionEngine {
    let id: SpeechEngineID = .whisper
    var phase: SpeechEnginePhase = .idle
    let progress: Double = 0
    let verified = true
    let capabilities = SpeechEngineCapabilities.whisper
    var isReady: Bool { phase == .ready }
    var loadError: String? { nil }
    var statusMessage: String { "Test" }
    var lastLanguage: String? { "en" }
    var calls = 0
    var suspend = false
    var output = "recognized text"
    var continuation: CheckedContinuation<Void, Never>?
    @MainActor func prepare() async throws { phase = .ready }
    @MainActor func transcribe(audioURL: URL, translate: Bool) async throws -> String {
        calls += 1
        if suspend { await withCheckedContinuation { continuation = $0 } }
        return output
    }
    @MainActor func previewTranscribe(_ samples: [Float]) async -> String? { nil }
    @MainActor func unload() async { phase = .idle }
}
