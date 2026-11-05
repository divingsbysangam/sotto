import AppKit
import SwiftUI

// MARK: - Help Tab

struct HelpTab: View {
    var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SottoDesign.spacing / 2) {
                    SottoPageHeader(title: "Help", subtitle: "Guides and info") {}

                    VStack(spacing: 0) {
                        HelpItemRow(
                            icon: "play.circle",
                            title: "Getting Started",
                            subtitle: "Set up permissions, pick a microphone, and make your first dictation"
                        ) {
                            GettingStartedView(onRunSetup: { appState.showOnboarding = true })
                        }

                        Divider()

                        HelpItemRow(
                            icon: "keyboard",
                            title: "Keyboard Shortcuts",
                            subtitle: "Dictate, use hands-free mode, and control your last transcript"
                        ) {
                            KeyboardShortcutsHelpView()
                        }

                        Divider()

                        HelpItemRow(
                            icon: "info.circle",
                            title: "About Sotto",
                            subtitle: "Version, privacy, and acknowledgements"
                        ) {
                            AboutView()
                        }
                    }
                    .sottoSurface()

                    HStack(spacing: SottoDesign.spacing) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 56, height: 56)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: SottoDesign.spacing / 4) {
                            Text("Sotto")
                                .font(.headline)
                                .foregroundStyle(SottoDesign.cream)
                            Text("Version \(Self.version) · Private, on-device dictation")
                                .font(.caption)
                                .foregroundStyle(SottoDesign.cream.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                    }
                    .sottoSurface()
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(SottoDesign.spacing)
            }
            .background(SottoDesign.charcoal)
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

private struct HelpIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(SottoDesign.accent)
            .frame(width: 36, height: 36)
            .background(SottoDesign.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
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
            HStack(spacing: SottoDesign.spacing / 2) {
                HelpIcon(symbol: icon)

                VStack(alignment: .leading, spacing: SottoDesign.spacing / 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SottoDesign.cream)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SottoDesign.cream.opacity(0.6))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SottoDesign.cream.opacity(0.5))
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        ScrollView {
            VStack(alignment: .leading, spacing: SottoDesign.spacing) {
                HStack(spacing: SottoDesign.spacing) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SottoDesign.spacing / 4) {
                        Text("Sotto")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(SottoDesign.cream)
                        Text("Voice to Text, Simplified")
                            .font(.title3)
                            .foregroundStyle(SottoDesign.cream.opacity(0.7))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                            .font(.caption)
                            .foregroundStyle(SottoDesign.cream.opacity(0.6))
                    }
                }
                .sottoSurface()

                VStack(alignment: .leading, spacing: SottoDesign.spacing) {
                    Text("Private by design")
                        .font(.headline)
                        .foregroundStyle(SottoDesign.cream)
                    Text("Sotto transcribes and cleans up speech on this Mac with Whisper Turbo. Send your words to the clipboard, the active app, or Scratchpad. No account or cloud inference is required.")
                        .foregroundStyle(SottoDesign.cream.opacity(0.7))
                    Divider()
                    Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                        Label("WhisperKit on GitHub", systemImage: "cpu")
                    }
                    Link("Third-party notices", destination: URL(string: "https://github.com/divingsbysangam/sotto/blob/main/THIRD_PARTY_NOTICES.md")!)
                    Text("Made with SwiftUI")
                        .font(.caption)
                        .foregroundStyle(SottoDesign.cream.opacity(0.6))
                }
                .sottoSurface()
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(SottoDesign.spacing)
        }
        .background(SottoDesign.charcoal)
        .navigationTitle("About")
    }
}
