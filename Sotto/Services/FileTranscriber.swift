import AVFoundation
import UniformTypeIdentifiers
import os

/// N13: transcribes an audio or video file (m4a, mp3, wav, mov, mp4, …) with the dictation
/// model. AVFoundation decodes it to 16 kHz mono off the main thread, in 60-second chunks: each
/// stays well inside the per-transcription timeout, progress can be shown, and cancelling (or a
/// dictation, which waits for at most one chunk) is possible between chunks.
enum FileTranscriber {
    static let chunkSeconds: Double = 60
    static let sampleRate: Double = 16_000

    /// What Sotto accepts from drops, Open With, and File › Import.
    static let contentTypes: [UTType] = [.audio, .movie]

    enum ImportError: LocalizedError {
        case noAudio
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The file has no audio track."
            case .unreadable(let reason): return "The file couldn't be read (\(reason))."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "FileImport")

    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    /// Returns the joined transcript and the file's duration. `transcribeChunk` runs on the main
    /// actor for each chunk (a 16 kHz mono WAV that is deleted afterwards).
    @MainActor
    static func transcribe(
        _ url: URL,
        progress: @escaping @MainActor (Double) -> Void,
        transcribeChunk: @escaping @MainActor (URL) async throws -> String
    ) async throws -> (text: String, duration: TimeInterval) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ImportError.noAudio }
        logger.notice("import start duration=\(Int(duration), privacy: .public)s")

        let chunks = decodeChunks(asset: asset, track: track)
        var pieces: [String] = []
        var done: Double = 0
        for try await chunk in chunks {
            try Task.checkCancellation()
            defer { try? FileManager.default.removeItem(at: chunk.url) }
            let text = try await transcribeChunk(chunk.url)
            if !text.isEmpty { pieces.append(text) }
            done += chunk.seconds
            progress(duration > 0 ? min(1, done / duration) : 1)
        }
        logger.notice("import done chunks=\(pieces.count, privacy: .public)")
        return (pieces.joined(separator: " "), duration)
    }

    private struct Chunk {
        let url: URL
        let seconds: Double
    }

    /// Decodes on a background task; cancelling the consumer stops it.
    private static func decodeChunks(asset: AVURLAsset, track: AVAssetTrack) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ])
                    reader.add(output)
                    guard reader.startReading() else {
                        throw ImportError.unreadable(reader.error?.localizedDescription ?? "unknown")
                    }
                    let chunkSamples = Int(sampleRate * chunkSeconds)
                    var samples: [Float] = []
                    samples.reserveCapacity(chunkSamples)
                    while let buffer = output.copyNextSampleBuffer() {
                        try Task.checkCancellation()
                        samples.append(contentsOf: floats(in: buffer))
                        while samples.count >= chunkSamples {
                            let piece = Array(samples.prefix(chunkSamples))
                            samples.removeFirst(chunkSamples)
                            continuation.yield(try writeChunk(piece))
                        }
                    }
                    if reader.status == .failed {
                        throw ImportError.unreadable(reader.error?.localizedDescription ?? "decode failed")
                    }
                    if !samples.isEmpty {
                        continuation.yield(try writeChunk(samples))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func floats(in buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var result = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        result.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return result
    }

    private static func writeChunk(_ samples: [Float]) throws -> Chunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import_\(UUID().uuidString).wav")
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        // Scoped so the file is closed (header written) before it's transcribed.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return Chunk(url: url, seconds: Double(samples.count) / sampleRate)
    }
}
