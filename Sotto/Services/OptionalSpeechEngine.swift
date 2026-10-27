import Foundation
import Observation

@Observable
final class OptionalSpeechEngine: TranscriptionEngine {
    let id: SpeechEngineID
    let capabilities = SpeechEngineCapabilities.english
    private(set) var phase: SpeechEnginePhase
    private(set) var progress: Double = 0
    private(set) var verified = false
    var isReady: Bool { phase == .ready }
    var lastLanguage: String? { "en" }
    var loadError: String? { if case .failed(let reason) = phase { return reason }; return nil }
    var statusMessage: String {
        switch phase {
        case .notInstalled: return "Download the selected engine in Settings → Transcription"
        case .idle: return "Model on disk"
        case .downloading: return "Downloading model… \(Int(progress * 100))%"
        case .verifying: return "Verifying model…"
        case .loading: return "Preparing model…"
        case .ready: return "Transcribing…"
        case .failed(let reason): return reason
        }
    }
    @ObservationIgnored private let runtime: any SpeechRuntime
    private let directory: URL
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(id: SpeechEngineID, runtime: any SpeechRuntime, directory: URL? = nil) {
        self.id = id
        self.runtime = runtime
        self.directory = directory ?? SpeechModelStore.directory(for: id)
        phase = SpeechModelStore.isInstalled(id, at: self.directory) ? .idle : .notInstalled
    }

    /// Download is explicit; selecting an uninstalled engine never starts network traffic.
    @MainActor func download() {
        guard downloadTask == nil, phase != .loading, phase != .verifying, !isReady else { return }
        let token = UUID()
        generation = token
        phase = .downloading
        progress = 0
        verified = false
        downloadTask = Task { [self] in
            do {
                let assets = try SpeechModelStore.assets(for: id)
                try await SpeechModelStore.ensure(assets: assets, root: directory, allowDownload: true) { [weak self] value in
                    Task { @MainActor in
                        guard self?.generation == token else { return }
                        self?.progress = value
                    }
                }
                try Task.checkCancellation()
                verified = true
                phase = .idle
            } catch where Task.isCancelled || error is CancellationError {
                phase = SpeechModelStore.isInstalled(id, at: directory) ? .idle : .notInstalled
            } catch {
                phase = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    @MainActor func cancelDownload() { downloadTask?.cancel() }

    @MainActor func prepare() async throws {
        guard !isReady else { return }
        guard downloadTask == nil, SpeechModelStore.isInstalled(id, at: directory) else { throw SpeechModelStore.StoreError.notInstalled }
        do {
            phase = .verifying
            verified = false
            try await SpeechModelStore.ensure(assets: SpeechModelStore.assets(for: id), root: directory, allowDownload: false) { _ in }
            verified = true
            try Task.checkCancellation()
            phase = .loading
            try await runtime.load(from: directory)
            try Task.checkCancellation()
            phase = .ready
        } catch {
            await runtime.unload()
            phase = .failed(error.localizedDescription)
            throw error
        }
    }

    @MainActor func transcribe(audioURL: URL, translate: Bool = false) async throws -> String {
        try await prepare()
        try Task.checkCancellation()
        let text = try await runtime.transcribe(audioURL)
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor func previewTranscribe(_ samples: [Float]) async -> String? { nil }

    @MainActor func unload() async {
        await runtime.unload()
        if phase == .ready { phase = .idle }
    }

    /// The manager calls this only after reservations and inference have finished.
    @MainActor func remove() async throws {
        // Await cancellation so a late download cannot recreate a removed directory.
        downloadTask?.cancel()
        await downloadTask?.value
        await unload()
        let root = directory
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        generation = UUID()
        verified = false
        progress = 0
        phase = .notInstalled
    }
}
