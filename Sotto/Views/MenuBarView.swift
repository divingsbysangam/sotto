import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    var onOpenSettings: () -> Void
    var onOpenHistory: () -> Void
    var onNavigate: (SottoRoute) -> Void

    var body: some View {
        contents
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing) {
            LiveDictationStatusView(appState: appState, onNavigate: { route in
                NSApp.keyWindow?.close()
                onNavigate(route)
            }, compact: true)

            Divider()

            VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
                recordingControl

                if appState.isRecording {
                    MenuAudioMeter(appState: appState)
                }

                if let entry = appState.lastSavedTranscriptEntry {
                    transcriptPreview(entry)
                }

                menuAction("Paste Last Transcript", symbol: .paste,
                           shortcut: AppSettings.shared.pasteLastDisplayName,
                           enabled: appState.lastSavedTranscriptEntry != nil) {
                    NSApp.keyWindow?.close()
                    appState.pasteLastTranscript(fromMenu: true)
                }
                menuAction("Copy Last Transcript", symbol: .copy,
                           shortcut: AppSettings.shared.copyLastDisplayName,
                           enabled: appState.lastSavedTranscriptEntry != nil) {
                    appState.copyLastTranscript()
                }
                menuAction("Scratchpad", symbol: .scratchpad,
                           shortcut: AppSettings.shared.scratchpadDisplayName) {
                    NSApp.keyWindow?.close()
                    appState.openScratchpad()
                }
                let isSpeaking = SpeechService.shared.isSpeaking
                menuAction(isSpeaking ? "Stop Reading" : "Read Last Transcript Aloud",
                           symbol: isSpeaking ? .stop : .read,
                           shortcut: AppSettings.shared.readLastDisplayName,
                           enabled: isSpeaking || appState.lastReadableTranscript != nil) {
                    appState.readLastTranscript()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
                menuAction("Transcripts", symbol: .transcripts) {
                    NSApp.keyWindow?.close()
                    onOpenHistory()
                }
                menuAction("Open Sotto", symbol: .openApp, shortcut: "⌘,") {
                    onOpenSettings()
                }
                menuAction("Check for Updates…", symbol: .updates) {
                    WindowManager.shared.updaterController.checkForUpdates(nil)
                }
                menuAction("Quit", symbol: .quit, shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(SottoDesign.spacing)
        .frame(width: 320)
    }

    @ViewBuilder private var recordingControl: some View {
        if appState.isRecording {
            menuAction("Stop Recording", symbol: .stop,
                       shortcut: AppSettings.shared.hotkeyDisplayName) {
                appState.toggleRecording()
            }
        } else {
            Button(action: { appState.toggleRecording() }) {
                actionLabel("Start Recording", symbol: .record,
                            shortcut: AppSettings.shared.hotkeyDisplayName)
            }
            .sottoPrimaryAction()
            .tint(SottoDesign.accent)
            .disabled(appState.isProcessing)
        }
    }

    private func transcriptPreview(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
            Text("Last transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(entry.sourceApp ?? "Sotto") · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .sottoSurface()
    }

    private func menuAction(_ title: String, symbol: SottoSymbol, shortcut: String? = nil,
                            enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, symbol: symbol, shortcut: shortcut)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func actionLabel(_ title: String, symbol: SottoSymbol, shortcut: String?) -> some View {
        HStack(spacing: SottoDesign.spacing / 2) {
            Image(systemName: symbol.rawValue)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: SottoDesign.spacing)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 0)
            if let shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SottoDesign.spacing / 4)
        .contentShape(Rectangle())
    }
}

/// Audio updates stay local and never trigger readiness announcements.
private struct MenuAudioMeter: View {
    let appState: AppState

    var body: some View {
        HStack(spacing: SottoDesign.spacing / 8) {
            ForEach(0..<20, id: \.self) { index in
                RoundedRectangle(cornerRadius: SottoDesign.spacing / 8)
                    .fill(index < Int(appState.audioLevel * 20) ? SottoDesign.accent : Color.secondary.opacity(0.3))
                    .frame(width: SottoDesign.spacing / 2, height: SottoDesign.spacing * 0.75)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
    }
}
