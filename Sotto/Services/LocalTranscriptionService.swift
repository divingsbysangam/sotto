import CryptoKit
import Foundation
import os
@preconcurrency import WhisperKit

enum LocalTranscriptionError: LocalizedError {
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case downloadStalled(TimeInterval)
    case downloadIncomplete
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "Speech model isn’t loaded (\(reason)). Open Settings → Transcription and click Retry."
        case .modelLoadFailed(let message):
            return "Speech model failed to load: \(message)"
        case .downloadStalled(let seconds):
            return "Model download stalled (no progress for \(Int(seconds))s). Check your connection and click Retry — the download resumes where it stopped."
        case .downloadIncomplete:
            return "Model download finished but files are missing. Click Retry to resume the download."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }

    var isModelLoadFailure: Bool {
        switch self {
        case .modelUnavailable, .modelLoadFailed, .downloadStalled, .downloadIncomplete:
            return true
        case .transcriptionFailed:
            return false
        }
    }
}

/// WhisperKit engine for the single shipped model (`WhisperModel.largev3Turbo`).
///
/// The model is loaded once (at launch, or on Retry) and kept in memory. Dictation awaits the
/// in-flight load instead of starting another one, and fails fast with a clear error when the
/// last load failed. Load-state mutations happen on the main actor, so no locks are needed.
@Observable
final class LocalTranscriptionService {
    enum Phase: Equatable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    static let shared = LocalTranscriptionService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Transcription")

    static let model = WhisperModel.largev3Turbo
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    /// Exact total of the model folder on Hugging Face; only used for the progress bar.
    static let expectedModelBytes: Int64 = 1_638_464_446

    /// Abort a download only when no bytes have arrived for this long. The Hub downloader
    /// flushes to disk in 10MB chunks, so slow links legitimately go minutes between writes;
    /// dead connections already fail on their own via URLSession timeouts.
    static let downloadStallTimeoutSeconds: TimeInterval = 600
    /// Hard cap for CoreML load/ANE specialization. First run on a new macOS build can take
    /// several minutes; cached loads take seconds.
    static let modelLoadTimeoutSeconds: TimeInterval = 20 * 60
    static let transcriptionTimeoutSeconds: TimeInterval = 180

    private(set) var phase: Phase = .idle
    private(set) var downloadProgress: Double = 0
    private(set) var isTranscribing = false
    /// N10: language code of the last transcription ("en", "es", …).
    private(set) var lastLanguage: String?

    /// N14: result of checking the model files against the bundled manifest.
    enum Verification: Equatable {
        case notChecked
        case checking
        case verified
        /// Files are from a different model revision than the one pinned in this build.
        case unverified(String)
        case failed(String)
    }
    private(set) var verification: Verification = .notChecked

    /// One transcription at a time on the single model (dictation, retries, file imports).
    @ObservationIgnored private var transcriptionBusy = false
    @ObservationIgnored private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    private var whisperKit: WhisperKit?
    @ObservationIgnored private var loadTask: Task<WhisperKit, Error>?
    @ObservationIgnored private var lastDownloadActivity = Date()
    @ObservationIgnored private var downloadStalled = false
    /// Set when a load timed out: the abandoned WhisperKit init keeps running, so a second
    /// load would double memory. Only a relaunch clears it.
    @ObservationIgnored private var hasOrphanedLoad = false
    /// Set once the Vocabulary prompt empties a transcript that succeeds without it, so later
    /// dictations skip the doomed first pass. Relaunch re-enables it.
    @ObservationIgnored private var vocabularyPromptDisabled = false

    var isReady: Bool { whisperKit != nil }
    var isModelLoaded: Bool { whisperKit != nil }
    var isDownloading: Bool { phase == .downloading }
    var isLoading: Bool { phase == .downloading || phase == .loading }

    /// False after a timed-out load; the Settings Retry button is hidden then.
    var canRetry: Bool { !hasOrphanedLoad }

