import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

/// N6: guided first-run setup. Microphone (with a live level check) → Accessibility → press
/// your shortcut → practice dictation → optional Screen Recording. Re-runnable from Help.
struct OnboardingView: View {
    var appState: AppState
    var onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case microphone, accessibility, shortcut, practice, screenRecording

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .shortcut: return "Your Shortcut"
            case .practice: return "Try It"
            case .screenRecording: return "Screen Context"
            }
        }
    }

    @State private var step: Step = .microphone
    init(appState: AppState, initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.appState = appState
        self.onFinish = onFinish
        _step = State(initialValue: Step(rawValue: initialStep) ?? .microphone)
    }
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var level = MicLevelMonitor()
    @State private var shortcutPressed = false
    @State private var practiceText = ""
    @State private var historyCountAtPractice = 0
    @FocusState private var practiceFocused: Bool

    private var model: any TranscriptionEngine {
        let manager = TranscriptionEngineManager.shared
        return manager.engine(for: manager.effectiveID)
    }
    private let history = TranscriptionHistoryManager.shared
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Set up Sotto", systemImage: "waveform")
                Spacer()
                Text("\(step.rawValue + 1) of \(Step.allCases.count)").foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .accessibilityLabel("Setup progress")

            Text(step.title)
                .font(.title2)
                .fontWeight(.semibold)

            Group {
                switch step {
                case .microphone: microphoneStep
                case .accessibility: accessibilityStep
                case .shortcut: shortcutStep
                case .practice: practiceStep
                case .screenRecording: screenRecordingStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .sottoSurface()

            modelProgress

            HStack {
                if step != .microphone {
                    Button("Back") { move(-1) }
                }
                Spacer()
                if step == .screenRecording {
                    Button("Finish") { finish() }
                        .sottoPrimaryAction()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(stepDone ? "Continue" : "Skip") { move(1) }
                        .sottoPrimaryAction()
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(SottoDesign.accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if step == .microphone { level.start() } }
        .onDisappear { level.stop() }
        .onReceive(poll) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityGranted = AXIsProcessTrusted()
            if step == .shortcut, appState.recordingState != .idle { shortcutPressed = true }
        }
        .onChange(of: appState.recordingState) {
            if step == .shortcut, appState.recordingState != .idle { shortcutPressed = true }
        }
    }

    private var stepDone: Bool {
        switch step {
        case .microphone: return micStatus == .authorized
        case .accessibility: return accessibilityGranted
        case .shortcut: return shortcutPressed
        case .practice: return practiceSucceeded
        case .screenRecording: return true
        }
    }

    private var practiceSucceeded: Bool {
        !practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || history.entries.count > historyCountAtPractice
    }

    // MARK: Steps

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sotto listens only while you hold (or double-tap) your shortcut, and everything is transcribed on this Mac.")
                .foregroundColor(.secondary)
            switch micStatus {
            case .authorized:
                statusLabel("Microphone allowed", ok: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Say something: the bar should move.")
                        .font(.callout)
                    ProgressView(value: Double(level.level))
                        .progressViewStyle(.linear)
                        .tint(level.level > 0.15 ? .green : .accentColor)
                    if level.sawSilenceOnly {
                        Text("Not hearing anything? Pick your microphone in Settings › Transcription › Microphone, or check System Settings › Sound › Input.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            case .notDetermined:
                Button("Allow Microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            if granted { level.start() }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            default:
                statusLabel("Microphone access is off", ok: false)
                Button("Open Microphone Settings") { openSettings("Privacy_Microphone") }
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility lets Sotto paste into the app you're using, read the text around your cursor, and use keys like Fn. Without it, transcripts are only copied.")
                .foregroundColor(.secondary)
            if accessibilityGranted {
                statusLabel("Accessibility allowed", ok: true)
            } else {
                statusLabel("Not allowed yet", ok: false)
                Button("Open Accessibility Settings") {
                    // Adds Sotto to the list so it only needs switching on.
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    openSettings("Privacy_Accessibility")
                }
                .buttonStyle(.borderedProminent)
                Text("Switch on Sotto in the list. This page updates by itself.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Press your dictation shortcut now.")
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(AppSettings.shared.hotkeyDisplayName.split(separator: " ").enumerated()), id: \.offset) { _, key in
                    Text(String(key))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(shortcutPressed ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundColor(shortcutPressed ? .white : .primary)
                        .animation(.easeOut(duration: 0.2), value: shortcutPressed)
                }
            }
            if shortcutPressed {
                statusLabel("That's it! Hold to talk, or double-tap for hands-free.", ok: true)
            }
            Text("You can change it, or use Fn / right ⌥ on its own, in Settings › General.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click in the box, hold your shortcut, and say “Hello from Sotto”. Release to paste.")
                .foregroundColor(.secondary)
            TextEditor(text: $practiceText)
                .font(.body)
                .frame(height: 80)
                .focused($practiceFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if practiceSucceeded {
                statusLabel("Your first dictation worked 🎉", ok: true)
            }
        }
        .onAppear {
            historyCountAtPractice = history.entries.count
            practiceFocused = true
        }
    }

    private var screenRecordingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional. Screen Context reads the text on screen to spell names and terms better during AI cleanup. It needs Screen Recording permission, and nothing leaves your Mac.")
                .foregroundColor(.secondary)
            HStack {
                Button("Turn On Screen Context") {
                    AppSettings.shared.enableScreenContext = true
                    _ = ScreenCaptureService.requestScreenRecordingAccessIfNeeded()
                }
                Button("Not Now") { finish() }
            }
            Text("Switching from superwhisper or Wispr Flow? Import your vocabulary from the Vocabulary tab.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var modelProgress: some View {
        switch model.phase {
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.progress)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .loading, .verifying:
            HStack {
                ProgressView().controlSize(.small)
                Text(model.statusMessage).font(.caption).foregroundColor(.secondary)
            }
        case .notInstalled:
            Text("Download your selected engine in Settings → Transcription before practicing.")
                .font(.caption).foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: Helpers

    private func statusLabel(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundColor(ok ? .green : .orange)
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
        if next == .microphone { level.start() } else { level.stop() }
    }

    private func finish() {
        level.stop()
        AppSettings.shared.hasCompletedOnboarding = true
        onFinish()
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Live input level for the setup check; runs only while that step is visible.
@Observable
final class MicLevelMonitor {
    private(set) var level: Float = 0
    /// Several seconds with no sound: the fix-it hint shows.
    private(set) var sawSilenceOnly = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var peak: Float = 0

    func start() {
        guard ProcessInfo.processInfo.environment["SOTTO_TESTING"] != "1" else { return }
        guard engine == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let engine = AVAudioEngine()
        AudioInputDevices.select(uid: AppSettings.shared.inputDeviceUID, on: engine)
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let normalized = max(0, min(1, (20 * log10(max(rms, 0.0001)) + 60) / 60))
            DispatchQueue.main.async {
                guard let self else { return }
                self.level = normalized
                self.peak = max(self.peak, normalized)
                self.sawSilenceOnly = Date().timeIntervalSince(self.startedAt) > 5 && self.peak < 0.2
            }
        }
        do {
            startedAt = Date()
            peak = 0
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }
}
