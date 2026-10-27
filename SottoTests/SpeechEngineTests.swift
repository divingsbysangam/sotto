import CryptoKit
import AppKit
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

    func testSettingsDefaultAndLegacyMigration() {
        let name = "com.divingsbysangam.sotto.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old-cloud-engine", forKey: "localEngine")
        defaults.set("unknown", forKey: "speechEngine")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.speechEngine, .whisper)
        XCTAssertNil(defaults.object(forKey: "localEngine"))
        settings.speechEngine = .cohere
        XCTAssertEqual(AppSettings(defaults: defaults).speechEngine, .cohere)
    }

    func testLanguageAndTranslationRouting() {
        for id in SpeechEngineID.allCases {
            XCTAssertEqual(SpeechEngineID.effective(selected: id, languageMode: .english), id)
            XCTAssertEqual(SpeechEngineID.effective(selected: id, languageMode: .auto), .whisper)
            XCTAssertEqual(SpeechEngineID.effective(selected: id, languageMode: .chosen), .whisper)
            XCTAssertEqual(SpeechEngineID.effective(selected: id, languageMode: .english, translate: true), .whisper)
        }
    }

    @MainActor func testSnapshotAndUnloadBeforeSwitch() async throws {
        let settings = isolatedSettings()
        settings.speechEngine = .parakeet
        let whisper = FakeSpeechEngine(.whisper), parakeet = FakeSpeechEngine(.parakeet), cohere = FakeSpeechEngine(.cohere)
        let manager = TranscriptionEngineManager(settings: settings, engines: [.whisper: whisper, .parakeet: parakeet, .cohere: cohere])
        let operation = manager.beginOperation()
        manager.select(.cohere)
        XCTAssertEqual(manager.operationCount, 1)
        XCTAssertEqual(operation.engineID, .parakeet)
        _ = try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused"), engineID: operation.engineID)
        XCTAssertEqual(parakeet.calls, 1)
        XCTAssertEqual(cohere.calls, 0)
        manager.endOperation(operation)
        _ = try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(cohere.calls, 1)
        XCTAssertGreaterThanOrEqual(parakeet.unloads, 1)
    }

    @MainActor func testCancellationDiscardsLateResultAndReleasesGate() async throws {
        let settings = isolatedSettings()
        let engine = FakeSpeechEngine(.whisper)
        engine.suspend = true
        let manager = TranscriptionEngineManager(settings: settings, engines: [.whisper: engine])
        let task = Task { try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused")) }
        while engine.continuation == nil { await Task.yield() }
        task.cancel()
        engine.continuation?.resume()
        do { _ = try await task.value; XCTFail("A cancelled result escaped") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(ModelWorkGate.shared.isBusy)
    }

    @MainActor func testCancelledQueuedWorkDoesNotRun() async throws {
        let engine = FakeSpeechEngine(.whisper)
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
        let engine = FakeSpeechEngine(.whisper)
        engine.output = "soto is ready"
        let manager = TranscriptionEngineManager(settings: settings, engines: [.whisper: engine])
        let text = try await manager.transcribe(audioURL: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(text, "Ready is Twice")
        XCTAssertEqual(engine.calls, 1)
    }

    @MainActor func testRemovalWaitsForReservedOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker")
        try Data([1]).write(to: marker)
        let settings = isolatedSettings()
        settings.speechEngine = .parakeet
        let optional = OptionalSpeechEngine(id: .parakeet, runtime: FakeSpeechRuntime(), directory: root)
        let manager = TranscriptionEngineManager(settings: settings, engines: [.parakeet: optional])
        let operation = manager.beginOperation()
        manager.requestRemoval(.parakeet)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        manager.endOperation(operation)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testManifestRequiresEveryAssetAndRejectsSameSizeCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("valid".utf8)
        let file = root.appendingPathComponent("weights")
        try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = SpeechModelManifest.Asset(repository: "unused/model", revision: String(repeating: "a", count: 40), remotePath: "weights", path: "weights", size: 5, sha256: hash)
        try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: false) { _ in }
        try Data("bad!!".utf8).write(to: file)
        do {
            try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: false) { _ in }
            XCTFail("Same-size corruption accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verification failed")) }
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try SpeechModelStore.validate(asset, at: root))
    }

    func testBundledManifestPinsRevisionsAndPaths() throws {
        for id: SpeechEngineID in [.parakeet, .cohere] {
            let assets = try SpeechModelStore.assets(for: id)
            XCTAssertFalse(assets.isEmpty)
            XCTAssertEqual(Set(assets.map(\.path)).count, assets.count)
            XCTAssertTrue(assets.allSatisfy { $0.revision.count == 40 && $0.sha256.count == 64 && $0.size > 0 })
        }
    }

    @MainActor func testWhisperDoesNotInventSpeechOnDigitalSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try SpeechEngineBenchmarkTests.write(samples: [Float](repeating: 0, count: 32_000), to: url)
        let hasSignal = try await SpeechAudio.hasSignal(url)
        XCTAssertFalse(hasSignal)
        let text = try await WhisperTranscriptionEngine().transcribe(audioURL: url, translate: false)
        XCTAssertEqual(text, "")
    }

    func testAudioReaderAccumulatesPacketAlignedReadsWithoutTinyTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SpeechEngineBenchmarkTests.write(samples: [Float](repeating: 0.1, count: 60 * 16_000), to: url)
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

    func testDownloadHTTPFailureChecksumFailureAndRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = SHA256.hash(data: Data("valid".utf8)).map { String(format: "%02x", $0) }.joined()
        let asset = SpeechModelManifest.Asset(repository: "unused/model", revision: String(repeating: "a", count: 40), remotePath: "weights", path: "weights", size: 5, sha256: hash)
        for (status, contents) in [(503, "valid"), (200, "bad!!")] {
            do {
                try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: true, transport: { url in
                    let temporary = root.appendingPathComponent(UUID().uuidString)
                    try Data(contents.utf8).write(to: temporary)
                    return (temporary, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }) { _ in }
                XCTFail("Bad download accepted")
            } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("weights").path)) }
        }
        try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: true, transport: { url in
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try Data("valid".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) { _ in }
        try SpeechModelStore.validate(asset, at: root)
        // Already verified files must never invoke the network transport, even online.
        try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: true, transport: { _ in
            XCTFail("Verified asset downloaded again")
            throw URLError(.notConnectedToInternet)
        }) { _ in }
    }

    func testCancelledDownloadDoesNotPublishFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = SpeechModelManifest.Asset(repository: "unused/model", revision: String(repeating: "a", count: 40), remotePath: "weights", path: "weights", size: 5, sha256: String(repeating: "a", count: 64))
        let task = Task {
            try await SpeechModelStore.ensure(assets: [asset], root: root, allowDownload: true, transport: { _ in
                throw CancellationError()
            }) { _ in }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("weights").path))
    }
}

actor FakeSpeechRuntime: SpeechRuntime {
    func load(from directory: URL) async throws {}
    func transcribe(_ url: URL) async throws -> String { "test" }
    func unload() async {}
}

final class FakeSpeechEngine: TranscriptionEngine {
    let id: SpeechEngineID
    var phase: SpeechEnginePhase = .idle
    let progress: Double = 0
    let verified = true
    var capabilities: SpeechEngineCapabilities { id == .whisper ? .whisper : .english }
    var isReady: Bool { phase == .ready }
    var loadError: String? { nil }
    var statusMessage: String { "Test" }
    var lastLanguage: String? { "en" }
    var calls = 0, unloads = 0
    var suspend = false
    var output = "recognized text"
    var continuation: CheckedContinuation<Void, Never>?
    init(_ id: SpeechEngineID) { self.id = id }
    @MainActor func prepare() async throws { phase = .ready }
    @MainActor func transcribe(audioURL: URL, translate: Bool) async throws -> String {
        calls += 1
        if suspend { await withCheckedContinuation { continuation = $0 } }
        return output
    }
    @MainActor func previewTranscribe(_ samples: [Float]) async -> String? { nil }
    @MainActor func unload() async { unloads += 1; phase = .idle }
}
