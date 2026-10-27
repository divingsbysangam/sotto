import AVFoundation
import Foundation
import os

enum RecordingState {
    case idle
    case recording
    case processing
}

@Observable
final class RecordingService {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Recording")
    private static let fileNamePrefix = "recording_"

    private(set) var state: RecordingState = .idle
    private(set) var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    private let audioQueue = DispatchQueue(label: "com.divingsbysangam.sotto.audio", qos: .userInteractive)

    /// L1: set before `startRecording()` to also keep a 16 kHz mono copy for the live preview.
    var capturesLiveAudio = false
    /// The last `liveSeconds` of audio at 16 kHz mono. Guarded by `audioQueue`.
    private var liveSamples: [Float] = []
    private var liveConverter: AVAudioConverter?
    private static let liveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// The capsule shows about two lines, so the last 10 s is plenty; a 10 s pass takes ~0.7 s
    /// on an M4 (30 s: ~1.6 s, which would keep the model busy nonstop).
    static let liveSeconds = 10

    init() {}

    func startRecording() throws -> URL {
        guard state == .idle else {
            throw RecordingError.alreadyRecording
        }

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw RecordingError.permissionDenied
        case .notDetermined:
            // Request permission synchronously for simplicity
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { result in
                granted = result
                semaphore.signal()
            }
            semaphore.wait()
            if !granted {
                throw RecordingError.permissionDenied
            }
        case .authorized:
            break
        @unknown default:
            break
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        // N9: the chosen microphone (falls back to the system default if it's missing).
        AudioInputDevices.select(uid: AppSettings.shared.inputDeviceUID, on: audioEngine)

        // Get the native format from the input node - CRITICAL: use inputFormat, not outputFormat
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(Self.fileNamePrefix)\(Date().timeIntervalSince1970).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Create audio file with native format settings. If anything below fails, remove the
        // file so a failed start doesn't leave audio behind.
        var started = false
        defer {
            if !started { cleanup(url: fileURL) }
        }
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )

        let converter = capturesLiveAudio ? AVAudioConverter(from: inputFormat, to: Self.liveFormat) : nil
        audioQueue.sync {
            liveSamples = []
            liveConverter = converter
        }

        // Install tap on input node using its native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.audioQueue.async {
                do {
                    try audioFile.write(from: buffer)
                    self?.updateAudioLevel(buffer: buffer)
                    self?.appendLiveAudio(buffer)
                } catch {
                    print("[RecordingService] Error writing: \(error)")
                }
            }
        }

        // Prepare and start the engine
        audioEngine.prepare()
        try audioEngine.start()

        self.audioEngine = audioEngine
        self.audioFile = audioFile
        self.recordingURL = fileURL
        self.state = .recording
        started = true

        return fileURL
    }

    /// Keeps capturing for `tail` seconds before finalizing the file, so the last word isn't
    /// clipped when the key comes up right as it's spoken. No new recording can start meanwhile.
    /// Cancelling the calling task ends the tail early; `stopRecording()` during the tail stops
    /// capture at once and this then returns nil.
    @MainActor
    func stopRecording(tail: TimeInterval) async -> URL? {
        guard state == .recording else { return nil }
        state = .processing
        if tail > 0 {
            try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
        }
        return stopRecording()
    }

    /// Stops capture immediately (ESC, or the end of the tail).
    func stopRecording() -> URL? {
        guard audioEngine != nil else { return nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // Tap buffers are written asynchronously; drain them so the last words are in the file
        // and the AVAudioFile is released (header finalized) before transcription reads it.
        audioQueue.sync {
            liveConverter = nil
            liveSamples = []
        }
        audioFile = nil

        state = .processing

        let url = recordingURL
        recordingURL = nil

        if let url = url {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                print("[RecordingService] Recording stopped. File size: \(size) bytes")
            }
        }

        return url
    }

    func reset() {
        state = .idle
        audioLevel = 0
    }

    /// Deletes a recording once it's no longer needed (after paste, cancel, or error).
    func cleanup(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            Self.logger.notice("deleted recording \(url.lastPathComponent, privacy: .public)")
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            Self.logger.error("failed to delete recording \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sweep for recordings a crash, force-quit, or reinstall left behind; runs at launch and at
    /// each recording start. Skips recent files so a recording that is still being written or
    /// transcribed is never touched.
    static func removeStaleRecordings(olderThan age: TimeInterval = 5 * 60) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for file in files where file.lastPathComponent.hasPrefix(fileNamePrefix) && file.pathExtension == "wav" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            logger.notice("removed \(removed, privacy: .public) stale recording(s) from \(tempDir.path, privacy: .public)")
        }
    }

    /// L1: a copy of the recent 16 kHz mono audio for the live preview (empty when off).
    func liveAudio() -> [Float] {
        audioQueue.sync { liveSamples }
    }

    /// Runs on `audioQueue`.
    private func appendLiveAudio(_ buffer: AVAudioPCMBuffer) {
        guard let converter = liveConverter else { return }
        let ratio = Self.liveFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.liveFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.floatChannelData?[0], output.frameLength > 0 else { return }
        liveSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        // Trim in one-second steps so the copy stays cheap.
        let limit = Self.liveSeconds * 16_000
        if liveSamples.count > limit + 16_000 {
            liveSamples.removeFirst(liveSamples.count - limit)
        }
    }

    private func updateAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 0.0001))
        let normalizedLevel = max(0, min(1, (db + 60) / 60))

        DispatchQueue.main.async {
            self.audioLevel = normalizedLevel
        }
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case permissionDenied
    case audioEngineError(Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .permissionDenied:
            return "Microphone access denied. Please enable in System Settings."
        case .audioEngineError(let error):
            return "Audio engine error: \(error.localizedDescription)"
        }
    }
}
