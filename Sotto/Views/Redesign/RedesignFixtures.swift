#if DEBUG
import SwiftUI

/// All examples are invented. Do not replace these with shared settings or history.
enum RedesignFixtures {
    enum Phase: String, CaseIterable, Identifiable {
        case ready = "Ready", microphone = "Microphone denied", missing = "Model missing"
        case downloading = "Downloading", verifying = "Verifying", loading = "Loading"
        case failed = "Model failed", recording = "Recording", processing = "Processing"
        case copied = "Copied", pasted = "Pasted", scratchpad = "Saved to Scratchpad"
        var id: Self { self }

        var presentation: SottoStatusPresentation {
            switch self {
            case .ready:
                return .init(title: "Ready to dictate", detail: "Whisper Turbo is ready on this Mac.", symbol: "checkmark.circle.fill", tone: .ready)
            case .microphone:
                return .init(title: "Allow microphone access", detail: "Sotto needs your microphone to hear you while you dictate.", symbol: "mic.slash.fill", tone: .attention, actionTitle: "Review Microphone Settings")
            case .missing:
                return .init(title: "Download a speech model", detail: "Download Whisper Turbo once, then dictate offline.", symbol: "arrow.down.circle.fill", tone: .attention, actionTitle: "Open Speech Settings")
            case .downloading:
                return .init(title: "Downloading Whisper Turbo", detail: "640 MB of 1.6 GB · Dictation will be available after setup.", symbol: "arrow.down.circle.fill", progress: 0.4)
            case .verifying:
                return .init(title: "Verifying model", detail: "Checking downloaded files before loading.", symbol: "checkmark.shield.fill")
            case .loading:
                return .init(title: "Loading Whisper Turbo", detail: "Preparing on-device dictation.", symbol: "waveform.circle.fill")
            case .failed:
                return .init(title: "Speech model needs attention", detail: "The model could not be loaded. Retry in speech settings.", symbol: "exclamationmark.triangle.fill", tone: .attention, actionTitle: "Open Speech Settings")
            case .recording:
                return .init(title: "Listening", detail: "Release your shortcut to finish. Press Escape to cancel.", symbol: "mic.fill", tone: .recording)
            case .processing:
                return .init(title: "Preparing your transcript", detail: "Transcribing and cleaning up on this Mac.", symbol: "waveform.circle.fill")
            case .copied:
                return .init(title: "Copied to clipboard", detail: "Paste into your app with Command-V. Allow Accessibility for automatic paste.", symbol: "doc.on.clipboard.fill", tone: .ready)
            case .pasted:
                return .init(title: "Pasted", detail: "Your transcript was pasted into the target app.", symbol: "checkmark.circle.fill", tone: .ready)
            case .scratchpad:
                return .init(title: "Saved to Scratchpad", detail: "Your words are saved in the selected note.", symbol: "note.text", tone: .ready)
            }
        }
    }

    static let transcripts: [SottoTranscriptPresentation] = [
        .init(id: "sample-1", text: "Let’s keep the first version small. I’ll send the revised outline after lunch.", source: "Notes", metadata: "10:42 AM · 18 words"),
        .init(id: "sample-2", text: "A quieter workspace starts with knowing what needs your attention.", source: "Scratchpad", metadata: "9:18 AM · 12 words"),
        .init(id: "sample-3", text: "Audio retained for retry", source: "Imported recording", metadata: "Yesterday · 24 sec", failure: "The speech model could not finish this transcript.", canRetry: true)
    ]
}
#endif
