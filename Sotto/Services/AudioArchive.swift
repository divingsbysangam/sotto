import AVFoundation
import os

/// Dictation audio kept under "Keep audio for", as AAC in M4A (about a third of the WAV's size)
/// in `~/Library/Application Support/Sotto/Audio/<entry id>.m4a`.
enum AudioArchive {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "AudioArchive")

    static let directory: URL = {
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Sotto-test-audio-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sotto/Audio", isDirectory: true)
    }()

    static func fileName(for entryID: UUID) -> String {
        "\(entryID.uuidString).m4a"
    }

    /// Encodes the temporary WAV into the archive, then deletes the WAV whether or not that
    /// worked. Runs in the background; the history row simply shows no audio until it's done.
    static func archive(wav: URL, as fileName: String) {
        Task.detached(priority: .utility) {
            let destination = directory.appendingPathComponent(fileName)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try await encodeM4A(from: wav, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                logger.notice("archived \(fileName, privacy: .public) bytes=\(size, privacy: .public)")
            } catch {
                try? FileManager.default.removeItem(at: destination)
                logger.error("failed to archive \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            try? FileManager.default.removeItem(at: wav)
        }
    }

    static func delete(fileNames: [String]) {
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                logger.notice("deleted \(name, privacy: .public)")
            }
        }
    }

    /// Deletes audio older than `maxAge` (nil = keep forever; 0 = keep none) and any file no
    /// history entry refers to (e.g. its transcript was deleted while Sotto wasn't running).
    /// `protected` files (failed dictations awaiting a retry) are never deleted for age.
    static func prune(olderThan maxAge: TimeInterval?, keeping referenced: Set<String>, protecting protected: Set<String> = []) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = maxAge.map { Date().addingTimeInterval(-$0) }
        var removed = 0
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let expired = !protected.contains(file.lastPathComponent) && (cutoff.map { created < $0 } ?? false)
            let orphaned = !referenced.contains(file.lastPathComponent)
            if expired || orphaned, (try? FileManager.default.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            logger.notice("pruned \(removed, privacy: .public) audio file(s)")
        }
    }

    private static func encodeM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if #available(macOS 15, *) {
            try await session.export(to: destination, as: .m4a)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            if let error = session.error { throw error }
            guard session.status == .completed else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
