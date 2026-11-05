import Foundation
import Observation

/// Routes local Whisper recognition. Operations retain a stable engine for imported files.
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

    struct Operation {
        let token: UUID
        let engineID: SpeechEngineID
    }

    var effectiveID: SpeechEngineID {
        SpeechEngineID.effective(selected: selectedID, languageMode: settings.languageMode)
    }
    var engine: any TranscriptionEngine { engines[activeID ?? effectiveID]! }
    var selectedEngine: any TranscriptionEngine { engines[selectedID]! }
    var fallbackNotice: String? { nil }
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
        selectedID = .whisper
        settings.speechEngine = .whisper
        self.engines = engines ?? [.whisper: WhisperTranscriptionEngine()]
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
    }

    @MainActor func select(_ id: SpeechEngineID) {
        selectedID = id
        settings.speechEngine = id
    }

    @MainActor private func activate(_ id: SpeechEngineID) async throws -> any TranscriptionEngine {
        let next = engines[id]!
        activeID = id
        try await next.prepare()
        try Task.checkCancellation()
        return next
    }

    @MainActor
    func prepare(retry: Bool = false) async {
        let id = effectiveID
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