    var loadError: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// Human-readable phase for the processing UI; empty when idle and loaded.
    var statusMessage: String {
        switch phase {
        case .downloading:
            let percent = Int((downloadProgress * 100).rounded(.down))
            return percent > 0 ? "Downloading model… \(percent)%" : "Downloading model…"
        case .loading:
            return verification == .checking ? "Verifying model…" : "Loading model…"
        case .failed:
            return "Model failed to load"
        case .idle, .ready:
            return isTranscribing ? "Transcribing…" : ""
        }
    }

    private init() {}

    /// Called with ModelWorkGate held, after all speech/preview work has completed.
    @MainActor
    func unload() {
        guard loadTask == nil, !transcriptionBusy else { return }
        whisperKit = nil
        if !hasOrphanedLoad { phase = .idle }
    }

    // MARK: - Loading

    /// Starts (or joins) the one-time model load. Safe to call repeatedly.
    @MainActor
    func prepare() async {
        do {
            _ = try await ensureModelLoaded()
        } catch {
            Self.logger.error("model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears a failed state and loads again. No-op while a load is already running.
    @MainActor
    func retryLoad() async {
        guard loadTask == nil, whisperKit == nil, !hasOrphanedLoad else { return }
        phase = .idle
        await prepare()
    }

    @MainActor
    @discardableResult
    func ensureModelLoaded() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }

        let task: Task<WhisperKit, Error>
        if let loadTask {
            Self.logger.notice("joining in-flight model load")
            task = loadTask
        } else {
            task = Task { try await self.performLoad() }
            loadTask = task
        }

        do {
            return try await task.value
        } catch let error as LocalTranscriptionError {
            throw error
        } catch {
            throw LocalTranscriptionError.modelLoadFailed(Self.describe(error))
        }
    }

    @MainActor
    private func performLoad() async throws -> WhisperKit {
        let variant = Self.model.rawValue
        defer { loadTask = nil }

        do {
            phase = .loading
            downloadProgress = 0

            var folder = try await Self.validatedLocalModelFolder(variant: variant)
            if folder == nil {
                Self.logger.notice("\(variant, privacy: .public) not on disk (or incomplete); downloading")
                phase = .downloading
                try await downloadWithStallWatchdog(variant: variant)
                folder = try await Self.validatedLocalModelFolder(variant: variant)
            }
            guard var modelFolder = folder else {
                throw LocalTranscriptionError.downloadIncomplete
            }

            // N14: check the files against the pinned manifest. Corrupt files (same revision,
            // wrong checksum) are deleted and downloaded once more.
            if try await verifyModel(folder: modelFolder, variant: variant) == false {
                phase = .downloading
                try await downloadWithStallWatchdog(variant: variant)
                guard let redownloaded = try await Self.validatedLocalModelFolder(variant: variant),
                      try await verifyModel(folder: redownloaded, variant: variant) else {
                    throw LocalTranscriptionError.modelLoadFailed("The downloaded model files don't match their checksums. Check your connection and click Retry.")
                }
                modelFolder = redownloaded
            }

            phase = .loading
            Self.logger.notice("loading \(variant, privacy: .public) from \(modelFolder.path, privacy: .public)")
            let start = Date()
            let kit = try await withTimeout(
                seconds: Self.modelLoadTimeoutSeconds,
                operation: "WhisperKit model load"
            ) {
                try await Self.makeWhisperKit(modelFolder: modelFolder)
            }
            Self.logger.notice("model loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s")

            whisperKit = kit
            phase = .ready
            return kit
        } catch let error as AsyncTimeoutError {
            hasOrphanedLoad = true
            let message = "\(Self.describe(error)). Quit and reopen Sotto to try again."
            Self.logger.error("load failed: \(message, privacy: .public)")
            phase = .failed(message)
            throw LocalTranscriptionError.modelLoadFailed(message)
        } catch {
            let message = Self.describe(error)
            Self.logger.error("load failed: \(message, privacy: .public)")
            phase = .failed(message)
            throw error
        }
    }

    /// Downloads the model folder, aborting only when bytes stop arriving.
    @MainActor
    private func downloadWithStallWatchdog(variant: String) async throws {
        lastDownloadActivity = Date()
        downloadStalled = false

        let download = Task<URL, Error> {
            try await WhisperKit.download(variant: variant, from: Self.modelRepo) { _ in
                _ = Task { @MainActor in self.lastDownloadActivity = Date() }
            }
        }

        let watchdog = Task { @MainActor in
            var lastBytes: Int64 = -1
            while !Task.isCancelled {
                let bytes = await Self.downloadedBytes(variant: variant)
                if bytes > lastBytes {
                    lastBytes = bytes
                    self.lastDownloadActivity = Date()
                }
                self.downloadProgress = min(1, Double(bytes) / Double(Self.expectedModelBytes))

                if Date().timeIntervalSince(self.lastDownloadActivity) > Self.downloadStallTimeoutSeconds {
                    Self.logger.error("download stalled; cancelling")
                    self.downloadStalled = true
                    download.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        defer { watchdog.cancel() }
        do {
            _ = try await download.value
        } catch {
            if downloadStalled { throw LocalTranscriptionError.downloadStalled(Self.downloadStallTimeoutSeconds) }
            throw error
        }
        // A cancelled Hub snapshot returns normally instead of throwing.
        if downloadStalled { throw LocalTranscriptionError.downloadStalled(Self.downloadStallTimeoutSeconds) }
        downloadProgress = 1
    }

    private static func makeWhisperKit(modelFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: model.rawValue,
            modelRepo: modelRepo,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    // MARK: - On-disk model folder

    /// Same location WhisperKit/Hub use by default: `~/Documents/huggingface/models/<repo>`.
    private static var repoRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent(modelRepo)
    }

    /// Hub download metadata; a file whose `.metadata` matches the remote commit is treated
    /// as cached without a size check, so corrupt files must lose their metadata too.
    private static var metadataRoot: URL {
        repoRoot.appendingPathComponent(".cache/huggingface/download")
    }

    /// Minimum sizes for files every WhisperKit model folder needs. Files are only moved into
    /// place once fully downloaded, so anything smaller is corrupt or from an interrupted copy.
    private static let requiredFiles: [(path: String, minBytes: Int64)] = [
        ("config.json", 1),
        ("generation_config.json", 1),
        ("MelSpectrogram.mlmodelc/coremldata.bin", 1),
        ("MelSpectrogram.mlmodelc/model.mil", 1),
        ("MelSpectrogram.mlmodelc/weights/weight.bin", 100_000),
        ("AudioEncoder.mlmodelc/coremldata.bin", 1),
        ("AudioEncoder.mlmodelc/model.mil", 1),
        ("AudioEncoder.mlmodelc/weights/weight.bin", 1_000_000_000),
        ("TextDecoder.mlmodelc/coremldata.bin", 1),
        ("TextDecoder.mlmodelc/model.mil", 1),
        ("TextDecoder.mlmodelc/weights/weight.bin", 300_000_000),
        ("TextDecoderContextPrefill.mlmodelc/coremldata.bin", 1),
        ("TextDecoderContextPrefill.mlmodelc/weights/weight.bin", 1_000_000),
    ]

    /// Deletes corrupt/partial files (and their Hub metadata), then returns the model folder
    /// if it is complete, or nil if it still needs downloading. Runs off the main actor.
    private static func validatedLocalModelFolder(variant: String) async throws -> URL? {
        validateLocalModelFolder(variant: variant)
    }

    private static func validateLocalModelFolder(variant: String) -> URL? {
        let fm = FileManager.default
        let folder = repoRoot.appendingPathComponent(variant)

        // Repo-level config.json is written by WhisperKit's device-support lookup; a 0-byte
        // copy breaks that lookup, so remove it (it is re-fetched on demand).
        removeIfCorrupt(
            repoRoot.appendingPathComponent("config.json"),
            metadata: metadataRoot.appendingPathComponent("config.json.metadata"),
            minBytes: 1
        )

        guard fm.fileExists(atPath: folder.path) else { return nil }

        if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let file as URL in enumerator {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(file.path.dropFirst(folder.path.count + 1))
                removeIfCorrupt(file, metadata: metadataURL(variant: variant, relativePath: relative), minBytes: 1)
            }
        }

        var complete = true
        for required in requiredFiles {
            let file = folder.appendingPathComponent(required.path)
            let metadata = metadataURL(variant: variant, relativePath: required.path)
            if removeIfCorrupt(file, metadata: metadata, minBytes: required.minBytes) || !fm.fileExists(atPath: file.path) {
                complete = false
            }
        }

        if !complete {
            Self.logger.notice("model folder \(folder.path, privacy: .public) is incomplete")
        }
        return complete ? folder : nil
    }

    private static func metadataURL(variant: String, relativePath: String) -> URL {
        metadataRoot.appendingPathComponent(variant).appendingPathComponent(relativePath + ".metadata")
    }

    /// Returns true if `file` existed and was removed for being smaller than `minBytes`.
    @discardableResult
    private static func removeIfCorrupt(_ file: URL, metadata: URL, minBytes: Int64) -> Bool {
        guard let size = fileSize(file), size < minBytes else { return false }
        Self.logger.notice("removing corrupt file (\(size, privacy: .public) bytes): \(file.path, privacy: .public)")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: metadata)
        return true
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Bytes of the model already on disk, including in-progress `.incomplete` files.
    private static func downloadedBytes(variant: String) async -> Int64 {
        downloadedBytesOnDisk(variant: variant)
    }

    private static func downloadedBytesOnDisk(variant: String) -> Int64 {
        let finished = totalFileBytes(in: repoRoot.appendingPathComponent(variant)) { _ in true }
        let inProgress = totalFileBytes(in: metadataRoot.appendingPathComponent(variant)) {
            $0.pathExtension == "incomplete"
        }
        return finished + inProgress
    }

    private static func totalFileBytes(in root: URL, where include: (URL) -> Bool) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator where include(file) {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Transcription

    @MainActor
    func transcribe(audioURL: URL, translate: Bool = false) async throws -> String {
        if case .failed(let message) = phase {
            throw LocalTranscriptionError.modelUnavailable(message)
        }
        let kit = try await ensureModelLoaded()

        await acquireTranscription()
        defer { releaseTranscription() }
        // Cancelled while queued (ESC, a cancelled import): don't spend a full pass on it.
        try Task.checkCancellation()
        isTranscribing = true
        defer { isTranscribing = false }

        // Translating from English-only makes no sense: let Whisper detect the spoken language.
        var language = await Self.resolveLanguage(kit: kit, path: audioURL.path)
        if translate, language == "en", AppSettings.shared.languageMode == .english {
            language = nil
        }
        let task: DecodingTask = translate ? .translate : .transcribe

        let vocabulary = AppSettings.shared.vocabularyList
        let prompt = Self.vocabularyPrompt(vocabulary)
        let promptTokens = vocabularyPromptDisabled ? nil : prompt.flatMap { Self.promptTokens(for: $0, kit: kit) }
        let path = audioURL.path

        let attempt: String
        if promptTokens != nil {
            attempt = "vocabulary-prompt"
        } else if prompt != nil && vocabularyPromptDisabled {
            attempt = "no-prompt(vocabulary-hint-disabled)"
        } else {
            attempt = "no-prompt"
        }

        do {
            let text = try await decode(
                kit: kit,
                path: path,
                prompt: prompt,
                promptTokens: promptTokens,
                language: language,
                task: task,
                attempt: attempt
            )
            guard text.isEmpty, promptTokens != nil else { return text }

            // A word-list prompt can make Whisper return nothing or echo the list back on real
            // speech. Vocabulary spellings are still applied afterwards by TranscriptionEngineManager.
            Self.logger.notice("empty result with vocabulary prompt (\(vocabulary.count, privacy: .public) words); retrying without prompt")
            let retried = try await decode(kit: kit, path: path, prompt: nil, promptTokens: nil, language: language, task: task, attempt: "retry-no-prompt")
            if !retried.isEmpty {
                vocabularyPromptDisabled = true
                Self.logger.notice("vocabulary hint disabled until relaunch: it emptied a transcript that has speech")
            }
            return retried
        } catch {
            Self.logger.error("transcription error: \(error.localizedDescription, privacy: .public)")
            throw LocalTranscriptionError.transcriptionFailed(Self.describe(error))
        }
    }

    /// One WhisperKit pass. Logs counts and confidence only — never the transcript text.
    @MainActor
    private func decode(
        kit: WhisperKit,
        path: String,
        prompt: String?,
        promptTokens: [Int]?,
        language: String?,
        task: DecodingTask = .transcribe,
        attempt: String
    ) async throws -> String {
        let options = Self.decodingOptions(promptTokens: promptTokens, language: language, task: task)
        let start = Date()
        let results = try await withTimeout(
            seconds: Self.transcriptionTimeoutSeconds,
            operation: "WhisperKit transcription"
        ) {
            try await kit.transcribe(audioPath: path, decodeOptions: options)
        }

        var text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Whisper can echo the conditioning prompt back verbatim instead of transcribing.
        var echoedPrompt = false
        if let prompt, !text.isEmpty, Self.normalized(text) == Self.normalized(prompt) {
            echoedPrompt = true
            text = ""
        }

        lastLanguage = language ?? results.first.map(\.language)
        let segments = results.flatMap { $0.segments }
        let maxNoSpeechProb = segments.map { $0.noSpeechProb }.max() ?? 0
        let seconds = Date().timeIntervalSince(start)
        Self.logger.notice("attempt=\(attempt, privacy: .public) task=\(task == .translate ? "translate" : "transcribe", privacy: .public) language=\(self.lastLanguage ?? "?", privacy: .public) promptTokens=\(promptTokens?.count ?? 0, privacy: .public) segments=\(segments.count, privacy: .public) maxNoSpeechProb=\(maxNoSpeechProb, format: .fixed(precision: 2), privacy: .public) echoedPrompt=\(echoedPrompt, privacy: .public) chars=\(text.count, privacy: .public) seconds=\(seconds, format: .fixed(precision: 1), privacy: .public)")
        return text
    }

    /// Dictation defaults. `language` nil = Whisper detects it for each stretch of speech.
    /// Whisper's standard temperature fallback (0.0 → 1.0 in 0.2 steps) re-decodes windows that
    /// look like repetition loops or low-confidence garbage.
    private static func decodingOptions(promptTokens: [Int]?, language: String?, task: DecodingTask = .transcribe) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: task,
            language: language,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
    }

    // MARK: - Language (N10)

    /// English → "en". Auto → nil (Whisper detects per stretch, so mixed speech works). Chosen
    /// languages → the one Whisper rates likeliest for this audio (a single choice is used as is).
    @MainActor
    private static func resolveLanguage(kit: WhisperKit, path: String) async -> String? {
        let settings = AppSettings.shared
        switch settings.languageMode {
        case .english:
            return "en"
        case .auto:
            return nil
        case .chosen:
            let codes = settings.dictationLanguages
            guard codes.count > 1 else { return codes.first ?? "en" }
            guard let detected = try? await kit.detectLanguage(audioPath: path) else { return codes[0] }
            let probs = Dictionary(detected.langProbs.map { ($0.key.trimmingCharacters(in: CharacterSet(charactersIn: "<|>")), $0.value) },
                                   uniquingKeysWith: max)
            return codes.max { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) } ?? codes[0]
        }
    }

    /// Whisper's language names by code, for Settings.
    static var supportedLanguages: [(code: String, name: String)] {
        Constants.languages
            .map { (code: $0.value, name: $0.key.capitalized) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Live Preview (L1)

    /// A quick pass over the recent audio for the live text in the capsule. Never waits and
    /// never queues: nil when the model isn't loaded or anything else is transcribing. Cancel
    /// the calling task to stop it: WhisperKit returns within ~0.15 s, so the real
    /// transcription (queued behind it) starts almost at once.
    @MainActor
    func previewTranscribe(_ samples: [Float]) async -> String? {
        guard let kit = whisperKit, !transcriptionBusy, samples.count >= 16_000 else { return nil }
        transcriptionBusy = true
        defer { releaseTranscription() }
        let settings = AppSettings.shared
        let language: String? = switch settings.languageMode {
        case .english: "en"
        case .chosen: settings.dictationLanguages.count == 1 ? settings.dictationLanguages.first : nil
        case .auto: nil
        }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            noSpeechThreshold: 0.6
        )
        let start = Date()
        // Called directly (not through withTimeout, which runs it in another task) so that
        // cancelling the caller cancels the decode.
        let text: String
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        Self.logger.notice("preview seconds=\(Double(samples.count) / 16_000, format: .fixed(precision: 1), privacy: .public) chars=\(text.count, privacy: .public) took=\(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public)")
        return text
    }

    // MARK: - One Transcription at a Time

    @MainActor
    private func acquireTranscription() async {
        guard transcriptionBusy else {
            transcriptionBusy = true
            return
        }
        await withCheckedContinuation { transcriptionWaiters.append($0) }
    }

    @MainActor
    private func releaseTranscription() {
        if transcriptionWaiters.isEmpty {
            transcriptionBusy = false
        } else {
            transcriptionWaiters.removeFirst().resume()
        }
    }

    // MARK: - Verification (N14)

    private struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int64
            let sha256: String
        }
        let variant: String
        let revision: String
        let files: [File]
    }

    /// Checks the model folder against Resources/model-manifest.json. Hashing ~1.6GB takes a
    /// few seconds, so a passing result is remembered by file size and date until files change.
    /// Returns false only when files from the pinned revision fail their checksum (they are
    /// deleted, with their Hub metadata, so they download again).
    @MainActor
    private func verifyModel(folder: URL, variant: String) async throws -> Bool {
        guard let url = Bundle.main.url(forResource: "model-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.variant == variant else {
            verification = .unverified("No checksum manifest for this model in this build")
            return true
        }
        verification = .checking
        let result = await Task.detached(priority: .userInitiated) {
            Self.check(folder: folder, variant: variant, manifest: manifest)
        }.value
        switch result {
        case .verified:
            verification = .verified
            Self.logger.notice("model files verified against manifest revision \(manifest.revision.prefix(8), privacy: .public)")
            return true
        case .otherRevision(let revision):
            verification = .unverified("Model revision \(revision.prefix(8)) differs from the pinned \(manifest.revision.prefix(8))")
            Self.logger.notice("model is revision \(revision, privacy: .public); manifest pins \(manifest.revision, privacy: .public)")
            return true
        case .corrupt(let paths):
            Self.logger.error("model files failed checksum: \(paths.joined(separator: ", "), privacy: .public)")
            for path in paths {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(path))
                try? FileManager.default.removeItem(at: Self.metadataURL(variant: variant, relativePath: path))
            }
            verification = .failed("\(paths.count) model file(s) were corrupt and are being downloaded again")
            return false
        }
    }

