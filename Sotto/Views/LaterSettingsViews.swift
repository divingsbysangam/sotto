import SwiftUI
import AppKit
import AVFoundation

// Settings blocks for the Later-section features. Each block loads its own values on appear and
// writes straight back to AppSettings, so the big settings sections only embed them.

// MARK: - L16 Caret dot per app

/// Apps where the pulsing caret dot is hidden. The capsule still shows.
struct CaretDotHiddenAppsEditor: View {
    var settings: AppSettings

    @State private var apps: [String] = []
    @State private var showingPicker = false

    /// Terminals report the caret unreliably; offered as a one-click suggestion when installed.
    private static let suggested = ["Terminal", "iTerm"]

    private var installedSuggestions: [String] {
        let installed = Set(InstalledAppsManager.shared.installedApps.map(\.name))
        return Self.suggested.filter { installed.contains($0) && !apps.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hide the cursor dot in")
                    .font(.subheadline)
                Spacer()
                Button {
                    showingPicker = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            if apps.isEmpty {
                Text("No apps. The dot shows everywhere the caret can be found.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(apps, id: \.self) { app in
                        ChipView(text: app) {
                            apps.removeAll { $0 == app }
                        }
                    }
                }
            }

            if !installedSuggestions.isEmpty {
                Button("Add \(installedSuggestions.joined(separator: " & "))") {
                    apps.append(contentsOf: installedSuggestions)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Text("Use this where the dot lands in the wrong place, such as terminals or full-screen games. The capsule still shows.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { apps = settings.caretDotHiddenApps }
        .onChange(of: apps) { _, new in settings.caretDotHiddenApps = new }
        .sheet(isPresented: $showingPicker) {
            AppPickerSheet(selectedApps: $apps)
        }
    }
}

// MARK: - L13 Read aloud

struct ReadAloudSettings: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var voiceID: String = ""
    @State private var rate: Double = 1
    @State private var keyCode = AppSettings.defaultReadLastKeyCode
    @State private var modifiers = AppSettings.defaultTranscriptActionModifiers
    @State private var voices = SpeechService.voicesByLanguage()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Read Aloud")
                    .font(.headline)

                Text("Listen back to proofread by ear. Uses your Mac's built-in voices; nothing leaves this Mac. Also in the menu bar and a transcript's right-click menu.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Read last transcript (press again to stop)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                ShortcutRecorderView(
                    keyCode: $keyCode,
                    modifiers: $modifiers,
                    defaultKeyCode: AppSettings.defaultReadLastKeyCode,
                    defaultModifiers: AppSettings.defaultTranscriptActionModifiers,
                    onShortcutChanged: {
                        settings.readLastKeyCode = keyCode
                        settings.readLastModifiers = modifiers
                        onSave?()
                    }
                )

                Picker("Voice", selection: $voiceID) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.language) { group in
                        Section(group.language) {
                            ForEach(group.voices, id: \.identifier) { voice in
                                Text(Self.label(for: voice)).tag(voice.identifier)
                            }
                        }
                    }
                }
                .frame(maxWidth: 360)

                HStack {
                    Text("Speed")
                    Slider(value: $rate, in: 0.5...2, step: 0.1)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.1f×", rate))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 36, alignment: .leading)
                    Button(SpeechService.shared.isSpeaking ? "Stop" : "Preview") {
                        if SpeechService.shared.isSpeaking {
                            SpeechService.shared.stop()
                        } else {
                            SpeechService.shared.speak("This is how your transcripts will sound.")
                        }
                    }
                }
            }
        }
        .onAppear {
            voiceID = settings.readAloudVoiceID ?? ""
            rate = settings.readAloudRate
            keyCode = settings.readLastKeyCode
            modifiers = settings.readLastModifiers
        }
        .onChange(of: voiceID) { _, id in settings.readAloudVoiceID = id.isEmpty ? nil : id }
        .onChange(of: rate) { _, value in settings.readAloudRate = value }
    }

    private static func label(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }
}

