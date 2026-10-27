import AVFoundation
import Observation
import os

/// L13: reads transcripts aloud with the system's on-device voices (AVSpeechSynthesizer).
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Speech")

    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `text`, replacing anything being read now.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        let settings = AppSettings.shared
        if let id = settings.readAloudVoiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = Self.utteranceRate(settings.readAloudRate)
        isSpeaking = true
        synthesizer.speak(utterance)
        Self.logger.notice("speaking chars=\(trimmed.count, privacy: .public)")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Speaks `text`, or stops if something is being read (one key for both).
    func toggle(_ text: String) {
        if isSpeaking {
            stop()
        } else {
            speak(text)
        }
    }

    /// Settings store a 0.5×–2× multiplier of the default rate; AVSpeech takes 0…1.
    static func utteranceRate(_ multiplier: Double) -> Float {
        let rate = Double(AVSpeechUtteranceDefaultSpeechRate) * min(max(multiplier, 0.5), 2)
        return Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    /// Installed voices, grouped by language name, best quality first.
    static func voicesByLanguage() -> [(language: String, voices: [AVSpeechSynthesisVoice])] {
        let current = Locale.current
        let groups = Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices()) { voice in
            current.localizedString(forIdentifier: voice.language) ?? voice.language
        }
        return groups
            .map { language, voices in
                (language, voices.sorted {
                    $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name
                })
            }
            .sorted { $0.language.localizedCaseInsensitiveCompare($1.language) == .orderedAscending }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = self.synthesizer.isSpeaking }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = self.synthesizer.isSpeaking }
    }
}
