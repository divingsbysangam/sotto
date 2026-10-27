import CoreML
import FluidAudio
import Foundation

/// Actor owns all CoreML/ANE state. loadLocal and VadManager(vadModel:) cannot download.
actor ParakeetTranscriptionService: SpeechRuntime {
    private var manager: AsrManager?
    private var vad: VadManager?

    func load(from directory: URL) async throws {
        guard manager == nil else { return }
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        let models = try AsrModels.loadLocal(from: directory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let config = MLModelConfiguration()
        // Keep the small Silero network on CPU. Parakeet's encoder still uses the ANE.
        config.computeUnits = .cpuOnly
        let vadModel = try MLModel(contentsOf: directory.appendingPathComponent("VAD/silero-vad-unified-256ms-v6.2.1.mlmodelc"), configuration: config)
        self.vad = VadManager(config: VadConfig(computeUnits: .cpuOnly), vadModel: vadModel)
        self.manager = manager
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let manager, let vad else { throw SpeechModelStore.StoreError.notInstalled }
        let reader = try AudioSampleReader(url: url)
        var pieces: [String] = []
        // Bound memory and cancellation latency. Fresh decoder state per independent chunk.
        while let samples = try reader.read(seconds: 30) {
            try Task.checkCancellation()
            let activity = try await vad.process(samples)
            guard activity.contains(where: { $0.isVoiceActive }) else { continue }
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            let input = samples.count < minimum
                ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(input, decoderState: &state)
            try Task.checkCancellation()
            pieces.append(result.text)
        }
        return pieces.joined(separator: " ")
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        vad = nil
    }
}