// MARK: - L12 Mouse button

/// An extra dictation trigger on a mouse button, alongside the keyboard shortcut.
struct MouseButtonShortcutPicker: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var button: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mouse button", selection: $button) {
                Text("Off").tag(Int?.none)
                ForEach(AppSettings.mouseButtonChoices, id: \.number) { choice in
                    Text(choice.name).tag(Int?.some(choice.number))
                }
            }
            .frame(maxWidth: 360)
            Text("Click to start hands-free and click again to stop, or hold to talk and release. The button's own action is turned off in other apps while it dictates.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { button = settings.dictationMouseButton }
        .onChange(of: button) { _, new in
            settings.dictationMouseButton = new
            onSave?()
        }
    }
}

// MARK: - L15 Voice vs keyboard

struct TypingCounterSettings: View {
    var settings: AppSettings

    @State private var enabled = false
    @State private var hasPermission = TypingCounterService.hasPermission

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Voice vs Keyboard")
                    .font(.headline)

                Toggle("Compare dictation with typing on the Dashboard", isOn: $enabled)
                Text("Counts how many characters you type each day and how long typing takes: two numbers per day, kept on this Mac for 90 days. Never what you type, which keys, or in which app. Needs Input Monitoring.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if enabled && !hasPermission {
                    HStack {
                        Text("⚠︎ Input Monitoring is off for Sotto.")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }

                if enabled {
                    Button("Delete Typing Counts") { TypingCounterService.shared.reset() }
                        .font(.caption)
                }
            }
        }
        .onAppear { enabled = settings.countTypingEnabled }
        .onChange(of: enabled) { _, on in
            settings.countTypingEnabled = on
            if on && !TypingCounterService.hasPermission {
                TypingCounterService.requestPermission()
            }
            TypingCounterService.shared.sync()
        }
        .task {
            // Starts counting as soon as Input Monitoring is granted.
            while !Task.isCancelled {
                let granted = TypingCounterService.hasPermission
                if granted != hasPermission {
                    hasPermission = granted
                    TypingCounterService.shared.sync()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - L14 Command-line tool

struct CommandLineToolSettings: View {
    @State private var link = CommandLineToolInstaller.installedLink
    @State private var errorMessage: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Command-Line Tool")
                    .font(.headline)

                Text("`sotto history last` and `sotto history search <words>` print your transcripts in Terminal (add `--json` for scripts and agents). Read-only and local: no server, nothing is written.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let link {
                    HStack {
                        Text("Installed at \(link.path)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Uninstall") {
                            CommandLineToolInstaller.uninstall()
                            self.link = CommandLineToolInstaller.installedLink
                        }
                    }
                    if !CommandLineToolInstaller.isOnPath(link.deletingLastPathComponent()) {
                        Text("Add it to your PATH: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                            .textSelection(.enabled)
                    }
                } else {
                    Button("Install `sotto` Command") {
                        do {
                            link = try CommandLineToolInstaller.install()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }

                if let errorMessage {
                    Text("⚠︎ \(errorMessage)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - L7 Scratchpad

struct ScratchpadSettings: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var keyCode = AppSettings.defaultScratchpadKeyCode
    @State private var modifiers = AppSettings.defaultScratchpadModifiers

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Scratchpad")
                        .font(.headline)
                    Spacer()
                    Button("Open Scratchpad") { ScratchpadWindowController.shared.show() }
                }

                Text("Think out loud without a target app: dictation goes into a local note you can edit, pin, and search. This shortcut opens it and starts dictating; press again to stop. Your dictation shortcut also writes into the Scratchpad while its window is in front.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ShortcutRecorderView(
                    keyCode: $keyCode,
                    modifiers: $modifiers,
                    defaultKeyCode: AppSettings.defaultScratchpadKeyCode,
                    defaultModifiers: AppSettings.defaultScratchpadModifiers,
                    onShortcutChanged: {
                        settings.scratchpadKeyCode = keyCode
                        settings.scratchpadModifiers = modifiers
                        onSave?()
                    }
                )
            }
        }
        .onAppear {
            keyCode = settings.scratchpadKeyCode
            modifiers = settings.scratchpadModifiers
        }
    }
}

// MARK: - L2 Learn from corrections

struct LearnFromCorrectionsSettings: View {
    var settings: AppSettings

    @State private var enabled = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Learn from my corrections", isOn: $enabled)
                Text("For 30 seconds after a paste, Sotto notices if you fix a word by hand and offers to add it to Vocabulary (or a phrase to Replacements). It reads only the text right around the paste in the same field, stops when you switch fields or apps, and never saves or logs that text. Needs Accessibility.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled && !settings.ignoredCorrections.isEmpty {
                    Button("Forget Dismissed Suggestions (\(settings.ignoredCorrections.count))") {
                        settings.ignoredCorrections = []
                    }
                    .font(.caption)
                }
            }
        }
        .onAppear { enabled = settings.learnFromCorrections }
        .onChange(of: enabled) { _, on in
            settings.learnFromCorrections = on
            if !on { CorrectionWatcher.shared.stop() }
        }
    }
}

// MARK: - L11 File names in code editors

struct FileNameSettings: View {
    var settings: AppSettings

    @State private var enabled = true
    @State private var refreshed = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Write file names exactly in code editors", isOn: $enabled)
                Text("In Xcode, VS Code, Cursor, and Windsurf, say “app state dot swift” or “main window view” and Sotto writes AppState.swift or MainWindowView, using the file names of the project that's open. Only file names are read, on this Mac; the list refreshes every 10 minutes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled {
                    Button(refreshed ? "File Lists Cleared" : "Refresh File Lists") {
                        WorkspaceIndexService.shared.refresh()
                        refreshed = true
                    }
                    .font(.caption)
                    .disabled(refreshed)
                }
            }
        }
        .onAppear { enabled = settings.resolveFileNamesInEditors }
        .onChange(of: enabled) { _, on in
            settings.resolveFileNamesInEditors = on
            if !on { WorkspaceIndexService.shared.refresh() }
        }
    }
}