    private enum CheckResult {
        case verified
        case otherRevision(String)
        case corrupt([String])
    }

    private static func check(folder: URL, variant: String, manifest: Manifest) -> CheckResult {
        let fm = FileManager.default
        // The Hub records the commit each file came from on the first line of its metadata.
        let revision = (try? String(contentsOf: metadataURL(variant: variant, relativePath: "config.json"), encoding: .utf8))?
            .split(separator: "\n").first.map(String.init)
        if let revision, revision != manifest.revision {
            return .otherRevision(revision)
        }

        let stampURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/model-verified.json")
        let stamp = manifest.files.map { file -> String in
            let values = try? folder.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(file.path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n") + "\n" + manifest.revision
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp {
            return .verified
        }

        var corrupt: [String] = []
        for file in manifest.files {
            let url = folder.appendingPathComponent(file.path)
            guard fileSize(url) == file.size, sha256(of: url) == file.sha256 else {
                corrupt.append(file.path)
                continue
            }
        }
        if corrupt.isEmpty {
            try? FileManager.default.createDirectory(at: stampURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            return .verified
        }
        return .corrupt(corrupt)
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Vocabulary words as a Whisper conditioning prompt, which biases decoding toward those
    /// spellings (like OpenAI's `initial_prompt`).
    private static func vocabularyPrompt(_ vocabulary: [String]) -> String? {
        guard !vocabulary.isEmpty else { return nil }
        return vocabulary.joined(separator: ", ") + "."
    }

    private static func promptTokens(for prompt: String, kit: WhisperKit) -> [Int]? {
        guard let tokenizer = kit.tokenizer else { return nil }
        let tokens = tokenizer
            .encode(text: " " + prompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // WhisperKit keeps at most the last ~223 prompt tokens; stay well under that.
        return tokens.isEmpty ? nil : Array(tokens.prefix(120))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
