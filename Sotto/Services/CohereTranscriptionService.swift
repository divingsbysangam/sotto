import Foundation
import MLX
import MLXAudioSTT

/// In-process q4 inference. The caller holds ModelWorkGate, shared with local MLX cleanup.
actor CohereTranscriptionService: SpeechRuntime {
    private var model: CohereTranscribeModel?

    func load(from directory: URL) async throws {
        guard model == nil else { return }
        model = try CohereTranscribeModel.fromDirectory(directory)
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let model else { throw SpeechModelStore.StoreError.notInstalled }
        let reader = try AudioSampleReader(url: url)
        var pieces: [String] = []
        while let samples = try reader.read(seconds: 30) {
            try Task.checkCancellation()
            // Digital silence is not speech; do not ask an autoregressive model to invent text.
            guard samples.contains(where: { abs($0) > 0.0001 }) else { continue }
            let output = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(
                maxTokens: 512, temperature: 0, language: "en"
            ))
            try Task.checkCancellation()
            pieces.append(output.text)
        }
        return pieces.joined(separator: " ")
    }

    func unload() async {
        model = nil
        MLX.Memory.clearCache()
    }
}