// MARK: - L1 Live text

struct LiveTextSettings: View {
    var settings: AppSettings
    var languageMode: DictationLanguageMode

    @State private var enabled = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show live text while speaking", isOn: $enabled)
                    .disabled(SpeechEngineID.effective(selected: TranscriptionEngineManager.shared.selectedID, languageMode: languageMode) != .whisper)
                if SpeechEngineID.effective(selected: TranscriptionEngineManager.shared.selectedID, languageMode: languageMode) != .whisper {
                    Text("Live text is available with Whisper Turbo. Your preference is retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The capsule shows the words heard so far, updated every 1.5 seconds. The pasted text still comes from a full pass over the whole recording once you stop. Uses the same model (no extra memory); on some Macs the paste can be a fraction of a second later. Needs the Minimal recording indicator.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { enabled = settings.liveTextEnabled }
        .onChange(of: enabled) { _, on in settings.liveTextEnabled = on }
    }
}

// MARK: - L5 Local cleanup model

struct LocalLLMSettings: View {
    var settings: AppSettings

    @State private var enabled = true
    private var service: LocalLLMService { .shared }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: LocalLLMService.totalBytes, countStyle: .file)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local Cleanup Model")
                    .font(.headline)

                Text(LLMService.foundationModelsAvailable && !LLMService.forceLocalLLM
                     ? "Apple Intelligence is cleaning up your dictations. This optional model is only used on Macs without it, or if Apple Intelligence can't handle a dictation."
                     : "Apple Intelligence isn't available on this Mac, so cleanup uses a built-in rule-based cleaner. This optional model cleans up grammar and fillers much better, entirely on this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch service.state {
                case .notInstalled:
                    HStack {
                        Text("\(LocalLLMService.displayName) · \(sizeText)")
                            .font(.caption)
                        Spacer()
                        Button("Download") { service.download() }
                    }
                case .downloading(let fraction):
                    HStack {
                        ProgressView(value: fraction)
                        Text("\(Int(fraction * 100))%")
                            .font(.system(.caption, design: .monospaced))
                        Button("Cancel") { service.cancelDownload() }
                    }
                case .installed:
                    Toggle("Use it for cleanup when Apple Intelligence isn't available", isOn: $enabled)
                    HStack {
                        Text(installedLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Remove") { service.remove() }
                    }
                case .failed(let message):
                    HStack {
                        Text("⚠︎ \(message)")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Try Again") { service.download() }
                    }
                }

                Text("Runs next to the Whisper model and adds about 1 GB of memory while loaded; it unloads after 10 minutes without use. Prompt mode and Command mode still need Apple Intelligence.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { enabled = settings.localLLMEnabled }
        .onChange(of: enabled) { _, on in
            settings.localLLMEnabled = on
            if !on { service.unload() }
        }
    }

    private var installedLine: String {
        var parts = ["\(LocalLLMService.displayName) · \(sizeText) on disk"]
        if let memory = service.measuredMemoryMB {
            parts.append(String(format: "%.0f MB in memory%@", memory, service.isLoaded ? "" : " when loaded"))
        } else {
            parts.append("not loaded yet")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - L6 Coding agent relay

struct AgentRelaySettings: View {
    var settings: AppSettings

    @State private var enabled = false
    @State private var timeout: TimeInterval = AgentRelay.defaultReplyTimeout
    @State private var message: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Coding Agent Relay (Beta)")
                    .font(.headline)

                Toggle("Reply to Claude Code and Cursor by voice", isOn: $enabled)
                Text("When an agent finishes, the capsule offers Reply: dictate your follow-up and the agent continues with it. When an agent needs attention (like a permission prompt), Sotto only notifies you; permissions are always answered in the terminal, and Sotto never changes them. Everything stays on this Mac. Turning this off stops all hooks at once.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if enabled {
                    Picker("Wait for a reply", selection: $timeout) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("2 minutes").tag(TimeInterval(120))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                    .frame(maxWidth: 320)

                    HStack {
                        Button("Add to Claude Code") {
                            install(AgentRelayService.claudeHooks(timeout: timeout), into: AgentRelayService.claudeSettingsURL, cursor: false)
                        }
                        Button("Copy Claude Code Config") {
                            copy(AgentRelayService.snippet(AgentRelayService.claudeHooks(timeout: timeout), cursor: false))
                        }
                    }
                    HStack {
                        Button("Add to Cursor") {
                            install(AgentRelayService.cursorHooks(), into: AgentRelayService.cursorHooksURL, cursor: true)
                        }
                        Button("Copy Cursor Config") {
                            copy(AgentRelayService.snippet(AgentRelayService.cursorHooks(), cursor: true))
                        }
                    }
                    Text("“Add” adds only Sotto's Stop/Notification hooks to ~/.claude/settings.json or ~/.cursor/hooks.json (a backup is saved next to it) and keeps everything else. Sotto must stay in /Applications for the hooks to find it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(message.hasPrefix("⚠︎") ? .orange : .secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            enabled = settings.agentRelayEnabled
            timeout = settings.agentRelayTimeout
        }
        .onChange(of: enabled) { _, on in
            settings.agentRelayEnabled = on
            AgentRelayService.shared.sync()
        }
        .onChange(of: timeout) { _, value in
            settings.agentRelayTimeout = value
            AgentRelayService.shared.sync()
        }
    }

    private func install(_ hooks: [String: Any], into url: URL, cursor: Bool) {
        do {
            let backup = try AgentRelayService.install(hooks, into: url, cursor: cursor)
            message = "✓ Added to \(url.path)" + (backup.map { " (backup: \($0.lastPathComponent))" } ?? "")
        } catch {
            message = "⚠︎ \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied. Paste it into the agent's settings file."
    }
}
