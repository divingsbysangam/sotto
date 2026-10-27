import Foundation
import Observation

/// Routes local recognition and owns model lifetime. Operations reserve an engine at their
/// start; switching Settings cannot change engines halfway through an imported file.
@Observable
final class TranscriptionEngineManager {
    static let shared = TranscriptionEngineManager()

    private let settings: AppSettings
    private let engines: [SpeechEngineID: any TranscriptionEngine]
    private(set) var selectedID: SpeechEngineID
    private(set) var activeID: SpeechEngineID?
    private(set) var operationCount = 0
    private(set) var maintenanceError: String?
    @ObservationIgnored private var reservations: [UUID: SpeechEngineID] = [:]
    @ObservationIgnored private var removals: Set<SpeechEngineID> = []

    struct Operation {
        let token: UUID
        let engineID: SpeechEngineID
    }

    var effectiveID: SpeechEngineID {
        SpeechEngineID.effective(selected: selectedID, languageMode: settings.languageMode)
    }
    var engine: any TranscriptionEngine { engines[activeID ?? effectiveID]! }
    var selectedEngine: any TranscriptionEngine { engines[selectedID]! }
    var fallbackNotice: String? {
        effectiveID != selectedID ? "Using Whisper Turbo for automatic language detection and non-English dictation." : nil
    }
    var livePreviewAvailable: Bool { engines[effectiveID]!.capabilities.livePreview }

    func engine(for id: SpeechEngineID) -> any TranscriptionEngine { engines[id]! }

    /// Best-effort user-facing phase while processing a dictation.
    var statusMessage: String {
        let message = engine.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Transcribing…" : message
    }

    /// N10: language code of the last transcription ("en", "es", …).
    private(set) var lastLanguage: String?

    init(settings: AppSettings = .shared, engines: [SpeechEngineID: any TranscriptionEngine]? = nil) {
        self.settings = settings
        selectedID = settings.speechEngine
        self.engines = engines ?? [
            .whisper: WhisperTranscriptionEngine(),
            .parakeet: OptionalSpeechEngine(id: .parakeet, runtime: ParakeetTranscriptionService()),
            .cohere: OptionalSpeechEngine(id: .cohere, runtime: CohereTranscriptionService()),
        ]
    }

    @MainActor func beginOperation() -> Operation {
        let operation = Operation(token: UUID(), engineID: effectiveID)
        reservations[operation.token] = operation.engineID
        operationCount = reservations.count
        return operation
    }

    @MainActor func endOperation(_ operation: Operation) {
        reservations.removeValue(forKey: operation.token)
        operationCount = reservations.count
        if operationCount == 0 { scheduleMaintenance() }
    }

    @MainActor func select(_ id: SpeechEngineID) {
        selectedID = id
        settings.speechEngine = id
        if operationCount == 0 { scheduleMaintenance() }
    }

    @MainActor func requestRemoval(_ id: SpeechEngineID) {
        guard id != .whisper else { return }
        removals.insert(id)
        scheduleMaintenance()
    }

    @MainActor func removalPending(_ id: SpeechEngineID) -> Bool { removals.contains(id) }

    @MainActor private func scheduleMaintenance() {
        Task {
            await ModelWorkGate.shared.acquire()
            defer { ModelWorkGate.shared.release() }
            guard reservations.isEmpty else { return }
            maintenanceError = nil
            for id in removals {
                do {
                    try await (engines[id] as? OptionalSpeechEngine)?.remove()
                    if activeID == id { activeID = nil }
                    removals.remove(id)
                } catch { maintenanceError = error.localizedDescription }
            }
            if let activeID, activeID != effectiveID {
                guard activeID != .whisper || LocalTranscriptionService.shared.canRetry else {
                    maintenanceError = "A previous model load timed out. Quit and reopen Sotto before switching engines."
                    return
                }
                await engines[activeID]!.unload()
                self.activeID = nil
            }
        }
    }

