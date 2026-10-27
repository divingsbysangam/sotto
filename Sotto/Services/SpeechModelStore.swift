import CryptoKit
import Foundation

/// Public model artifacts only. Every byte is pinned in the bundled manifest; runtime loads
/// use local directories and never call a dependency's automatic model downloader.
struct SpeechModelManifest: Codable {
    struct Asset: Codable {
        let repository: String
        let revision: String
        let remotePath: String
        let path: String
        let size: Int64
        let sha256: String
    }
    let engines: [String: [Asset]]
}

enum SpeechModelStore {
    enum StoreError: LocalizedError {
        case missingManifest, notInstalled, invalidAsset(String), download(String), checksum(String)
        var errorDescription: String? {
            switch self {
            case .missingManifest: return "The speech model manifest is missing. Reinstall Sotto."
            case .notInstalled: return "Download this engine in Settings → Transcription before using it."
            case .invalidAsset(let name): return "Invalid model asset: \(name)."
            case .download(let name): return "Couldn't download \(name). Check your connection and retry."
            case .checksum(let name): return "Model verification failed for \(name). Retry to download a fresh copy."
            }
        }
    }

    static func directory(for id: SpeechEngineID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/SpeechModels/\(id.rawValue)", isDirectory: true)
    }

    static func assets(for id: SpeechEngineID) throws -> [SpeechModelManifest.Asset] {
        guard let url = Bundle.main.url(forResource: "speech-model-manifest", withExtension: "json") else {
            throw StoreError.missingManifest
        }
        let manifest = try JSONDecoder().decode(SpeechModelManifest.self, from: Data(contentsOf: url))
        guard let assets = manifest.engines[id.rawValue], !assets.isEmpty else { throw StoreError.missingManifest }
        return assets
    }

    static func isInstalled(_ id: SpeechEngineID, at root: URL? = nil) -> Bool {
        guard let assets = try? assets(for: id) else { return false }
        return assets.allSatisfy { hasExpectedSize($0, in: root ?? directory(for: id)) }
    }

    static func hasExpectedSize(_ asset: SpeechModelManifest.Asset, in root: URL) -> Bool {
        let url = root.appendingPathComponent(asset.path)
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == asset.size
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ asset: SpeechModelManifest.Asset, at root: URL) throws {
        guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains(".."),
              asset.revision.count == 40, asset.sha256.count == 64 else {
            throw StoreError.invalidAsset(asset.path)
        }
        guard hasExpectedSize(asset, in: root), try sha256(root.appendingPathComponent(asset.path)) == asset.sha256 else {
            throw StoreError.checksum(asset.path)
        }
    }

    /// Runs on a generic executor, including disk hashing. Valid assets survive cancellation;
    /// incomplete downloads remain temporary and are never accepted as installed models.
    static func ensure(
        assets: [SpeechModelManifest.Asset], root: URL, allowDownload: Bool,
        session: URLSession = .shared,
        transport: (@Sendable (URL) async throws -> (URL, URLResponse))? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let total = max(1, assets.reduce(Int64(0)) { $0 + $1.size })
        var done: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            do {
                try validate(asset, at: root)
            } catch {
                guard allowDownload else { throw error }
                guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains(".."),
                      asset.revision.count == 40, asset.sha256.count == 64 else {
                    throw StoreError.invalidAsset(asset.path)
                }
                let destination = root.appendingPathComponent(asset.path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let url = URL(string: "https://huggingface.co/\(asset.repository)/resolve/\(asset.revision)/\(asset.remotePath)")!
                let base = done
                let delegate = DownloadProgress { written in
                    progress(min(1, Double(base + written) / Double(total)))
                }
                let (temporary, response): (URL, URLResponse)
                if let transport { (temporary, response) = try await transport(url) }
                else { (temporary, response) = try await session.download(from: url, delegate: delegate) }
                defer { try? fm.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreError.download(asset.path) }
                guard (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == asset.size,
                      try sha256(temporary) == asset.sha256 else { throw StoreError.checksum(asset.path) }
                // Keep an existing verified copy until its replacement has passed validation.
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temporary, to: destination)
            }
            done += asset.size
            progress(Double(done) / Double(total))
        }
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64) -> Void
        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
