import SwiftUI
import Sparkle

struct MenuBarView: View {
    @Bindable var appState: AppState
    var onOpenSettings: () -> Void
    var onOpenHistory: () -> Void
    var onNavigate: (SottoRoute) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            contents.fixedSize(horizontal: false, vertical: true)
            ScrollView { contents }.frame(height: maximumHeight)
        }
        .frame(width: 320)
        .frame(maxHeight: maximumHeight)
        .tint(SottoDesign.accent)
    }

    private var maximumHeight: CGFloat { min(760, (NSScreen.main?.visibleFrame.height ?? 840) - 80) }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status indicator
            LiveDictationStatusView(appState: appState, onNavigate: { route in
                NSApp.keyWindow?.close()
                onNavigate(route)
            })
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()

            // Recording button
            Button(action: { appState.toggleRecording() }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .foregroundColor(appState.isRecording ? .red : .primary)
                    Text(appState.isRecording ? "Stop Recording" : "Start Recording")
                    Spacer()
                    Text(AppSettings.shared.hotkeyDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isProcessing)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // Audio level indicator (when recording)
            if appState.isRecording {
                MenuAudioMeter(appState: appState).padding(.horizontal, 12)
            }

            Divider()

            // Last transcription preview
            if let lastText = appState.lastTranscription {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last transcript:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(lastText.prefix(100) + (lastText.count > 100 ? "..." : ""))
                        .font(.caption)
                        .lineLimit(3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                Divider()
            }

            // Recover a missed or wrong-app paste without retyping (greyed out until there's history)
            let hasTranscript = appState.lastSavedTranscript != nil

            Button(action: {
                // Close this menu first so the paste lands in the app the user was in.
                NSApp.keyWindow?.close()
                appState.pasteLastTranscript(fromMenu: true)
            }) {
                HStack {
                    Image(systemName: "doc.on.clipboard")
                    Text("Paste Last Transcript")
                    Spacer()
                    Text(AppSettings.shared.pasteLastDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!hasTranscript)
            .opacity(hasTranscript ? 1 : 0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button(action: { appState.copyLastTranscript() }) {
                HStack {
                    Image(systemName: "doc.on.doc")
                    Text("Copy Last Transcript")
                    Spacer()
                    Text(AppSettings.shared.copyLastDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!hasTranscript)
            .opacity(hasTranscript ? 1 : 0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // L7: dictate into a local note instead of an app.
            Button(action: {
                NSApp.keyWindow?.close()
                appState.openScratchpad()
            }) {
                HStack {
                    Image(systemName: "note.text")
                    Text("Scratchpad")
                    Spacer()
                    Text(AppSettings.shared.scratchpadDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // L13: listen back to proofread by ear; the same item stops reading.
            let isSpeaking = SpeechService.shared.isSpeaking
            let canRead = isSpeaking || appState.lastReadableTranscript != nil
            Button(action: { appState.readLastTranscript() }) {
                HStack {
                    Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2")
                    Text(isSpeaking ? "Stop Reading" : "Read Last Transcript Aloud")
                    Spacer()
                    Text(AppSettings.shared.readLastDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(!canRead)
            .opacity(canRead ? 1 : 0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Open Sotto (main window)
            Button(action: {
                NSApp.keyWindow?.close()
                onOpenHistory()
            }) {
                Label("Transcripts", systemImage: SottoSymbol.transcripts.rawValue)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button(action: { onOpenSettings() }) {
                HStack {
                    Image(systemName: "macwindow")
                    Text("Open Sotto")
                    Spacer()
                    Text("⌘,")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Check for Updates
            Button(action: {
                WindowManager.shared.updaterController.checkForUpdates(nil)
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Check for Updates...")
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Quit
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
        .tint(SottoDesign.accent)
    }

}

/// Audio updates stay local and never trigger readiness announcements.
private struct MenuAudioMeter: View {
    let appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<20, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < Int(appState.audioLevel * 20) ? SottoDesign.accent : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 12)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: SottoDesign.feedbackDuration), value: appState.audioLevel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
    }
}