    @MainActor private func activate(_ id: SpeechEngineID) async throws -> any TranscriptionEngine {
        let next = engines[id]!
        if let activeID, activeID != id {
            guard activeID != .whisper || LocalTranscriptionService.shared.canRetry else {
                throw LocalTranscriptionError.modelUnavailable("A previous model load timed out. Quit and reopen Sotto before switching engines.")
            }
            await engines[activeID]!.unload()
        }
        activeID = id
        // Don't retain the optional cleanup LLM while loading the larger speech model.
        if id == .cohere { LocalLLMService.shared.unloadWhileLocked() }
        try await next.prepare()
        try Task.checkCancellation()
        return next
    }

    @MainActor
    func prepare(retry: Bool = false) async {
        let id = effectiveID
        // Optional models are downloaded only by their explicit Settings button.
        guard id == .whisper || SpeechModelStore.isInstalled(id) else { return }
        await ModelWorkGate.shared.acquire()
        defer { ModelWorkGate.shared.release() }
        if retry && id == .whisper { await LocalTranscriptionService.shared.retryLoad() }
        do { _ = try await activate(id) }
        catch { maintenanceError = error.localizedDescription }
    }

    @MainActor
    /// `translate`: L10, Whisper's X→English task instead of transcription.
    func transcribe(audioURL: URL, translate: Bool = false, engineID: SpeechEngineID? = nil, applyRules: Bool = true) async throws -> String {
        let id = translate ? .whisper : (engineID ?? effectiveID)
        await ModelWorkGate.shared.acquire()
        defer { ModelWorkGate.shared.release() }
        try Task.checkCancellation()
        let engine = try await activate(id)
        let text = try await engine.transcribe(audioURL: audioURL, translate: translate)
        try Task.checkCancellation()
        lastLanguage = engine.lastLanguage
        return applyRules ? corrected(text) : text
    }

    @MainActor func previewTranscribe(_ samples: [Float], engineID: SpeechEngineID) async -> String? {
        guard engineID == .whisper, activeID == .whisper, !ModelWorkGate.shared.isBusy else { return nil }
        await ModelWorkGate.shared.acquire()
        defer { ModelWorkGate.shared.release() }
        guard !Task.isCancelled else { return nil }
        return await engines[.whisper]!.previewTranscribe(samples)
    }

    func corrected(_ input: String) -> String {
        var text = input

        let vocabulary = settings.vocabularyList
        if !vocabulary.isEmpty {
            text = applyVocabularyCorrections(text, vocabulary: vocabulary)
        }

        return DictationTextRules.applyReplacements(text, settings.replacements)
    }

    // MARK: - Vocabulary Corrections (shared)

    private func applyVocabularyCorrections(_ text: String, vocabulary: [String]) -> String {
        var correctedText = text

        for word in vocabulary {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(correctedText.startIndex..., in: correctedText)
                correctedText = regex.stringByReplacingMatches(
                    in: correctedText,
                    options: [],
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: word)
                )
            }

            let variations = generatePhoneticVariations(for: word)
            for variation in variations {
                let varPattern = "\\b\(NSRegularExpression.escapedPattern(for: variation))\\b"
                if let regex = try? NSRegularExpression(pattern: varPattern, options: .caseInsensitive) {
                    let range = NSRange(correctedText.startIndex..., in: correctedText)
                    correctedText = regex.stringByReplacingMatches(
                        in: correctedText,
                        options: [],
                        range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: word)
                    )
                }
            }
        }

        return correctedText
    }

    private func generatePhoneticVariations(for word: String) -> [String] {
        var variations: [String] = []
        let lowercased = word.lowercased()

        var i = lowercased.startIndex
        while i < lowercased.endIndex {
            let nextIndex = lowercased.index(after: i)
            if nextIndex < lowercased.endIndex && lowercased[i] == lowercased[nextIndex] {
                var variation = lowercased
                variation.remove(at: nextIndex)
                variations.append(variation)
            }
            i = nextIndex
        }

        return variations
    }
}
