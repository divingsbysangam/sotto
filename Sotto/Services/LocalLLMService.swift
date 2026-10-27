import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Observation
import os
import Tokenizers

/// L5: an optional small LLM for cleanup on Macs without Apple Intelligence (or when forced for
/// testing). Qwen2.5 1.5B Instruct, 4-bit MLX weights (~0.9 GB), downloaded on demand from a
/// pinned Hugging Face revision and checked by size and SHA-256; runs in-process on the GPU (no
/// server). Loaded on first use and unloaded after 10 idle minutes.
@Observable
final class LocalLLMService {
    static let shared = LocalLLMService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "LocalLLM")

    static let repo = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    static let revision = "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"
    static let displayName = "Qwen2.5 1.5B Instruct (4-bit)"
    /// Files and sizes at `revision`; the weights are also checked by SHA-256.
    static let files: [(name: String, size: Int64)] = [
        ("added_tokens.json", 605), ("config.json", 784), ("merges.txt", 1_671_853),
        ("model.safetensors", 868_628_559), ("model.safetensors.index.json", 51_569),
        ("special_tokens_map.json", 613), ("tokenizer.json", 7_031_673),
        ("tokenizer_config.json", 7_308), ("vocab.json", 2_776_833),
    ]
    static let weightsSHA256 = "0979f33d1bc58afcf696d13f57977644e7b11a6f0eec3e631d8e9463d18c0717"
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    static let idleUnloadAfter: TimeInterval = 10 * 60

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var state: State = .notInstalled
    /// Memory the loaded model added to Sotto (phys_footprint delta at load), for Settings.
    private(set) var measuredMemoryMB: Double?
    private(set) var isLoaded = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var loadTask: Task<ModelContainer, Error>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Timer?

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/LLM/Qwen2.5-1.5B-Instruct-4bit", isDirectory: true)
    }

    private init() {
        state = Self.isInstalledOnDisk ? .installed : .notInstalled
        // Keep MLX's buffer cache small: Whisper shares the machine.
        MLX.Memory.cacheLimit = 64 * 1024 * 1024
    }

    /// All files present with the expected sizes (the hash is checked after download).
    static var isInstalledOnDisk: Bool {
        files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.name).path)[.size] as? Int64) ?? -1
            return size == file.size
        }
    }

    /// Installed and turned on: cleanup may use it.
    var isUsable: Bool {
        state == .installed && AppSettings.shared.localLLMEnabled
    }

    // MARK: - Download

    @MainActor
    func download() {
        guard downloadTask == nil else { return }
        state = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                try await Self.fetchFiles { fraction in
                    Task { @MainActor in self?.state = .downloading(fraction) }
                }
                await MainActor.run { self?.state = .installed }
                Self.logger.notice("local LLM downloaded")
            } catch is CancellationError {
                await MainActor.run { self?.state = Self.isInstalledOnDisk ? .installed : .notInstalled }
            } catch {
                Self.logger.error("local LLM download failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
            await MainActor.run { self?.downloadTask = nil }
        }
    }

    @MainActor
    func cancelDownload() {
        downloadTask?.cancel()
    }

    @MainActor
    func remove() {
        downloadTask?.cancel()
        Task { @MainActor in
            await ModelWorkGate.shared.acquire()
            defer { ModelWorkGate.shared.release() }
            await downloadTask?.value
            unloadWhileLocked()
            try? FileManager.default.removeItem(at: Self.directory)
            state = .notInstalled
            measuredMemoryMB = nil
            Self.logger.notice("local LLM removed")
        }
    }

    private enum DownloadError: LocalizedError {
        case badResponse(String)
        case sizeMismatch(String)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .badResponse(let file): return "Couldn't download \(file)."
            case .sizeMismatch(let file): return "\(file) downloaded incompletely."
            case .checksumMismatch: return "The model file didn't match its checksum and was deleted."
            }
        }
    }

    /// Downloads each missing file to a temporary name, checks it, then moves it into place.
    private static func fetchFiles(progress: @escaping (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var done: Int64 = files.filter { file in
            (try? fm.attributesOfItem(atPath: directory.appendingPathComponent(file.name).path)[.size] as? Int64) == file.size
        }.reduce(0) { $0 + $1.size }
        progress(Double(done) / Double(totalBytes))
        for file in files {
            let destination = directory.appendingPathComponent(file.name)
            if (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) == file.size { continue }
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.name)")!
            let base = done
            let delegate = ProgressDelegate { written in
                progress(Double(base + written) / Double(totalBytes))
            }
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.badResponse(file.name) }
            let size = (try fm.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? -1
            guard size == file.size else {
                try? fm.removeItem(at: temporary)
                throw DownloadError.sizeMismatch(file.name)
            }
            if file.name == "model.safetensors" {
                guard try sha256(of: temporary) == weightsSHA256 else {
                    try? fm.removeItem(at: temporary)
                    throw DownloadError.checksumMismatch
                }
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temporary, to: destination)
            done += file.size
            progress(Double(done) / Double(totalBytes))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: (Int64) -> Void
        init(_ onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesWritten)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    // MARK: - Generation

    /// One cleanup pass. The dictation is sent between <<< and >>> markers, which keeps the small
    /// model from answering or acting on it (tested: 8/8 faithful vs 5/8 without).
    @MainActor
    func respond(system: String, dictation: String) async throws -> String {
        await ModelWorkGate.shared.acquire()
        defer { ModelWorkGate.shared.release() }
        try Task.checkCancellation()
        let container = try await loadedContainer()
        scheduleUnload()
        let wordCount = dictation.split(whereSeparator: \.isWhitespace).count
        let parameters = GenerateParameters(maxTokens: min(1024, wordCount * 3 + 64), temperature: 0)
        let session = ChatSession(
            container,
            instructions: system + "\n\nThe dictation is between <<< and >>>. Output only the cleaned dictation, without the markers.",
            generateParameters: parameters
        )
        var output = try await session.respond(to: "<<<\(dictation)>>>").trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        if output.hasPrefix("<<<") { output.removeFirst(3) }
        if output.hasSuffix(">>>") { output.removeLast(3) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        let before = Self.footprintMB()
        let task = Task { try await loadModelContainer(from: Self.directory, using: TokenizerLoaderBridge()) }
        loadTask = task
        defer { loadTask = nil }
        let container = try await task.value
        self.container = container
        isLoaded = true
        measuredMemoryMB = max(0, Self.footprintMB() - before)
        Self.logger.notice("local LLM loaded memoryMB=\(self.measuredMemoryMB ?? 0, format: .fixed(precision: 0), privacy: .public)")
        return container
    }

    @MainActor
    private func scheduleUnload() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleUnloadAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.unload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    @MainActor
    func unload() {
        Task { @MainActor in
            await ModelWorkGate.shared.acquire()
            defer { ModelWorkGate.shared.release() }
            unloadWhileLocked()
        }
    }

    @MainActor
    func unloadWhileLocked() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard container != nil else { return }
        container = nil
        isLoaded = false
        MLX.Memory.clearCache()
        Self.logger.notice("local LLM unloaded (idle)")
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

// MARK: - swift-transformers tokenizer for MLX

private struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
