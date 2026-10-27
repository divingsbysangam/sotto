import Foundation

// This verification-only target builds the production store/reader/runtime sources without
// the app, its settings, TCC flows, or updater. It is never bundled in the installed app.
enum SpeechEngineID: String { case whisper, parakeet, cohere }

@main struct SpeechProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let id = SpeechEngineID(rawValue: CommandLine.arguments[1]), id != .whisper else {
            throw ProbeError.usage
        }
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let manifest = try JSONDecoder().decode(SpeechModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        guard let assets = manifest.engines[id.rawValue] else { throw ProbeError.usage }
        let directory = SpeechModelStore.directory(for: id)
        try await SpeechModelStore.ensure(assets: assets, root: directory, allowDownload: false,
                                         transport: { _ in throw URLError(.notConnectedToInternet) }) { _ in }
        let runtime: any SpeechRuntime = id == .parakeet ? ParakeetTranscriptionService() : CohereTranscriptionService()
        try await runtime.load(from: directory)
        let transcript = try await runtime.transcribe(audio)
        await runtime.unload()
        guard !transcript.isEmpty else { throw ProbeError.emptyTranscript }
        let result: [String: String] = ["engine": id.rawValue, "transcript": transcript, "preparation": "cache-only"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    enum ProbeError: Error { case usage, emptyTranscript }
}
