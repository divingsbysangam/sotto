import SwiftUI

// MARK: - Help Tab

struct HelpTab: View {
    var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
        List {
            Section {
                HelpItemRow(
                    icon: "play.circle",
                    title: "Getting Started",
                    subtitle: "Learn the basics of Sotto"
                ) {
                    GettingStartedView(onRunSetup: { appState.showOnboarding = true })
                }

                HelpItemRow(
                    icon: "command",
                    title: "Keyboard Shortcuts",
                    subtitle: "Quick reference for all shortcuts"
                ) {
                    KeyboardShortcutsHelpView()
                }
            }

            Section {
                HelpItemRow(
                    icon: "info.circle",
                    title: "About Sotto",
                    subtitle: "Version and credits"
                ) {
                    AboutView()
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Help")
        }
    }
}

struct HelpItemRow<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Getting Started View

struct GettingStartedView: View {
    var onRunSetup: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Sotto")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Voice to text, simplified. Here's how to get started:")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    GettingStartedStep(
                        number: 1,
                        title: "Set Up Permissions",
                        description: "Grant microphone access when prompted. For auto-paste, enable Accessibility in System Settings."
                    )

                    GettingStartedStep(
                        number: 2,
                        title: "Let the Model Load",
                        description: "Whisper Turbo downloads once (about 1.6 GB), then works offline. Optional English engines download only when requested. Check readiness in Settings → Transcription."
                    )

                    GettingStartedStep(
                        number: 3,
                        title: "Start Dictating",
                        description: "Hold \(AppSettings.shared.hotkeyDisplayName) and speak, then release. Double-tap for hands-free dictation and tap once to stop."
                    )

                    GettingStartedStep(
                        number: 4,
                        title: "Customize App Modes",
                        description: "Set up app-specific modes to get formatted output tailored to different applications like email, code, or chat."
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tips")
                        .font(.headline)

                    BulletPoint(text: "Press ESC to cancel a recording without transcribing")
                    BulletPoint(text: "Drop audio or video files on the window to transcribe them into Transcripts")
                    BulletPoint(text: "Select text and hold the Command Mode shortcut to edit it by voice")
                    BulletPoint(text: "Add custom vocabulary for technical terms and names")
                    BulletPoint(text: "Enable AI Enhancement for cleaner output")
                }
            }
            .padding(20)
        }
        .navigationTitle("Getting Started")
        .toolbar {
            if let onRunSetup {
                Button("Run Setup Again", action: onRunSetup)
            }
        }
    }
}

struct GettingStartedStep: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct BulletPoint: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.accentColor)
            Text(text)
                .font(.body)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Keyboard Shortcuts Help View

struct KeyboardShortcutsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard Shortcuts")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Quick reference for all keyboard shortcuts")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    ShortcutGroup(title: "Recording") {
                        ShortcutRow(keys: "Hold", description: "Push-to-talk: hold your shortcut, release to stop")
                        ShortcutRow(keys: "Double-tap", description: "Hands-free: keeps recording after you let go")
                        ShortcutRow(keys: "Hold + Space", description: "Switch to hands-free mid-hold (not with a Space shortcut)")
                        ShortcutRow(keys: "Tap", description: "Stop hands-free recording")
                        ShortcutRow(keys: "ESC", description: "Cancel recording")
                        if let button = AppSettings.shared.dictationMouseButton {
                            ShortcutRow(keys: AppSettings.mouseButtonName(button), description: "Click: hands-free (click again to stop) · Hold: push-to-talk")
                        }
                        ShortcutRow(keys: AppSettings.shared.modeCycleKey.map { "Tap \($0.displayName)" } ?? "Mode key (off)", description: "While recording: switch the mode for this dictation")
                    }

                    ShortcutGroup(title: "Command Mode") {
                        ShortcutRow(keys: AppSettings.shared.commandDisplayName, description: "Hold with text selected, say an edit, release (needs Apple Intelligence)")
                    }

                    ShortcutGroup(title: "Last Transcript") {
                        ShortcutRow(keys: AppSettings.shared.pasteLastDisplayName, description: "Paste last transcript (clipboard is restored)")
                        ShortcutRow(keys: AppSettings.shared.copyLastDisplayName, description: "Copy last transcript")
                        ShortcutRow(keys: AppSettings.shared.readLastDisplayName, description: "Read last transcript aloud (press again to stop)")
                    }

                    ShortcutGroup(title: "Scratchpad") {
                        ShortcutRow(keys: AppSettings.shared.scratchpadDisplayName, description: "Open the Scratchpad and dictate into a note (press again to stop)")
                    }

                    Text("Your shortcut is \(AppSettings.shared.hotkeyDisplayName) (change it in Settings > General). A quick single tap, or anything under 0.4 s, is ignored.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Keyboard Shortcuts")
    }
}

struct ShortcutGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .sottoSurface()
    }
}

struct ShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(SottoDesign.accent)

            VStack(spacing: 8) {
                Text("Sotto")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Voice to Text, Simplified")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                Text("Sotto transcribes and cleans up speech on this Mac. Whisper Turbo is the default; optional Parakeet and Cohere engines handle English. Send your words to the clipboard, the active app, or Scratchpad. No account or cloud inference is required.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 400)
            }

            Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                Label("WhisperKit on GitHub", systemImage: "cpu")
            }
            .font(.callout)

            Text("Parakeet TDT 0.6B v3 © NVIDIA, CC BY 4.0, converted to Core ML by FluidInference.")
                .font(.caption)
                .foregroundColor(.secondary)

            Link("Third-party notices", destination: URL(string: "https://github.com/divingsbysangam/sotto/blob/main/THIRD_PARTY_NOTICES.md")!)
                .font(.callout)

            Spacer()

            Text("Made with SwiftUI")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .navigationTitle("About")
    }
}
