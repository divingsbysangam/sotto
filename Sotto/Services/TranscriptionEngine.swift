import Foundation

enum SpeechEngineID: String, Codable, CaseIterable, Identifiable {
    case whisper, parakeet, cohere
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .whisper: return "Whisper Turbo (Default)"
        case .parakeet: return "Parakeet TDT v3 (Fast)"
        case .cohere: return "Cohere Transcribe (Max accuracy)"
        }
    }

    static func effective(selected: Self, languageMode: DictationLanguageMode, translate: Bool = false) -> Self {
        translate || languageMode != .english ? .whisper : selected
    }
}

enum SpeechEnginePhase: Equatable {
    case notInstalled, idle, downloading, verifying, loading, ready
    case failed(String)
}

struct SpeechEngineCapabilities {
    let livePreview: Bool
    let translation: Bool
    static let whisper = Self(livePreview: true, translation: true)
    static let english = Self(livePreview: false, translation: false)
}

protocol TranscriptionEngine: AnyObject {
    var id: SpeechEngineID { get }
    var phase: SpeechEnginePhase { get }
    var progress: Double { get }
    var verified: Bool { get }
    var capabilities: SpeechEngineCapabilities { get }
    var isReady: Bool { get }
    var loadError: String? { get }
    var statusMessage: String { get }
    var lastLanguage: String? { get }
    @MainActor func prepare() async throws
    @MainActor func transcribe(audioURL: URL, translate: Bool) async throws -> String
    @MainActor func previewTranscribe(_ samples: [Float]) async -> String?
    @MainActor func unload() async
}

/// Shared by speech inference and MLX cleanup. Holding this gate includes model loading and
/// unloading: neither GPU cache clearing nor a model switch can race an in-flight decode.
@MainActor
final class ModelWorkGate {
    static let shared = ModelWorkGate()
    private(set) var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy { isBusy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { isBusy = false }
        else { waiters.removeFirst().resume() }
    }
}

final class WhisperTranscriptionEngine: TranscriptionEngine {
    let id: SpeechEngineID = .whisper
    let capabilities = SpeechEngineCapabilities.whisper
    private let service = LocalTranscriptionService.shared
    var phase: SpeechEnginePhase {
        switch service.phase {
        case .idle: return .idle
        case .ready: return .ready
        case .downloading: return .downloading
        case .loading: return service.verification == .checking ? .verifying : .loading
        case .failed(let message): return .failed(message)
        }
    }
    var progress: Double { service.downloadProgress }
    var verified: Bool { service.verification == .verified }
    var isReady: Bool { service.isReady }
    var loadError: String? { service.loadError }
    var statusMessage: String { service.statusMessage }
    var lastLanguage: String? { service.lastLanguage }
    @MainActor func prepare() async throws {
        guard service.canRetry else {
            throw LocalTranscriptionError.modelUnavailable("A previous load timed out. Quit and reopen Sotto to try again.")
        }
        if let error = service.loadError { throw LocalTranscriptionError.modelUnavailable(error) }
        _ = try await service.ensureModelLoaded()
    }
    @MainActor func transcribe(audioURL: URL, translate: Bool) async throws -> String {
        guard try await SpeechAudio.hasSignal(audioURL) else { return "" }
        return try await service.transcribe(audioURL: audioURL, translate: translate)
    }
    @MainActor func previewTranscribe(_ samples: [Float]) async -> String? {
        await service.previewTranscribe(samples)
    }
    @MainActor func unload() async { service.unload() }
}

enum SpeechAudio {
    /// Run decoding off the main actor. Digital silence can make autoregressive ASR invent
    /// phrases even when its no-speech threshold is enabled; never send it to Whisper.
    static func hasSignal(_ url: URL) async throws -> Bool {
        let reader = try AudioSampleReader(url: url)
        while let samples = try reader.read(seconds: 1) {
            try Task.checkCancellation()
            if samples.contains(where: { abs($0) > 0.0001 }) { return true }
        }
        return false
    }
}
