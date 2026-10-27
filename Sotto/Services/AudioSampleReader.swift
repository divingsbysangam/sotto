import AVFoundation

/// Reads an audio file as 16 kHz mono Float chunks.
final class AudioSampleReader {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private var pendingSamples: [Float] = []
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: Self.format) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.converter = converter
    }

    /// Up to `seconds` of audio, or nil at the end.
    func read(seconds: Int) throws -> [Float]? {
        let wanted = seconds * 16_000
        guard wanted > 0 else { return nil }
        // AVAudioFile can return packet-aligned reads shorter than requested, even for a
        // 60-second WAV. Accumulate them so engines don't receive a spurious <0.3s tail.
        while pendingSamples.count < wanted, let converted = try readConverted(seconds: seconds) {
            guard !converted.isEmpty else { break }
            pendingSamples.append(contentsOf: converted)
        }
        guard !pendingSamples.isEmpty else { return nil }
        let count = min(wanted, pendingSamples.count)
        let result = Array(pendingSamples.prefix(count))
        pendingSamples.removeFirst(count)
        return result
    }

    private func readConverted(seconds: Int) throws -> [Float]? {
        let sourceFrames = AVAudioFrameCount(Double(seconds) * file.processingFormat.sampleRate)
        guard file.framePosition < file.length,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceFrames) else { return nil }
        try file.read(into: input, frameCount: sourceFrames)
        guard input.frameLength > 0,
              let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(seconds * 16_000) + 1024) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
