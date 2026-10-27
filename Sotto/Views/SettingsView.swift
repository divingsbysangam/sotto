import SwiftUI
import Sparkle
import ServiceManagement

// MARK: - Settings Tab with Sub-Navigation

struct SettingsTab: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @Binding var selectedSection: SettingsSection

    var body: some View {
        VStack(spacing: 0) {
            AccessibilityBanner()

            // Section picker
            Picker("Settings section", selection: $selectedSection) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Section content
            ScrollView {
                switch selectedSection {
                case .general:
                    GeneralSettingsSection(settings: settings, onSave: onSave)
                case .transcription:
                    TranscriptionSettingsSection(settings: settings, onSave: onSave)
                case .system:
                    SystemSettingsSection(settings: settings, onSave: onSave)
                }
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Accessibility Banner

/// Shown at the top of Settings until Accessibility is granted. Replaces the old modal alert
/// that interrupted every dictation. Rechecks every second so it disappears once granted.
struct AccessibilityBanner: View {
    @State private var isTrusted = AXIsProcessTrusted()

    var body: some View {
        // A container (not Group) so the polling task runs even while the banner is hidden.
        VStack(spacing: 0) {
            if !isTrusted {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility permission is off")
                            .font(.headline)
                        Text("Sotto copies transcripts to the clipboard instead of pasting them. Accessibility also lets Sotto show the recording dot at your cursor and detect websites for App Modes.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding([.horizontal, .top])
            }
        }
        .task {
            while !Task.isCancelled {
                isTrusted = AXIsProcessTrusted()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - General Settings Section

struct GeneralSettingsSection: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var outputMode: OutputMode = .clipboard
    @State private var enableScreenContext: Bool = false
    @State private var soundEffectsEnabled: Bool = true
    @State private var hotkeyKeyCode: UInt32 = 49
    @State private var hotkeyModifiers: UInt = 0
    @State private var hotkeyModifierKey: ModifierKey?
    @State private var modeCycleKey: ModifierKey? = .rightShift
    @State private var commandModeEnabled = true
    @State private var commandKeyCode = AppSettings.defaultCommandKeyCode
    @State private var commandModifiers = AppSettings.defaultCommandModifiers
    @State private var commandModifierKey: ModifierKey?
    @State private var pasteLastKeyCode = AppSettings.defaultPasteLastKeyCode
    @State private var pasteLastModifiers = AppSettings.defaultTranscriptActionModifiers
    @State private var copyLastKeyCode = AppSettings.defaultCopyLastKeyCode
    @State private var copyLastModifiers = AppSettings.defaultTranscriptActionModifiers
    @State private var recordingUIStyle: RecordingUIStyle = .minimal
    @State private var matchCaretFormatting = true
    @State private var tipsEnabled = true
    @State private var useSelectionAndClipboardContext = true
    @State private var audioRetention: RetentionPeriod = .off
    @State private var transcriptRetention: RetentionPeriod = .forever

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Output Mode")
                        .font(.headline)

                    Picker("", selection: $outputMode) {
                        Text("Copy to Clipboard").tag(OutputMode.clipboard)
                        Text("Auto-paste to Active App").tag(OutputMode.autoPaste)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if outputMode == .autoPaste {
                        Text("Uses Accessibility for automatic paste; clipboard output remains available without it.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Toggle("Match casing & spacing at the cursor", isOn: $matchCaretFormatting)
                        Text("Mid-sentence, the first word is lowercased (names, “I”, and acronyms stay), a space is added where needed, and the final period is dropped when text follows.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording Shortcut")
                        .font(.headline)

                    Text("Hold to talk and release to stop. Double-tap, or press Space while holding, for hands-free; tap again to stop. ESC cancels.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ShortcutRecorderView(
                        keyCode: $hotkeyKeyCode,
                        modifiers: $hotkeyModifiers,
                        modifierKey: $hotkeyModifierKey,
                        onShortcutChanged: { saveSettings() }
                    )

                    Text("Record a key combination, or press and release Fn, right ⌥, or right ⌘ on its own. Left ⌥/⌘ keep working normally.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if hotkeyModifierKey == .fn {
                        Text("On keyboards without Fn, ⌃⌥ (Control + Option) works too.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let action = ModifierKey.fnKeySystemAction {
                            Text("⚠︎ Your 🌐 key is also set to “\(action)” (System Settings › Keyboard › Press 🌐 key to). Set it to “Do Nothing” so both don't fire.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }

                    Divider()

                    MouseButtonShortcutPicker(settings: settings, onSave: onSave)

                    Divider()

                    Picker("Switch mode while recording", selection: $modeCycleKey) {
                        Text("Off").tag(ModifierKey?.none)
                        ForEach(ModifierKey.modeCycleChoices.filter { $0 != hotkeyModifierKey }, id: \.self) { key in
                            Text("Tap \(key.displayName)").tag(ModifierKey?.some(key))
                        }
                    }
                    .frame(maxWidth: 360)
                    Text("The capsule shows the mode a dictation will use. Tap this key while recording to cycle Default → Raw → your modes; it applies to that dictation only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Command Mode")
                        .font(.headline)

                    if LLMService.foundationModelsAvailable {
                        Toggle("Edit selected text by voice", isOn: $commandModeEnabled)
                        Text("Select text in any app, hold this shortcut, say what to change (“make this more formal”, “turn into bullets”), and release. The selection is replaced; your clipboard is restored.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if commandModeEnabled {
                            ShortcutRecorderView(
                                keyCode: $commandKeyCode,
                                modifiers: $commandModifiers,
                                defaultKeyCode: AppSettings.defaultCommandKeyCode,
                                defaultModifiers: AppSettings.defaultCommandModifiers,
                                modifierKey: $commandModifierKey,
                                onShortcutChanged: { saveSettings() }
                            )
                        }
                    } else {
                        Text("Needs Apple Intelligence, which isn't available on this Mac right now.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Last Transcript Shortcuts")
                        .font(.headline)

                    Text("Recover a missed or wrong-app paste. Paste restores your clipboard afterwards; both are also in the menu bar.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Paste last transcript")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ShortcutRecorderView(
                        keyCode: $pasteLastKeyCode,
                        modifiers: $pasteLastModifiers,
                        defaultKeyCode: AppSettings.defaultPasteLastKeyCode,
                        defaultModifiers: AppSettings.defaultTranscriptActionModifiers,
                        onShortcutChanged: { saveSettings() }
                    )

                    Text("Copy last transcript")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ShortcutRecorderView(
                        keyCode: $copyLastKeyCode,
                        modifiers: $copyLastModifiers,
                        defaultKeyCode: AppSettings.defaultCopyLastKeyCode,
                        defaultModifiers: AppSettings.defaultTranscriptActionModifiers,
                        onShortcutChanged: { saveSettings() }
                    )
                }
            }

            ScratchpadSettings(settings: settings, onSave: onSave)

            ReadAloudSettings(settings: settings, onSave: onSave)

            TypingCounterSettings(settings: settings)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Selected & copied text as context", isOn: $useSelectionAndClipboardContext)
                    Text("With AI Enhancement on, text you had selected or copied within 3 seconds of dictating helps cleanup spell names and terms. It is never pasted, saved, or read from password fields. The capsule shows a quote icon when it's used.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Screen Context (OCR)", isOn: $enableScreenContext)
                    Text("Off by default. When on, briefly captures on-screen text to improve cleanup. Leave off unless you need OCR — dictation never touches Screen Recording while this is off.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if enableScreenContext {
                        Text("Requires a one-time Screen Recording grant: System Settings → Privacy & Security → Screen Recording → enable Sotto.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    Divider()

                    Toggle("Enable Sound Effects", isOn: $soundEffectsEnabled)

                    Toggle("Show tips", isOn: $tipsEnabled)
                    Text("A one-time hint in the capsule the first time you use Backtrack, spoken lists, a mode, or paste-last.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recording Indicator Style")
                        .font(.headline)

                    Picker("", selection: $recordingUIStyle) {
                        ForEach(RecordingUIStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text("The bottom capsule stays above the Dock. Dot near writing uses only a small indicator beside the active field, following the caret or pointer. Both stay out of the way of typing; the floating window is optional.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if recordingUIStyle != .floating {
                        Divider()
                        CaretDotHiddenAppsEditor(settings: settings)
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("History & Audio")
                        .font(.headline)

                    Picker("Keep transcripts for", selection: $transcriptRetention) {
                        ForEach(RetentionPeriod.transcriptChoices, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .frame(maxWidth: 320)

                    Picker("Keep audio for", selection: $audioRetention) {
                        ForEach(RetentionPeriod.audioChoices, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                    .frame(maxWidth: 320)

                    Text(retentionFootnote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .onAppear { loadSettings() }
        .onChange(of: outputMode) { saveSettings() }
        .onChange(of: enableScreenContext) { _, enabled in
            saveSettings()
            // Request Screen Recording at most once when the user opts in — never on every dictation.
            if enabled {
                ScreenCaptureService.requestScreenRecordingAccessIfNeeded()
            }
        }
        .onChange(of: soundEffectsEnabled) { saveSettings() }
        .onChange(of: recordingUIStyle) { saveSettings() }
        .onChange(of: audioRetention) { saveSettings() }
        .onChange(of: matchCaretFormatting) { saveSettings() }
        .onChange(of: tipsEnabled) { saveSettings() }
        .onChange(of: modeCycleKey) { saveSettings() }
        .onChange(of: commandModeEnabled) { saveSettings() }
        .onChange(of: useSelectionAndClipboardContext) { saveSettings() }
        .onChange(of: transcriptRetention) { saveSettings() }
    }

    private var retentionFootnote: String {
        let audio = audioRetention == .off
            ? "Audio is deleted right after each dictation."
            : "Audio is saved as M4A on this Mac only and deleted with its transcript."
        return "\(audio) Failed dictations keep their audio until retried or deleted. Anything older than these limits is deleted at launch and after each dictation."
    }

    private func loadSettings() {
        outputMode = settings.outputMode
        enableScreenContext = settings.enableScreenContext
        soundEffectsEnabled = settings.soundEffectsEnabled
        hotkeyKeyCode = settings.hotkeyKeyCode
        hotkeyModifiers = settings.hotkeyModifiers
        hotkeyModifierKey = settings.hotkeyModifierKey
        modeCycleKey = settings.modeCycleKey
        commandModeEnabled = settings.commandModeEnabled
        commandKeyCode = settings.commandKeyCode
        commandModifiers = settings.commandModifiers
        commandModifierKey = settings.commandModifierKey
        pasteLastKeyCode = settings.pasteLastKeyCode
        pasteLastModifiers = settings.pasteLastModifiers
        copyLastKeyCode = settings.copyLastKeyCode
        copyLastModifiers = settings.copyLastModifiers
        recordingUIStyle = settings.recordingUIStyle
        audioRetention = settings.audioRetention
        transcriptRetention = settings.transcriptRetention
        matchCaretFormatting = settings.matchCaretFormatting
        tipsEnabled = settings.tipsEnabled
        useSelectionAndClipboardContext = settings.useSelectionAndClipboardContext
    }

    private func saveSettings() {
        settings.outputMode = outputMode
        settings.enableScreenContext = enableScreenContext
        settings.soundEffectsEnabled = soundEffectsEnabled
        settings.hotkeyKeyCode = hotkeyKeyCode
        settings.hotkeyModifiers = hotkeyModifiers
        settings.hotkeyModifierKey = hotkeyModifierKey
        // The same key can't both dictate and cycle modes.
        if modeCycleKey != nil, modeCycleKey == hotkeyModifierKey { modeCycleKey = nil }
        settings.modeCycleKey = modeCycleKey
        settings.commandModeEnabled = commandModeEnabled
        settings.commandKeyCode = commandKeyCode
        settings.commandModifiers = commandModifiers
        settings.commandModifierKey = commandModifierKey == hotkeyModifierKey ? nil : commandModifierKey
        settings.pasteLastKeyCode = pasteLastKeyCode
        settings.pasteLastModifiers = pasteLastModifiers
        settings.copyLastKeyCode = copyLastKeyCode
        settings.copyLastModifiers = copyLastModifiers
        settings.recordingUIStyle = recordingUIStyle
        settings.audioRetention = audioRetention
        settings.transcriptRetention = transcriptRetention
        settings.matchCaretFormatting = matchCaretFormatting
        settings.tipsEnabled = tipsEnabled
        settings.useSelectionAndClipboardContext = useSelectionAndClipboardContext
        onSave?()
    }
}

// MARK: - Transcription Settings Section

struct TranscriptionSettingsSection: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var enableLLMProcessing: Bool = true
    @State private var voiceCommandsEnabled: Bool = true
    @State private var inputDeviceUID: String?
    @State private var inputDevices: [AudioInputDevices.Device] = []
    @State private var pauseMediaWhileDictating = false
    @State private var languageMode: DictationLanguageMode = .english
    @State private var dictationLanguages: [String] = ["en"]


    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Local, on-device transcription only
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription Mode")
                        .font(.headline)

                    Text("On-device transcription. Fully private — no audio data leaves your Mac.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            modelSettings

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Microphone")
                        .font(.headline)
                    Picker("Record from", selection: $inputDeviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                        if let uid = inputDeviceUID, !inputDevices.contains(where: { $0.uid == uid }) {
                            Text("Not connected (using system default)").tag(String?.some(uid))
                        }
                    }
                    .frame(maxWidth: 420)
                    Text("Pick your built-in or desk mic so connecting AirPods doesn't switch dictation to their lower-quality mic. If it's not connected, the system default is used.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Pause Music & Spotify while dictating", isOn: $pauseMediaWhileDictating)
                    Text("Pauses only if playing, and resumes when you're done. macOS asks once to let Sotto control them.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Language")
                        .font(.headline)
                    Picker("", selection: $languageMode) {
                        Text("English").tag(DictationLanguageMode.english)
                        Text("Auto-detect").tag(DictationLanguageMode.auto)
                        Text("Choose up to 3").tag(DictationLanguageMode.chosen)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    if languageMode == .chosen {
                        ForEach(0..<3, id: \.self) { slot in
                            Picker("Language \(slot + 1)", selection: languageBinding(slot)) {
                                if slot > 0 { Text("None").tag("") }
                                ForEach(LocalTranscriptionService.supportedLanguages, id: \.code) { language in
                                    Text(language.name).tag(language.code)
                                }
                            }
                            .frame(maxWidth: 320)
                        }
                    }

                    Text(languageFootnote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // On-device text cleanup
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable AI Enhancement (on-device)", isOn: $enableLLMProcessing)
                    Text("Cleans up grammar and removes filler words entirely on your Mac. Uses Apple Intelligence when available, then the optional local model below, otherwise a built-in rule-based cleaner.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if enableLLMProcessing {
                LocalLLMSettings(settings: settings)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Voice commands", isOn: $voiceCommandsEnabled)
                    Text("Say “new line”, “new paragraph”, “bullet point”, “comma”, “question mark”, or “at sign” to format as you speak. “Scratch that” drops the sentence you just said, and “3 pm, actually 4 pm” keeps only the correction. Spoken lists (“one …, two …”) become numbered lists. Only clear cases are changed, and this works with AI Enhancement off.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            LiveTextSettings(settings: settings, languageMode: languageMode)

            LearnFromCorrectionsSettings(settings: settings)

            FileNameSettings(settings: settings)
        }
        .padding(16)
        .onAppear { loadSettings() }
        .onChange(of: enableLLMProcessing) { saveSettings() }
        .onChange(of: voiceCommandsEnabled) { saveSettings() }
        .onChange(of: inputDeviceUID) { saveSettings() }
        .onChange(of: pauseMediaWhileDictating) { saveSettings() }
        .onChange(of: languageMode) { saveSettings() }
        .onChange(of: dictationLanguages) { saveSettings() }
    }

    // MARK: - Model

    private var modelSettings: some View {
        SpeechEngineSettings(languageMode: languageMode)
    }

    // MARK: - Actions

    private var languageFootnote: String {
        switch languageMode {
        case .english:
            return "Fastest and most accurate for English."
        case .auto:
            return "Whisper detects the language as you speak, so switching languages mid-dictation works. Cleanup keeps the language you spoke."
        case .chosen:
            return "Each dictation uses whichever of these it sounds most like. For mixing languages within one dictation, use Auto-detect."
        }
    }

    private func languageBinding(_ slot: Int) -> Binding<String> {
        Binding(
            get: { slot < dictationLanguages.count ? dictationLanguages[slot] : "" },
            set: { code in
                var languages = dictationLanguages
                if slot < languages.count {
                    languages[slot] = code
                } else if !code.isEmpty {
                    languages.append(code)
                }
                dictationLanguages = languages.filter { !$0.isEmpty }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                if dictationLanguages.isEmpty { dictationLanguages = ["en"] }
            }
        )
    }

    private func loadSettings() {
        enableLLMProcessing = settings.enableLLMProcessing
        voiceCommandsEnabled = settings.voiceCommandsEnabled
        inputDevices = AudioInputDevices.all()
        inputDeviceUID = settings.inputDeviceUID
        pauseMediaWhileDictating = settings.pauseMediaWhileDictating
        languageMode = settings.languageMode
        dictationLanguages = settings.dictationLanguages
    }

    private func saveSettings() {
        settings.enableLLMProcessing = enableLLMProcessing
        settings.voiceCommandsEnabled = voiceCommandsEnabled
        settings.inputDeviceUID = inputDeviceUID
        settings.pauseMediaWhileDictating = pauseMediaWhileDictating
        settings.languageMode = languageMode
        settings.dictationLanguages = dictationLanguages
        onSave?()
    }

}

// MARK: - System Settings Section

struct SystemSettingsSection: View {
    var settings: AppSettings
    var onSave: (() -> Void)?

    @State private var launchAtLogin: Bool = false
    @State private var showDockIcon: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                    Text("Start Sotto automatically when you log in to your Mac")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show Dock Icon", isOn: $showDockIcon)
                    Text("When disabled, Sotto will only appear in the menu bar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    DictationPermissionSettings()
                }
            }

            CommandLineToolSettings()

            AgentRelaySettings(settings: settings)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Updates")
                        .font(.headline)

                    Button(action: {
                        WindowManager.shared.updaterController.checkForUpdates(nil)
                    }) {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .padding(16)
        .onAppear { loadSettings() }
        .onChange(of: launchAtLogin) { applyLaunchAtLogin() }
        .onChange(of: showDockIcon) { applyDockIconVisibility() }
    }

    private func loadSettings() {
        launchAtLogin = settings.launchAtLogin
        showDockIcon = settings.showDockIcon
    }

    private func applyLaunchAtLogin() {
        settings.launchAtLogin = launchAtLogin
        guard ProcessInfo.processInfo.environment["SOTTO_TESTING"] != "1" else { return }

        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
            }
        }
        onSave?()
    }

    private func applyDockIconVisibility() {
        settings.showDockIcon = showDockIcon

        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        onSave?()
    }
}
