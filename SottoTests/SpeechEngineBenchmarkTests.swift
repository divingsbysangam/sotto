import AVFoundation
import XCTest
@testable import Sotto

/// Opt-in real-model acceptance test. Normal test runs never download multi-GB models.
final class SpeechEngineBenchmarkTests: XCTestCase {
    struct Clip: Codable { let id: String; let file: String; let text: String; let sha256: String }
    struct Measurement: Codable {
        let id: String
        let reference: String
        let transcript: String
        let warmSeconds: [Double]
        let errors: Int
        let referenceWords: Int
    }
    struct EngineReport: Codable {
        let engine: String
        let loadSeconds: Double
        let baselineMemoryMB: Double
        let peakMemoryMB: Double
        let measurements: [Measurement]
        let silencePassed: Bool
        let shortText: String
        let multiChunkText: String
    }

    @MainActor func testRealEngineBenchmark() async throws {
        let path = ProcessInfo.processInfo.environment["SOTTO_ASR_BENCHMARK_DIR"] ?? ""
        guard path.hasPrefix("/") else { throw XCTSkip("Set SOTTO_ASR_BENCHMARK_DIR to opt into model downloads and benchmarking") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: root.appendingPathComponent("corpus.json")))
        XCTAssertEqual(clips.count, 20)
        for clip in clips {
            XCTAssertEqual(try SpeechModelStore.sha256(root.appendingPathComponent(clip.file)), clip.sha256)
        }
        let suite = "com.sotto.benchmark.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.languageMode = .english
        let manager = TranscriptionEngineManager(settings: settings)
        let firstSamples = try XCTUnwrap(AudioSampleReader(url: root.appendingPathComponent(clips[0].file)).read(seconds: 30))
        let silence = root.appendingPathComponent("silence.caf")
        try Self.write(samples: [Float](repeating: 0, count: 32_000), to: silence)
        let short = root.appendingPathComponent("short.caf")
        try Self.write(samples: Array(firstSamples.prefix(16_000)), to: short)
        let long = root.appendingPathComponent("multi-chunk.caf")
        let repeated = Array(repeating: firstSamples, count: 1 + 65 * 16_000 / max(1, firstSamples.count)).flatMap { $0 }
        try Self.write(samples: repeated, to: long)

        for id in SpeechEngineID.allCases {
            // Use the production downloader once; all inference preparation is local-only.
            if id != .whisper {
                try await SpeechModelStore.ensure(assets: SpeechModelStore.assets(for: id), root: SpeechModelStore.directory(for: id), allowDownload: true) { _ in }
            }
            manager.select(id)
            let operation = manager.beginOperation()
            let engine = manager.engine(for: id)
            let baseline = LocalLLMService.footprintMB()
            let memory = Task.detached {
                var peak = LocalLLMService.footprintMB()
                while !Task.isCancelled {
                    peak = max(peak, LocalLLMService.footprintMB())
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return peak
            }
            let start = Date()
            await manager.prepare()
            let loadSeconds = Date().timeIntervalSince(start)
            XCTAssertTrue(engine.isReady, engine.loadError ?? "Engine did not load")
            guard engine.isReady else {
                memory.cancel()
                _ = await memory.value
                manager.endOperation(operation)
                throw SpeechModelStore.StoreError.notInstalled
            }
            var measurements: [Measurement] = []
            for clip in clips {
                var times: [Double] = []
                var transcript = ""
                for _ in 0..<3 {
                    let start = Date()
                    transcript = try await manager.transcribe(audioURL: root.appendingPathComponent(clip.file), engineID: operation.engineID, applyRules: false)
                    times.append(Date().timeIntervalSince(start))
                }
                let reference = Self.words(clip.text)
                measurements.append(Measurement(id: clip.id, reference: clip.text, transcript: transcript, warmSeconds: times,
                                                errors: Self.distance(reference, Self.words(transcript)), referenceWords: reference.count))
            }
            let silentText = try await manager.transcribe(audioURL: silence, engineID: operation.engineID, applyRules: false)
            XCTAssertTrue(silentText.isEmpty, "Silence hallucination: \(id.rawValue): \(silentText)")
            let shortText = try await manager.transcribe(audioURL: short, engineID: operation.engineID, applyRules: false)
            let imported = try await FileTranscriber.transcribe(long, progress: { _ in }, transcribeChunk: { url in
                try await manager.transcribe(audioURL: url, engineID: operation.engineID, applyRules: false)
            })
            XCTAssertFalse(imported.text.isEmpty)
            memory.cancel()
            let peak = await memory.value
            let report = EngineReport(engine: id.rawValue, loadSeconds: loadSeconds, baselineMemoryMB: baseline,
                                      peakMemoryMB: peak, measurements: measurements, silencePassed: silentText.isEmpty,
                                      shortText: shortText, multiChunkText: imported.text)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: root.appendingPathComponent("\(id.rawValue)-results.json"))
            await ModelWorkGate.shared.acquire()
            await engine.unload()
            ModelWorkGate.shared.release()
            manager.endOperation(operation)
        }
        // Switching back must preserve the existing Whisper-only features.
        manager.select(.whisper)
        let operation = manager.beginOperation()
        defer { manager.endOperation(operation) }
        let switchedText = try await manager.transcribe(
            audioURL: root.appendingPathComponent(clips[0].file), engineID: operation.engineID, applyRules: false
        )
        XCTAssertFalse(switchedText.isEmpty)
        // Preview intentionally skips rather than queues behind deferred maintenance.
        while ModelWorkGate.shared.isBusy { await Task.yield() }
        let preview = await manager.previewTranscribe(firstSamples, engineID: .whisper)
        XCTAssertNotNil(preview)
        XCTAssertFalse(preview?.isEmpty ?? true)
        try JSONSerialization.data(withJSONObject: ["previewPassed": !(preview?.isEmpty ?? true)], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("whisper-feature-checks.json"))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func distance(_ reference: [String], _ hypothesis: [String]) -> Int {
        var row = Array(0...hypothesis.count)
        for (i, word) in reference.enumerated() {
            var next = [i + 1] + [Int](repeating: 0, count: hypothesis.count)
            for (j, other) in hypothesis.enumerated() {
                next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (word == other ? 0 : 1))
            }
            row = next
        }
        return row.last!
    }

    static func write(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
