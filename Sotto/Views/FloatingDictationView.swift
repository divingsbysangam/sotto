import SwiftUI

enum DictationState: Equatable {
    case recording
    case processing(status: String = "Transcribing…")
    case readyToPaste(text: String)
}

final class FloatingDictationModel: ObservableObject {
    @Published var state: DictationState
    @Published var modeName: String?
    @Published var isPresented = false
    @Published var generation = UUID()

    init(state: DictationState = .recording, modeName: String? = nil) {
        self.state = state
        self.modeName = modeName
    }

    struct CountdownKey: Equatable {
        let state: DictationState
        let generation: UUID
        let isPresented: Bool
    }
    var countdownKey: CountdownKey { .init(state: state, generation: generation, isPresented: isPresented) }
}

struct FloatingDictationView: View {
    @ObservedObject var model: FloatingDictationModel
    let level: CapsuleLevel
    let onCancel: () -> Void
    let onPasteNow: () -> Void
    @State private var countdown = 3
    @State private var didPaste = false

    private var status: SottoStatusPresentation {
        switch model.state {
        case .recording: return RecordingOverlayStatus.make(isProcessing: false, message: "")
        case .processing(let message): return RecordingOverlayStatus.make(isProcessing: true, message: message)
        case .readyToPaste: return .init(title: "Ready to paste", detail: "", symbol: "doc.on.clipboard", tone: .ready)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Label(status.title, systemImage: status.symbol)
                    .font(.headline).foregroundStyle(status.color).lineLimit(2)
                Spacer(minLength: 0)
                SottoIconButton(symbol: .close, label: "Cancel dictation", action: onCancel)
            }
            .padding(12)
            .sottoFloatingControls()
            if let mode = model.modeName {
                Label(mode, systemImage: SottoSymbol.appModes.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch model.state {
            case .recording:
                CapsuleAudioMeter(level: level).frame(maxWidth: .infinity).frame(height: 36)
                Text("Release your shortcut to finish. In hands-free mode, tap it again to stop.")
                    .font(.callout).foregroundStyle(.secondary)
                SottoShortcutHint(keys: "Esc", instruction: "Cancel recording")
            case .processing:
                Text("Processing on this Mac.").font(.caption).foregroundStyle(.secondary)
            case .readyToPaste(let text):
                Text(text).font(.body).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                    .sottoSurface()
                HStack {
                    Text("Pasting in \(countdown)s…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Paste Now", action: pasteOnce).sottoPrimaryAction()
                }
                ProgressView(value: Double(countdown), total: 3).accessibilityLabel("Time before paste")
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.secondary.opacity(0.25)))
        .tint(SottoDesign.accent)
        .task(id: model.countdownKey) {
            countdown = 3
            didPaste = false
            guard model.isPresented, case .readyToPaste = model.state else { return }
            for remaining in stride(from: 3, through: 1, by: -1) {
                countdown = remaining
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, model.isPresented, case .readyToPaste = model.state else { return }
            pasteOnce()
        }
    }

    private func pasteOnce() {
        guard !didPaste, model.isPresented, case .readyToPaste = model.state else { return }
        didPaste = true
        onPasteNow()
    }
}

/// Only this leaf observes audio levels, so model, buttons and countdown retain identity.
struct CapsuleAudioMeter: View {
    @ObservedObject var level: CapsuleLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sottoAccessibilityPreview) private var accessibilityPreview

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { index in
                let variation = Float(index % 3 + 1) / 3
                RoundedRectangle(cornerRadius: 2)
                    .fill(SottoDesign.accent)
                    .frame(width: 4, height: max(4, CGFloat(min(1, max(0, level.value))) * CGFloat(variation) * 28))
            }
        }
        .frame(height: 28)
        .animation(reduceMotion || accessibilityPreview ? nil : .easeOut(duration: SottoDesign.feedbackDuration), value: level.value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
    }
}
