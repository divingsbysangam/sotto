import Foundation
import Observation

enum DictationOutput: Equatable {
    case output(OutputService.Outcome)
    case scratchpadSaved
    case scratchpadUnsaved
}

/// Operation-scoped feedback. A late output callback cannot replace a newer operation's state.
@Observable
final class DictationFeedback {
    private(set) var generation = UUID()
    private(set) var result: DictationOutput?

    @discardableResult func begin() -> UUID {
        generation = UUID()
        result = nil
        return generation
    }

    @discardableResult func complete(_ result: DictationOutput, for generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        self.result = result
        return true
    }
}

struct DictationPresentation {
    struct Item {
        let status: SottoStatusPresentation
        var route: SottoRoute? = nil
    }
    let primary: Item
    var readiness: Item? = nil

    static func make(
        recording: RecordingState,
        processingStatus: String,
        microphoneAllowed: Bool,
        accessibilityAllowed: Bool,
        engineName: String,
        enginePhase: SpeechEnginePhase,
        progress: Double,
        fallbackNotice: String?,
        error: String?,
        output: DictationOutput?
    ) -> Self {
        if recording == .recording {
            return .init(primary: .init(status: .init(title: "Listening", detail: "Release your shortcut to finish. Press Escape to cancel.", symbol: "mic.fill", tone: .recording)))
        }
        if recording == .processing {
            return .init(primary: .init(status: .init(title: "Preparing your transcript", detail: processingStatus.isEmpty ? "Transcribing on this Mac…" : processingStatus, symbol: "waveform.circle.fill")))
        }

        let ready: Item
        if !microphoneAllowed {
            ready = .init(status: .init(title: "Allow microphone access", detail: "Allow Sotto to use your microphone while you dictate.", symbol: "mic.slash.fill", tone: .attention, actionTitle: "Review Permissions"), route: .settings(.system))
        } else {
            let modelDetail = fallbackNotice ?? "\(engineName) · On this Mac"
            switch enginePhase {
            case .ready:
                ready = .init(status: .init(title: "Ready to dictate", detail: accessibilityAllowed ? modelDetail : modelDetail + " · Clipboard output is available. Allow Accessibility for automatic paste.", symbol: "checkmark.circle.fill", tone: .ready, actionTitle: accessibilityAllowed ? nil : "Review Permissions"), route: accessibilityAllowed ? nil : .settings(.system))
            case .notInstalled:
                ready = .init(status: .init(title: "Speech model not installed", detail: modelDetail + " · Download the model in speech settings.", symbol: "arrow.down.circle.fill", tone: .attention, actionTitle: "Open Speech Settings"), route: .settings(.transcription))
            case .idle:
                ready = .init(status: .init(title: "Speech model not loaded", detail: modelDetail, symbol: "waveform.circle.fill", actionTitle: "Open Speech Settings"), route: .settings(.transcription))
            case .downloading:
                ready = .init(status: .init(title: "Downloading speech model", detail: modelDetail, symbol: "arrow.down.circle.fill", progress: min(1, max(0, progress)), actionTitle: "Open Speech Settings"), route: .settings(.transcription))
            case .verifying:
                ready = .init(status: .init(title: "Verifying speech model", detail: modelDetail, symbol: "checkmark.shield.fill"))
            case .loading:
                ready = .init(status: .init(title: "Loading speech model", detail: modelDetail, symbol: "waveform.circle.fill"))
            case .failed(let message):
                ready = .init(status: .init(title: "Speech model needs attention", detail: message, symbol: "exclamationmark.triangle.fill", tone: .attention, actionTitle: "Open Speech Settings"), route: .settings(.transcription))
            }
        }
        if let error, !error.isEmpty {
            return .init(primary: .init(status: .init(title: "Dictation needs attention", detail: error, symbol: "exclamationmark.triangle.fill", tone: .attention, actionTitle: "Open Transcripts"), route: .destination(.transcripts)), readiness: ready)
        }
        if let output, let result = outputItem(output) {
            return .init(primary: result, readiness: ready)
        }
        return .init(primary: ready)
    }

    private static func outputItem(_ output: DictationOutput) -> Item? {
        switch output {
        case .output(.cancelled): return nil
        case .output(.pasted):
            return .init(status: .init(title: "Pasted", detail: "The paste command was sent to your app.", symbol: "checkmark.circle.fill", tone: .ready))
        case .output(.copied):
            return .init(status: .init(title: "Copied to clipboard", detail: "Paste into your app with Command-V.", symbol: "doc.on.clipboard.fill", tone: .ready))
        case .output(.copiedMissingAccessibility):
            return .init(status: .init(title: "Copied to clipboard", detail: "Allow Accessibility for automatic paste, or paste with Command-V.", symbol: "doc.on.clipboard.fill", actionTitle: "Review Permissions"), route: .settings(.system))
        case .output(.copiedAppChanged):
            return .init(status: .init(title: "Copied to clipboard", detail: "The target app changed. Paste with Command-V where you want your words.", symbol: "doc.on.clipboard.fill"))
        case .output(.copiedPasteFailed):
            return .init(status: .init(title: "Copied to clipboard", detail: "Automatic paste could not be sent. Paste with Command-V.", symbol: "doc.on.clipboard.fill", tone: .attention))
        case .output(.failed):
            return .init(status: .init(title: "Text could not be copied", detail: "Your transcript is available in Transcripts.", symbol: "exclamationmark.triangle.fill", tone: .attention, actionTitle: "Open Transcripts"), route: .destination(.transcripts))
        case .scratchpadSaved:
            return .init(status: .init(title: "Saved to Scratchpad", detail: "Your words were saved in the selected note.", symbol: "note.text", tone: .ready))
        case .scratchpadUnsaved:
            return .init(status: .init(title: "Scratchpad could not save", detail: "Your words remain in the open note and in Transcripts. Copy them before quitting.", symbol: "exclamationmark.triangle.fill", tone: .attention, actionTitle: "Open Transcripts"), route: .destination(.transcripts))
        }
    }
}
