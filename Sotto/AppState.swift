import AppKit
import SwiftUI
import Observation
import Carbon.HIToolbox
import os

@Observable
final class AppState {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "AppState")

    // State
    var recordingState: RecordingState = .idle
    var audioLevel: Float = 0
    var lastTranscription: String?
    var lastError: String?
    let dictationFeedback = DictationFeedback()
    var showSettings: Bool = false
    /// N6: the first-run setup sheet on the main window.
    var showOnboarding: Bool = !AppSettings.shared.hasCompletedOnboarding
    /// User-facing phase while `recordingState == .processing`
    /// (Downloading model… / Loading model… / Transcribing… / Cleaning…).
    var processingStatus: String = ""

    // Computed
    var isRecording: Bool { recordingState == .recording }
    var isProcessing: Bool { recordingState == .processing }

    // Services
    private let recordingService = RecordingService()
    private let transcriptionManager = TranscriptionEngineManager.shared
    private let screenCaptureService = ScreenCaptureService()
    private let outputService = OutputService()
    private let hotkeyManager = HotkeyManager()
    private let llmService = LLMService.shared
    private let settings = AppSettings.shared
    private let cursorPositionService = CursorPositionService()
    private let mediaPauser = MediaPauser()

    // Recording state
    private var currentRecordingURL: URL?
    private var dictationOperation: TranscriptionEngineManager.Operation?
    private var audioLevelTimer: Timer?
    private var dotTrackingTimer: Timer?
    private var statusPollTimer: Timer?
    private var floatingWindow: FloatingDictationWindow?
    private var notchCapsuleWindow: NotchCapsuleWindow?
    private var cursorIndicatorWindow: CursorIndicatorWindow?
    private var recordingStartTime: Date?
    /// Key-down to end of capture (tail included) for the recording being processed.
    private var recordDuration: TimeInterval?

    /// N7: recordings stop on their own after this long (warned a minute before).
    private static let maxRecordingDuration: TimeInterval = 20 * 60
    private static let recordingWarningLead: TimeInterval = 60
    @ObservationIgnored private var recordingLimitTask: Task<Void, Never>?
    /// Recordings longer than this are transcribed in 60 s chunks so none hits the per-call timeout.
    private static let chunkedTranscriptionThreshold: TimeInterval = 4 * 60
    /// N7: a tip earned by the dictation being processed, shown once it's pasted.
    private var pendingTip: String?
    /// A warning earned while processing (e.g. L10 couldn't translate), shown after the paste.
    private var pendingNotice: String?
    /// N4: the mode for the current dictation. Starts as the matched mode; tapping the
    /// mode-cycle key changes it for this dictation only.
    enum ModeChoice: Equatable {
        case defaults
        case raw
        case mode(AppMode)

        var label: String {
            switch self {
            case .defaults: return "Default"
            case .raw: return "Raw"
            case .mode(let mode): return mode.skipsCleanup ? "\(mode.displayName) · Raw" : mode.displayName
            }
        }

        var appMode: AppMode? {
            if case .mode(let mode) = self { return mode }
            return nil
        }

        var skipsCleanup: Bool {
            self == .raw || appMode?.skipsCleanup == true
        }
    }
    private var modeChoice: ModeChoice = .defaults
    private var modeChosenManually = false
    /// N15: a mode picked by sotto://mode/<name> or Shortcuts while idle, used by the next dictation.
    private var nextModeChoice: ModeChoice?

    /// N1: set while the current recording is a Command-mode instruction. `selection` is nil when
    /// Accessibility couldn't read the field (then ⌘C is tried once the instruction is in).
    private struct CommandContext {
        let selection: String?
    }
    private var commandContext: CommandContext?

    /// L7: the Scratchpad note the current recording goes into (instead of pasting into an app).
    private var scratchpadNoteID: UUID?
    /// Set by the Scratchpad shortcut/button just before it starts a recording.
    private var startsInScratchpad = false
    /// The current dictation goes into the Scratchpad.
    var isScratchpadDictation: Bool { scratchpadNoteID != nil }

    /// L6: a finished coding agent waiting for a spoken follow-up (shown as a prompt).
    private var pendingAgentRequest: AgentRelay.Request?
    /// The request the current recording answers (its text goes to the agent, not an app).
    private var agentReplyRequest: AgentRelay.Request?
    private var startsAgentReply = false

    /// Text selected in the source app when recording started (cleanup reference only).
    private var selectionContext: String?
    /// Text copied up to this long before recording starts counts as context.
    private static let clipboardContextWindow: TimeInterval = 3
    private var sourceApp: NSRunningApplication?
    private var sourceAppName: String?
    private var sourceAppIdentity: SourceAppIdentity?
    private var sourceWindowTitle: String?
    private var sourceWebsiteURL: URL?
    private var processingTask: Task<Void, Never>?
    private var currentPipelineID: UUID?

    /// ESC on a recording at least this long keeps the audio and offers Undo instead of
    /// deleting it outright; shorter ones cancel instantly.
    private static let undoableCancelDuration: TimeInterval = 20
    private static let cancelUndoWindow: TimeInterval = 10
    /// Audio of a cancelled long recording, kept until Undo, the window expiring, or the next
    /// recording starting.
    private var pendingUndo: (url: URL, expiry: Task<Void, Never>)?

    // History
    private let historyManager = TranscriptionHistoryManager.shared

    // ESC key monitors for canceling recording
    private var escKeyMonitor: Any?
    private var escLocalKeyMonitor: Any?

    /// The last app the user worked in other than Sotto: where "Paste last transcript" goes when
    /// it's chosen from Sotto's own menu.
    private var lastExternalApp: NSRunningApplication?
    private var appActivationObserver: Any?

    /// The app's single AppState, for the app delegate (file opens, sotto:// links) and App Intents.
    private(set) static weak var current: AppState?

    init() {
        // Hosted unit tests must not register hotkeys, prune personal history, or load models.
        if ProcessInfo.processInfo.environment["SOTTO_TESTING"] == "1" {
            Self.current = self
            showOnboarding = false
            return
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let aiEnhancement = settings.enableLLMProcessing ? "on" : "off"
        Self.logger.notice("launched version=\(version, privacy: .public) build=\(build, privacy: .public) aiEnhancement=\(aiEnhancement, privacy: .public) path=\(Bundle.main.bundlePath, privacy: .public)")
        Self.current = self
        setupHotkey()
        trackExternalApps()
        ClipboardWatcher.shared.start()
        VocabularyServiceProvider.shared.onNotice = { [weak self] message in
            Task { @MainActor in self?.showNotice(message) }
        }
        CorrectionWatcher.shared.onSuggestion = { [weak self] correction in
            Task { @MainActor in self?.offerCorrection(correction) }
        }
        AgentRelayService.shared.onRequest = { [weak self] request in
            Task { @MainActor in self?.handleAgentRequest(request) }
        }
        AgentRelayService.shared.sync()
        historyManager.applyRetention()
        TypingCounterService.shared.sync()
        autoLoadTranscriptionModel()
        DispatchQueue.global(qos: .utility).async {
            RecordingService.removeStaleRecordings()
        }
    }

    /// The only place the model load is started automatically; dictations join this load.
    private func autoLoadTranscriptionModel() {
        Task { @MainActor in
            NSLog("[AppState] Loading transcription model on launch…")
            await transcriptionManager.prepare()
            NSLog(
                "[AppState] Launch model load finished. ready=%@ error=%@",
                transcriptionManager.engine.isReady ? "yes" : "no",
                transcriptionManager.engine.loadError ?? "none"
            )
        }
    }

    private func setupHotkey() {
        // The dictation key's gestures never act on a Command-mode recording: that one is
        // ended by releasing the Command key (or ESC).
        hotkeyManager.register(
            onStart: { [weak self] in
                Task { @MainActor in
                    guard let self, self.commandContext == nil else { return }
                    await self.startRecording()
                }
            },
            onStop: { [weak self] in
                Task { @MainActor in
                    guard let self, self.commandContext == nil else { return }
                    await self.stopRecording()
                }
            },
            onDiscard: { [weak self] in
                Task { @MainActor in
                    guard let self, self.commandContext == nil else { return }
                    self.discardRecording()
                }
            }
        )
        hotkeyManager.registerCommand(
            onStart: { [weak self] in
                Task { @MainActor in await self?.startCommand() }
            },
            onStop: { [weak self] in
                Task { @MainActor in await self?.stopCommand() }
            }
        )
        hotkeyManager.registerModeCycling { [weak self] in
            Task { @MainActor in self?.cycleMode() }
        }
        hotkeyManager.registerTranscriptActions(
            onPasteLast: { [weak self] in
                Task { @MainActor in self?.pasteLastTranscript(fromMenu: false) }
            },
            onCopyLast: { [weak self] in
                Task { @MainActor in self?.copyLastTranscript() }
            }
        )
        hotkeyManager.registerAction("scratchpad", shortcut: {
            let settings = AppSettings.shared
            return (settings.scratchpadKeyCode, settings.scratchpadModifiers)
        }, action: { [weak self] in
            Task { @MainActor in self?.toggleScratchpadDictation() }
        })
        hotkeyManager.registerAction("read-last", shortcut: {
            let settings = AppSettings.shared
            return (settings.readLastKeyCode, settings.readLastModifiers)
        }, action: { [weak self] in
            Task { @MainActor in self?.readLastTranscript() }
        })
    }

    // MARK: - Last Transcript Actions

    /// The newest saved transcript. Read from history so it survives relaunches.
    var lastSavedTranscript: String? {
        historyManager.entries.first { !$0.isFailed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    /// Pastes the latest transcript and restores the clipboard afterwards. From the menu, it
    /// goes to the app the user was last in; from the hotkey, to the frontmost app.
    @MainActor
    func pasteLastTranscript(fromMenu: Bool) {
        guard recordingState == .idle, let text = lastSavedTranscript else {
            NSSound.beep()
            return
        }
        let feedbackGeneration = dictationFeedback.begin()
        lastError = nil
        Task { @MainActor in
            // The shortcut's own modifiers are still held; a paste sent now would arrive as
            // e.g. ⌃⌘V instead of ⌘V.
            await Self.waitForModifierKeysReleased()
            guard dictationFeedback.generation == feedbackGeneration else { return }
            if fromMenu, NSApp.isActive, let target = lastExternalApp {
                target.activate()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let outcome = await outputService.pasteRestoringClipboard(text, shouldProceed: {
                self.dictationFeedback.generation == feedbackGeneration
            })
            guard dictationFeedback.complete(.output(outcome), for: feedbackGeneration) else { return }
            if outcome == .pasted, let tip = takeTip("pasteLast") {
                showNotice(tip, seconds: 5)
            }
            Self.logger.notice("paste last transcript outcome=\(String(describing: outcome), privacy: .public) chars=\(text.count, privacy: .public)")
            if outcome == .copiedMissingAccessibility {
                NSSound.beep()
            } else if settings.soundEffectsEnabled {
                NSSound(named: "Glass")?.play()
            }
        }
    }

    @MainActor
    func copyLastTranscript() {
        guard let text = lastSavedTranscript else {
            NSSound.beep()
            return
        }
        copyTranscript(text)
    }

    @MainActor
    func copyTranscript(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = dictationFeedback.begin()
        lastError = nil
        let copied = outputService.copyToClipboard(text)
        dictationFeedback.complete(.output(copied ? .copied : .failed), for: generation)
        Self.logger.notice("copied last transcript chars=\(text.count, privacy: .public)")
        if !copied { NSSound.beep() }
        else if settings.soundEffectsEnabled {
            NSSound(named: "Tink")?.play()
        }
    }

    /// L13: the newest transcript with text (failed dictations are saved empty).
    var lastReadableTranscript: String? {
        historyManager.entries.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    /// L13: reads the last transcript aloud, or stops if something is being read.
    @MainActor
    func readLastTranscript() {
        let speech = SpeechService.shared
        if speech.isSpeaking {
            speech.stop()
            return
        }
        guard let text = lastReadableTranscript else {
            NSSound.beep()
            return
        }
        speech.speak(text)
    }

    private func trackExternalApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID {
            lastExternalApp = app
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            self?.lastExternalApp = app
        }
    }

    private static func waitForModifierKeysReleased(timeout: TimeInterval = 1.0) async {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              !CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func refreshHotkey() {
        guard ProcessInfo.processInfo.environment["SOTTO_TESTING"] != "1" else { return }
        hotkeyManager.refreshHotkey()
    }

    func toggleRecording() {
        Task { @MainActor in
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    @MainActor
    private func startRecording() async {
        guard ProcessInfo.processInfo.environment["SOTTO_TESTING"] != "1" else { return }
        guard recordingState == .idle else {
            // Something else started first: these one-shot flags were for this start only.
            startsInScratchpad = false
            startsAgentReply = false
            return
        }

        // A new recording replaces the source app and capsule a pending Undo would need. The
        // minimal style re-shows the capsule right away; the floating widget doesn't use it.
        dropPendingUndo(hideNotice: settings.recordingUIStyle != .minimal)
        CorrectionWatcher.shared.stop()
        promptGeneration += 1
        lastError = nil
        dictationFeedback.begin()

        // Capture source app before we start (cursor is in this app).
        // Window title uses Accessibility only — never CGWindowList / Screen Recording APIs.
        sourceApp = NSWorkspace.shared.frontmostApplication
        sourceAppName = sourceApp?.localizedName
        sourceAppIdentity = sourceApp.map { SourceAppIdentity(app: $0) }
        sourceWindowTitle = screenCaptureService.getActiveWindowTitle()
        sourceWebsiteURL = BrowserURLService.currentURL(for: sourceApp)
        modeChoice = settings.getMode(for: sourceAppIdentity, url: sourceWebsiteURL).map(ModeChoice.mode) ?? .defaults
        modeChosenManually = false
        if let next = nextModeChoice {
            modeChoice = next
            modeChosenManually = true
            nextModeChoice = nil
        }
        // L7: from the Scratchpad (its shortcut, or dictating while its window is in front) the
        // dictation goes into the note, cleaned with the default instructions (no App Mode).
        // L6: a spoken reply to a coding agent (started from its prompt or sotto://agent/reply).
        agentReplyRequest = startsAgentReply ? pendingAgentRequest : nil
        startsAgentReply = false
        if agentReplyRequest != nil {
            pendingAgentRequest = nil
            modeChoice = .defaults
        }
        let intoScratchpad = commandContext == nil && agentReplyRequest == nil
            && (startsInScratchpad || ScratchpadWindowController.shared.isKeyWindow)
        startsInScratchpad = false
        scratchpadNoteID = intoScratchpad ? NotesManager.shared.dictationTarget() : nil  // created only when text arrives
        if intoScratchpad, !modeChosenManually {
            modeChoice = .defaults
        }
        // L11: index the open project's file names while the user speaks.
        if !intoScratchpad, commandContext == nil, agentReplyRequest == nil {
            WorkspaceIndexService.shared.prepare(for: sourceApp, windowTitle: sourceWindowTitle)
        }
        recordingStartTime = Date()
        recordDuration = nil
        // The paste only goes to this app; see performPaste().
        Self.logger.notice("recording source app=\(self.sourceApp?.bundleIdentifier ?? "nil", privacy: .public) pid=\(self.sourceApp?.processIdentifier ?? -1, privacy: .public)")

        // Leftovers from a dictation cut off by a quit or crash go now, not at the next launch.
        // The age cutoff keeps the recording about to be created (and any in flight) safe.
        DispatchQueue.global(qos: .utility).async {
            RecordingService.removeStaleRecordings()
        }

        do {
            // L1: live text needs the capsule (Minimal style); never for Command instructions.
            recordingService.capturesLiveAudio = settings.liveTextEnabled
                && transcriptionManager.livePreviewAvailable
                && settings.recordingUIStyle == .minimal && commandContext == nil
            let url = try recordingService.startRecording()
            currentRecordingURL = url
            dictationOperation = transcriptionManager.beginOperation()
            recordingState = .recording
            hotkeyManager.setRecordingState(true)

            if settings.pauseMediaWhileDictating {
                mediaPauser.pauseIfPlaying()
            }
            scheduleRecordingLimit()

            // Show recording UI
            showRecordingUI()
            showModeLabel()
            captureStartContext()

            // Start audio level updates
            startAudioLevelUpdates()
            startLivePreview()

            // Play start sound
            if settings.soundEffectsEnabled {
                NSSound(named: "Tink")?.play()
            }

            // ESC key monitors — need both global + local to cover all focus states
            escKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == UInt16(kVK_Escape) {
                    NSLog("[AppState] ESC pressed (global monitor)")
                    Task { @MainActor in
                        self?.cancelRecording()
                    }
                }
            }
            escLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == UInt16(kVK_Escape) {
                    NSLog("[AppState] ESC pressed (local monitor)")
                    Task { @MainActor in
                        self?.cancelRecording()
                    }
                    return nil
                }
                return event
            }
            NSLog("[AppState] ESC monitors installed")

        } catch {
            lastError = error.localizedDescription
            recordingState = .idle
        }
    }

    @MainActor
    private func stopRecording() async {
        guard recordingState == .recording else { return }
        stopLivePreview()
        mediaPauser.resume()
        recordingLimitTask?.cancel()

        // Remove ESC monitor
        removeEscMonitor()

        // Stop audio level updates
        stopAudioLevelUpdates()

        // The UI switches to processing now; the mic keeps running for a short tail inside the
        // pipeline task so the last word isn't clipped (ESC meanwhile cancels it at once).
        recordingState = .processing
        processingStatus = transcriptionManager.statusMessage
        setRecordingUIProcessing()
        startStatusPolling()

        // Play stop sound
        if settings.soundEffectsEnabled {
            NSSound(named: "Pop")?.play()
        }

        let tail = settings.recordingTail
        await startPipeline { [weak self, recordingService] in
            let url = await recordingService.stopRecording(tail: tail)
            self?.recordDuration = self?.recordingStartTime.map { Date().timeIntervalSince($0) }
            return url
        }
    }

    /// Runs transcribe → cleanup → paste on the audio `audio()` produces, as the one cancellable
    /// processing task. Used for a normal stop and for Undo of a cancelled recording.
    @MainActor
    private func startPipeline(audio: @escaping @MainActor () async -> URL?) async {
        processingTask?.cancel()
        let operation = dictationOperation ?? transcriptionManager.beginOperation()
        dictationOperation = nil
        let pipelineID = UUID()
        currentPipelineID = pipelineID
        let task = Task { @MainActor in
            defer { self.transcriptionManager.endOperation(operation) }
            guard let audioURL = await audio() else {
                // Nothing was captured, or ESC during the tail (which already reset everything).
                guard self.currentPipelineID == pipelineID else { return }
                self.currentPipelineID = nil
                self.processingTask = nil
                self.stopStatusPolling()
                self.recordingService.reset()
                self.hideRecordingUI()
                self.recordingState = .idle
                self.processingStatus = ""
                self.hotkeyManager.setRecordingState(false)
                return
            }
            await self.runTranscriptionPipeline(audioURL: audioURL, pipelineID: pipelineID, engineID: operation.engineID)
        }
        processingTask = task
        await task.value
    }

    @MainActor
    private func runTranscriptionPipeline(audioURL: URL, pipelineID: UUID, engineID: SpeechEngineID) async {
        // A cancelled pipeline can wake up minutes later (e.g. after joining the first-run
        // model download); it must not reset state that now belongs to a newer recording.
        var ownsState: Bool { currentPipelineID == pipelineID }
        // Set when "Keep audio for" hands the WAV to AudioArchive, which deletes it after encoding.
        var audioArchived = false

        defer {
            // Success, error, or cancel: the audio is never needed again. Runs only after
            // transcribe returns, so the file isn't removed while it's being read.
            if !audioArchived {
                recordingService.cleanup(url: audioURL)
            }
            if ownsState {
                currentPipelineID = nil
                stopStatusPolling()
                processingTask = nil
                recordingService.reset()
            }
        }

        do {
            try Task.checkCancellation()

            if !transcriptionManager.engine.isReady {
                NSLog("[AppState] Model not ready yet — waiting for the launch load (%@)", transcriptionManager.statusMessage)
            }
            setProcessingStatus(transcriptionManager.statusMessage)

            let command = commandContext
            commandContext = nil

            // Chromium/Electron build their AX tree on first request, so the URL may only be
            // readable now. The source app is still frontmost while processing.
            if sourceWebsiteURL == nil, sourceApp == NSWorkspace.shared.frontmostApplication {
                sourceWebsiteURL = BrowserURLService.currentURL(for: sourceApp)
            }
            // Resolved once, before transcribing (L10 Translate changes how it's transcribed):
            // decides Translate, Raw (skip cleanup) and Send after paste. A mode picked with the
            // cycle key wins; otherwise re-match now that the URL may be known.
            let choice = modeChosenManually || scratchpadNoteID != nil || agentReplyRequest != nil
                ? modeChoice
                : (settings.getMode(for: sourceAppIdentity, url: sourceWebsiteURL).map(ModeChoice.mode) ?? .defaults)
            let mode = choice.appMode
            let translate = command == nil && mode?.translateToEnglish == true
            pendingNotice = nil

            let transcribeStart = Date()
            var transcript: String
            var cleanupLanguage: String?
            if translate {
                (transcript, cleanupLanguage) = try await transcribeToEnglish(audioURL, duration: recordDuration ?? 0, engineID: engineID)
            } else {
                transcript = try await transcribeAudio(audioURL, duration: recordDuration ?? 0, engineID: engineID)
                cleanupLanguage = transcriptionManager.lastLanguage
            }
            let transcribeTime = Date().timeIntervalSince(transcribeStart)
            try Task.checkCancellation()

            if let command {
                audioArchived = await runCommand(instruction: transcript, command: command, audioURL: audioURL, transcribeTime: transcribeTime)
                return
            }

            // Snippets and spoken commands are deterministic and run before cleanup; snippet
            // blocks stay as placeholders until cleanup is done so it can't reword them.
            var prepared = DictationTextRules.prepare(
                transcript,
                snippets: settings.snippets,
                voiceCommands: settings.voiceCommandsEnabled
            )
            // L11: spoken file names from the project open in a code editor, written exactly and
            // protected from cleanup like snippets.
            if scratchpadNoteID == nil, let index = await WorkspaceIndexService.shared.currentIndex() {
                prepared = DictationTextRules.protectFileNames(prepared, index: index)
                if prepared.resolvedFileNames > 0 {
                    Self.logger.notice("resolved file names=\(prepared.resolvedFileNames, privacy: .public) of indexed=\(index.fileCount, privacy: .public)")
                }
            }
            // "Raw" for history and Undo AI Edit: everything except the AI cleanup.
            let rawText = prepared.expand(prepared.text)
            pendingTip = prepared.usedBacktrack ? takeTip("backtrack")
                : prepared.usedFormatting ? takeTip("formatting") : nil
            var text = rawText
            var cleanedText: String?
            var cleanupTime: TimeInterval?
            var modeName: String?

            // LLM post-processing (if enabled)
            if settings.enableLLMProcessing, prepared.isOnlySnippets {
                Self.logger.notice("dictation is only snippet cues; cleanup skipped")
            } else if settings.enableLLMProcessing, choice.skipsCleanup {
                Self.logger.notice("mode=\(choice.label, privacy: .public) is Raw; cleanup skipped")
                modeName = choice.label
            } else if settings.enableLLMProcessing {
                setProcessingStatus("Cleaning…")
                let cleanupStart = Date()
                defer { cleanupTime = Date().timeIntervalSince(cleanupStart) }
                do {
                    // Screen context is optional and time-boxed inside the service.
                    // When OFF: zero ScreenCaptureKit / Screen Recording API calls.
                    // When ON: permission requested at most once per process (service-gated).
                    // Never let OCR failure/hang abort transcribe→paste.
                    var context = CleanupContext(selectedText: selectionContext)
                    if settings.enableScreenContext {
                        context.screenText = await screenCaptureService.captureScreenContext()
                    }
                    // Copied just before or during the dictation.
                    if settings.useSelectionAndClipboardContext, let start = recordingStartTime {
                        context.clipboardText = ClipboardWatcher.shared.textCopied(
                            since: start.addingTimeInterval(-Self.clipboardContextWindow)
                        )
                        if context.clipboardText != nil {
                            notchCapsuleWindow?.setContextCaptured(true)
                        }
                    }
                    try Task.checkCancellation()
                    let cleaned = try await llmService.processText(
                        prepared.text,
                        context: context,
                        sourceApp: sourceAppIdentity,
                        websiteURL: sourceWebsiteURL,
                        mode: mode,
                        protectedTokens: prepared.tokens,
                        language: cleanupLanguage
                    )
                    text = prepared.expand(cleaned)
                    cleanedText = text
                    modeName = mode?.displayName
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Log error but continue with raw transcription
                    NSLog("[AppState] LLM processing failed, using raw transcription: %@", error.localizedDescription)
                }
            } else {
                Self.logger.notice("AI Enhancement is off; skipping cleanup, App Modes not applied")
            }

            try Task.checkCancellation()

            lastTranscription = text
            setProcessingStatus("Pasting…")
            let details = DictationDetails(
                rawText: rawText,
                cleanedText: cleanedText,
                modeName: modeName,
                record: recordDuration ?? 0,
                transcribe: transcribeTime,
                cleanup: cleanupTime,
                sendKey: mode.flatMap { $0.sendAfterPaste ? $0.sendKey : nil }
            )
            if let noteID = scratchpadNoteID {
                audioArchived = deliverToScratchpad(noteID, details: details, audioURL: audioURL)
            } else if let request = agentReplyRequest {
                deliverAgentReply(request, details: details)
            } else {
                audioArchived = performPaste(details: details, audioURL: audioURL)
            }

        } catch is CancellationError {
            NSLog("[AppState] Transcription pipeline cancelled")
            guard ownsState else { return }
            hideRecordingUI()
            recordingState = .idle
            processingStatus = ""
            hotkeyManager.setRecordingState(false)
        } catch {
            guard ownsState else {
                NSLog("[AppState] Stale pipeline failed after cancel: %@", error.localizedDescription)
                return
            }
            lastError = error.localizedDescription
            NSLog("[AppState] Transcription pipeline failed: %@", error.localizedDescription)

            // N2: keep the failed dictation with its audio so it can be retried from history.
            if FileManager.default.fileExists(atPath: audioURL.path) {
                let entryID = UUID()
                let fileName = AudioArchive.fileName(for: entryID)
                AudioArchive.archive(wav: audioURL, as: fileName)
                audioArchived = true
                historyManager.addEntry(TranscriptionEntry(
                    id: entryID,
                    text: "",
                    duration: recordDuration ?? recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0,
                    sourceApp: sourceAppName,
                    windowTitle: sourceWindowTitle,
                    sourceWebsite: BrowserURLService.origin(of: sourceWebsiteURL),
                    outputMethod: .notPasted,
                    transcriptionMode: .local,
                    audioFileName: fileName,
                    failureReason: error.localizedDescription
                ))
            }

            if settings.soundEffectsEnabled {
                NSSound(named: "Basso")?.play()
            }

            recordingState = .idle
            processingStatus = ""
            hotkeyManager.setRecordingState(false)

            if let modelError = error as? LocalTranscriptionError, modelError.isModelLoadFailure {
                showErrorBrieflyThenHide("⚠︎ Model not loaded — see Settings")
            } else {
                hideRecordingUI()
            }
        }
    }

    /// Keeps the capsule/widget up with an error or warning for a few seconds instead of an
    /// endless spinner. A "⚠︎" prefix shows the capsule's warning icon.
    @MainActor
    private func showErrorBrieflyThenHide(_ message: String, seconds: Double = 3) {
        let generation = dictationFeedback.generation
        promptGeneration += 1
        let noticeGeneration = promptGeneration
        notchCapsuleWindow?.setProcessing(true, status: message)
        cursorIndicatorWindow?.hide()
        floatingWindow?.updateState(.processing(status: message))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.promptGeneration == noticeGeneration, self.dictationFeedback.generation == generation, self.recordingState == .idle, self.notchCapsuleWindow?.isShowingPrompt != true else { return }
            self.hideRecordingUI()
        }
    }

    /// A short capsule message while idle (e.g. "✓ Added … to Vocabulary"). Never interrupts
    /// a recording or a dictation in progress.
    @MainActor
    private func showNotice(_ message: String, seconds: Double = 2) {
        guard recordingState == .idle else { return }
        promptGeneration += 1
        let generation = promptGeneration
        if notchCapsuleWindow == nil {
            notchCapsuleWindow = NotchCapsuleWindow()
        }
        notchCapsuleWindow?.show()
        notchCapsuleWindow?.setProcessing(true, status: message)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard self.promptGeneration == generation, self.recordingState == .idle, self.notchCapsuleWindow?.isShowingPrompt != true else { return }
            self.notchCapsuleWindow?.hide()
        }
    }

    /// Bumped per prompt so an older prompt's timeout doesn't hide a newer one.
    @ObservationIgnored private var promptGeneration = 0

    /// A clickable capsule prompt while idle (L2 suggestions, L6 relay). Hides
    /// itself after `seconds` unless answered or replaced.
    @MainActor
    private func showPrompt(_ prompt: CapsulePrompt, seconds: Double) {
        guard recordingState == .idle else { return }
        if notchCapsuleWindow == nil {
            notchCapsuleWindow = NotchCapsuleWindow()
        }
        promptGeneration += 1
        let generation = promptGeneration
        notchCapsuleWindow?.showPrompt(prompt)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard generation == self.promptGeneration, self.recordingState == .idle,
                  self.notchCapsuleWindow?.isShowingPrompt == true else { return }
            self.notchCapsuleWindow?.hide()
        }
    }

    @MainActor
    private func dismissPrompt() {
        promptGeneration += 1
        if notchCapsuleWindow?.isShowingPrompt == true {
            notchCapsuleWindow?.hide()
        }
    }

    // MARK: - Learn From Corrections (L2)

    /// Offers a hand fix for Vocabulary (one word) or Replacements (a phrase).
    @MainActor
    private func offerCorrection(_ correction: DictationTextRules.Correction) {
        guard recordingState == .idle else { return }
        let text = correction.isSingleWord
            ? "Add “\(correction.corrected)” to Vocabulary?"
            : "Replace “\(correction.original)” → “\(correction.corrected)”?"
        showPrompt(CapsulePrompt(
            icon: "text.badge.plus",
            iconColor: Color(red: 0x4F / 255, green: 0xD1 / 255, blue: 0xC5 / 255),
            text: text,
            actions: [.init(title: "Add") { [weak self] in
                Task { @MainActor in self?.acceptCorrection(correction) }
            }],
            onDismiss: { [weak self] in
                Task { @MainActor in
                    self?.settings.ignoredCorrections.append(CorrectionWatcher.key(correction))
                    self?.dismissPrompt()
                }
            }
        ), seconds: 8)
    }

    /// One word goes to Vocabulary (a spelling hint for Whisper, and its spelling and case are
    /// applied to every transcript); a phrase becomes a Replacement.
    @MainActor
    private func acceptCorrection(_ correction: DictationTextRules.Correction) {
        if correction.isSingleWord {
            settings.addToVocabulary([correction.corrected])
            showNotice("✓ Added “\(correction.corrected)” to Vocabulary", seconds: 2)
        } else {
            settings.upsertReplacement(spoken: correction.original, written: correction.corrected)
            showNotice("✓ Added replacement for “\(correction.original)”", seconds: 2)
        }
        Self.logger.notice("correction accepted single=\(correction.isSingleWord, privacy: .public)")
    }

    @MainActor
    private func setProcessingStatus(_ status: String) {
        processingStatus = status
        notchCapsuleWindow?.setProcessing(true, status: status)
        floatingWindow?.updateState(.processing(status: status))
        NSLog("[AppState] Processing status: %@", status)
    }

    private func startStatusPolling() {
        stopStatusPolling()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.recordingState == .processing else { return }
                // Prefer engine phase while still in download/load/transcribe;
                // keep "Cleaning…" / "Pasting…" once we have moved past ASR.
                let engineStatus = self.transcriptionManager.statusMessage
                let current = self.processingStatus
                if current == "Cleaning…" || current == "Pasting…" || current.contains("%") { return }
                if !engineStatus.isEmpty && engineStatus != current {
                    self.setProcessingStatus(engineStatus)
                }
            }
        }
    }

    private func stopStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    // MARK: - Recording UI

    private func showRecordingUI() {
        hideRecordingUI()
        switch settings.recordingUIStyle {
        case .minimal:
            showMinimalUI()
        case .dot:
            showDotUI()
        case .floating:
            showFloatingWidget()
        }
    }

    private func hideRecordingUI() {
        dotTrackingTimer?.invalidate()
        dotTrackingTimer = nil
        // Hide whichever is active
        notchCapsuleWindow?.hide()
        cursorIndicatorWindow?.hide()
        floatingWindow?.hide()
    }

    private func setRecordingUIProcessing() {
        switch settings.recordingUIStyle {
        case .minimal, .dot:
            notchCapsuleWindow?.setProcessing(true, status: processingStatus)
            cursorIndicatorWindow?.setProcessing(true)
        case .floating:
            floatingWindow?.updateState(.processing(status: processingStatus))
        }
    }

    private func showMinimalUI() {
        let position = cursorPositionService.getCursorPosition()
        // Notch capsule
        if notchCapsuleWindow == nil {
            notchCapsuleWindow = NotchCapsuleWindow()
        }
        notchCapsuleWindow?.show(on: position?.screen)

        // Cursor indicator — capture position once at recording start
        if cursorIndicatorWindow == nil {
            cursorIndicatorWindow = CursorIndicatorWindow()
        }
        // L16: some apps report the caret unreliably (terminals, games); the capsule still shows.
        if settings.hidesCaretDot(for: sourceAppIdentity) { return }
        if let pos = position {
            cursorIndicatorWindow?.show(at: pos.point)
        }
    }

    /// Dot-only presentation: keep all recording/output behavior, with bottom notices used
    /// for Undo and recovery. Per-app dot exclusions fall back to the bottom listener.
    private func showDotUI() {
        guard !settings.hidesCaretDot(for: sourceAppIdentity), let position = cursorPositionService.getCursorPosition() else {
            showMinimalUI()
            return
        }
        if cursorIndicatorWindow == nil { cursorIndicatorWindow = CursorIndicatorWindow() }
        cursorIndicatorWindow?.show(at: position.point)
        dotTrackingTimer?.invalidate()
        dotTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.recordingState != .idle else {
                    self.dotTrackingTimer?.invalidate()
                    self.dotTrackingTimer = nil
                    return
                }
                let front = NSWorkspace.shared.frontmostApplication.map { SourceAppIdentity(app: $0) }
                if self.settings.hidesCaretDot(for: front) {
                    if self.cursorIndicatorWindow?.isVisible == true { self.cursorIndicatorWindow?.hide() }
                } else if let position = self.cursorPositionService.getCursorPosition() {
                    if self.cursorIndicatorWindow?.isVisible != true {
                        self.cursorIndicatorWindow?.show(at: position.point)
                        self.cursorIndicatorWindow?.setProcessing(self.isProcessing)
                    } else {
                        self.cursorIndicatorWindow?.move(to: position.point)
                    }
                }
            }
        }
    }

    private func showFloatingWidget() {
        if floatingWindow == nil {
            floatingWindow = FloatingDictationWindow()
            floatingWindow?.configure(
                onCancel: { [weak self] in
                    Task { @MainActor in
                        self?.cancelRecording()
                    }
                },
                onPasteNow: { [weak self] in
                    Task { @MainActor in
                        self?.performPaste()
                    }
                }
            )
        }
        floatingWindow?.show(state: .recording, audioLevel: 0)
    }

    // MARK: - Paste

    /// Safe paste: the text only goes to the app that was frontmost when recording started.
    /// If the user has switched apps since, it stays on the clipboard and the capsule says so;
    /// Sotto never pulls them back to the old app.
    /// What the pipeline learned about a dictation, saved with its history entry.
    private struct DictationDetails {
        let rawText: String
        let cleanedText: String?
        let modeName: String?
        let record: TimeInterval
        let transcribe: TimeInterval
        let cleanup: TimeInterval?
        /// The App Mode's "Send after paste" key, if on.
        let sendKey: AppMode.SendKey?
        /// N1: replacing a selection, so no caret fitting and no send key.
        var isCommand = false
    }

    /// Returns true when the recording was handed to AudioArchive ("Keep audio for" is on), which
    /// then owns deleting the WAV.
    @MainActor
    @discardableResult
    private func performPaste(details: DictationDetails? = nil, audioURL: URL? = nil) -> Bool {
        guard let text = lastTranscription else { return false }
        processingStatus = ""

        let entryID = UUID()
        var audioFileName: String?
        if let audioURL, settings.audioRetention != .off {
            let fileName = AudioArchive.fileName(for: entryID)
            AudioArchive.archive(wav: audioURL, as: fileName)
            audioFileName = fileName
        }

        // Time spent speaking, which the Dashboard's WPM and time-saved figures assume.
        let duration = details?.record ?? recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let target = sourceApp
        let targetName = sourceAppName
        let targetTitle = sourceWindowTitle
        let targetWebsite = BrowserURLService.origin(of: sourceWebsiteURL)
        let feedbackGeneration = dictationFeedback.generation

        Task { @MainActor in
            guard dictationFeedback.generation == feedbackGeneration else { return }
            let pasteStart = Date()
            let outgoing = details?.isCommand == true ? text : fittedToCaret(text, target: target)
            let outcome = await outputService.output(text: outgoing, target: target, shouldProceed: {
                self.dictationFeedback.generation == feedbackGeneration
            })
            // Only after a real paste into the intended app, never after a copy-only outcome.
            if outcome == .pasted, dictationFeedback.generation == feedbackGeneration, let sendKey = details?.sendKey {
                _ = await outputService.pressSendKey(sendKey, target: target)
            }
            let pasteTime = Date().timeIntervalSince(pasteStart)
            Self.logger.notice("dictation output outcome=\(String(describing: outcome), privacy: .public) chars=\(text.count, privacy: .public)")

            let timings = details.map {
                TranscriptionEntry.StageTimings(record: $0.record, transcribe: $0.transcribe, cleanup: $0.cleanup, paste: pasteTime)
            }
            if let timings {
                let cleanup = timings.cleanup.map { String(format: "%.2f", $0) } ?? "off"
                Self.logger.notice("timings record=\(String(format: "%.2f", timings.record), privacy: .public) transcribe=\(String(format: "%.2f", timings.transcribe), privacy: .public) cleanup=\(cleanup, privacy: .public) paste=\(String(format: "%.2f", timings.paste), privacy: .public)")
            }

            historyManager.addEntry(TranscriptionEntry(
                id: entryID,
                text: text,
                duration: duration,
                sourceApp: targetName,
                windowTitle: targetTitle,
                sourceWebsite: targetWebsite,
                outputMethod: outcome == .pasted ? .paste : (outcome == .failed || outcome == .cancelled ? .notPasted : .clipboard),
                transcriptionMode: .local,
                rawText: details?.rawText,
                cleanedText: details?.cleanedText,
                modeName: details?.modeName,
                timings: timings,
                audioFileName: audioFileName
            ))
            // History retains the result even if an output completed after cancellation,
            // but all visible state and delayed notices belong to the current generation.
            guard dictationFeedback.complete(.output(outcome), for: feedbackGeneration) else { return }

            // No modal alerts, so dictation is never blocked. Without Accessibility, Settings
            // also shows a banner until it's granted.
            switch outcome {
            case .copiedMissingAccessibility:
                showErrorBrieflyThenHide("⚠︎ Copied — enable Accessibility to auto-paste", seconds: 4)
            case .copiedAppChanged:
                showErrorBrieflyThenHide("⚠︎ Copied — app changed")
            case .copiedPasteFailed:
                showErrorBrieflyThenHide("⚠︎ Copied — paste with Command-V", seconds: 4)
            case .failed:
                showErrorBrieflyThenHide("⚠︎ Could not copy — see Transcripts", seconds: 4)
            case .cancelled:
                break
            case .pasted, .copied:
                if let notice = pendingNotice {
                    showErrorBrieflyThenHide(notice, seconds: 4)
                } else {
                    hideRecordingUI()
                }
            }

            // Play success sound
            if settings.soundEffectsEnabled {
                NSSound(named: "Glass")?.play()
            }

            recordingState = .idle
            hotkeyManager.setRecordingState(false)

            // N7: at most one tip, only after a normal paste (a warning notice wins).
            let hadNotice = pendingNotice != nil
            pendingNotice = nil
            if (outcome == .pasted || outcome == .copied) && !hadNotice {
                var tip = pendingTip
                if tip == nil, details?.modeName != nil, details?.isCommand == false {
                    tip = takeTip("modes", mode: details?.modeName)
                }
                if tip == nil, historyManager.entries.count >= 5 {
                    let words = historyManager.entries.reduce(0) { $0 + historyManager.wordCount(for: $1.text) }
                    if words >= 500 { tip = takeTip("words500") }
                }
                pendingTip = nil
                if let tip {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard dictationFeedback.generation == feedbackGeneration else { return }
                    showNotice(tip, seconds: 5)
                }
            }

            // L2: watch for a hand fix of what was just pasted (not Command edits or sent text).
            if outcome == .pasted, details?.isCommand != true, details?.sendKey == nil, settings.learnFromCorrections {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard recordingState == .idle, dictationFeedback.generation == feedbackGeneration else { return }
                CorrectionWatcher.shared.start(pasted: outgoing, target: target)
            }
        }
        return audioFileName != nil
    }

    // MARK: - Live Text (L1)

    @ObservationIgnored private var livePreviewTask: Task<Void, Never>?

    /// Every 1.5 s while recording, a quick pass over the last 10 s shows what's been heard so
    /// far. It uses the same loaded model (no extra memory), skips a beat whenever the model is
    /// busy, and is cancelled at key-up so the real transcription (which still reads the whole
    /// recording) waits at most ~0.15 s for it. Measured on an M4: see CLAUDE.md.
    @MainActor
    private func startLivePreview() {
        stopLivePreview()
        guard recordingService.capturesLiveAudio, let operation = dictationOperation else { return }
        livePreviewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.recordingState == .recording else { return }
                let samples = self.recordingService.liveAudio()
                guard let text = await self.transcriptionManager.previewTranscribe(samples, engineID: operation.engineID),
                      !Task.isCancelled, self.recordingState == .recording else { continue }
                self.notchCapsuleWindow?.setLiveText(text.isEmpty ? nil : text)
            }
        }
    }

    @MainActor
    private func stopLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        notchCapsuleWindow?.setLiveText(nil)
    }

    // MARK: - Coding Agent Relay (L6)

    @MainActor
    private func handleAgentRequest(_ request: AgentRelay.Request) {
        let who = request.agent.displayName
        switch request.event {
        case .notification:
            // Attention only: permissions and questions are answered in the terminal.
            if settings.soundEffectsEnabled { NSSound(named: "Ping")?.play() }
            showNotice("⚠︎ \(who) needs you in \(request.project)", seconds: 5)
        case .stop:
            pendingAgentRequest = request
            if settings.soundEffectsEnabled { NSSound(named: "Ping")?.play() }
            showAgentPrompt(request)
        }
    }

    @MainActor
    private func showAgentPrompt(_ request: AgentRelay.Request) {
        // Mid-dictation it isn't shown; sotto://agent/reply still answers until the timeout.
        guard recordingState == .idle else { return }
        let remaining = request.expiresAt.timeIntervalSinceNow
        guard remaining > 1 else { return }
        showPrompt(CapsulePrompt(
            icon: "terminal",
            iconColor: Color(red: 0x4F / 255, green: 0xD1 / 255, blue: 0xC5 / 255),
            text: "\(request.agent.displayName) finished in \(request.project)",
            actions: [
                .init(title: "Reply") { [weak self] in Task { @MainActor in self?.replyToAgent() } },
                .init(title: "Skip", isPrimary: false) { [weak self] in
                    Task { @MainActor in
                        AgentRelayService.shared.reply(to: request, text: nil)
                        self?.pendingAgentRequest = nil
                        self?.dismissPrompt()
                    }
                },
            ]
        ), seconds: min(remaining, 60))
    }

    /// Starts a recording whose text goes to the waiting agent. Stop it with a tap of the
    /// dictation key (or ESC to cancel).
    @MainActor
    func replyToAgent() {
        guard recordingState == .idle else { return NSSound.beep() }
        guard let request = pendingAgentRequest, AgentRelayService.shared.isWaiting(request) else {
            pendingAgentRequest = nil
            showNotice("⚠︎ No agent is waiting for a reply")
            return
        }
        dismissPrompt()
        startsAgentReply = true
        Task { await startRecording() }
    }

    @MainActor
    private func deliverAgentReply(_ request: AgentRelay.Request, details: DictationDetails) {
        agentReplyRequest = nil
        guard let text = lastTranscription else { return }
        processingStatus = ""
        let waiting = AgentRelayService.shared.isWaiting(request)
        if waiting {
            AgentRelayService.shared.reply(to: request, text: text)
        }
        historyManager.addEntry(TranscriptionEntry(
            id: UUID(),
            text: text,
            duration: details.record,
            sourceApp: request.agent.displayName,
            windowTitle: request.project,
            sourceWebsite: nil,
            outputMethod: waiting ? .agentReply : .notPasted,
            transcriptionMode: .local,
            rawText: details.rawText,
            cleanedText: details.cleanedText,
            modeName: details.modeName,
            timings: TranscriptionEntry.StageTimings(record: details.record, transcribe: details.transcribe, cleanup: details.cleanup, paste: 0)
        ))
        showErrorBrieflyThenHide(waiting ? "✓ Sent to \(request.agent.displayName)" : "⚠︎ \(request.agent.displayName) stopped waiting — reply saved in Transcripts", seconds: 3)
        if settings.soundEffectsEnabled { NSSound(named: "Glass")?.play() }
        recordingState = .idle
        hotkeyManager.setRecordingState(false)
    }

    // MARK: - Scratchpad (L7)

    @MainActor
    func openScratchpad() {
        ScratchpadWindowController.shared.show()
    }

    /// The Scratchpad shortcut and its Dictate button: opens the Scratchpad and dictates into
    /// the selected note (or a new one); pressed again, stops.
    @MainActor
    func toggleScratchpadDictation() {
        switch recordingState {
        case .recording where scratchpadNoteID != nil:
            Task { await stopRecording() }
        case .idle:
            ScratchpadWindowController.shared.show()
            startsInScratchpad = true
            Task { await startRecording() }
        default:
            NSSound.beep()
        }
    }

    /// Adds the dictation to its note and saves it to history; nothing is pasted anywhere.
    @MainActor
    private func deliverToScratchpad(_ noteID: UUID, details: DictationDetails, audioURL: URL?) -> Bool {
        scratchpadNoteID = nil
        guard let text = lastTranscription else { return false }
        processingStatus = ""
        let entryID = UUID()
        var audioFileName: String?
        if let audioURL, settings.audioRetention != .off {
            let fileName = AudioArchive.fileName(for: entryID)
            AudioArchive.archive(wav: audioURL, as: fileName)
            audioFileName = fileName
        }
        let noteSaved = NotesManager.shared.append(text, to: noteID)
        dictationFeedback.complete(noteSaved ? .scratchpadSaved : .scratchpadUnsaved, for: dictationFeedback.generation)
        historyManager.addEntry(TranscriptionEntry(
            id: entryID,
            text: text,
            duration: details.record,
            sourceApp: "Scratchpad",
            windowTitle: nil,
            sourceWebsite: nil,
            outputMethod: .scratchpad,
            transcriptionMode: .local,
            rawText: details.rawText,
            cleanedText: details.cleanedText,
            modeName: details.modeName,
            timings: TranscriptionEntry.StageTimings(record: details.record, transcribe: details.transcribe, cleanup: details.cleanup, paste: 0),
            audioFileName: audioFileName
        ))
        Self.logger.notice("dictation saved to scratchpad chars=\(text.count, privacy: .public)")
        if let notice = pendingNotice {
            showErrorBrieflyThenHide(notice, seconds: 4)
        } else {
            hideRecordingUI()
        }
        pendingNotice = nil
        if settings.soundEffectsEnabled {
            NSSound(named: "Glass")?.play()
        }
        recordingState = .idle
        hotkeyManager.setRecordingState(false)
        return audioFileName != nil
    }

    // MARK: - Command Mode (N1)

    /// Command key down: needs Apple Intelligence and a selection, then records the instruction.
    @MainActor
    private func startCommand() async {
        guard recordingState == .idle, settings.commandModeEnabled else { return }
        guard LLMService.foundationModelsAvailable else {
            showNotice("⚠︎ Command mode needs Apple Intelligence")
            return
        }
        let focused = CursorPositionService.focusedText(limit: 0)
        let selection = focused?.selected?.trimmingCharacters(in: .whitespacesAndNewlines)
        if focused != nil, selection?.isEmpty ?? true {
            showNotice("⚠︎ Select text first, then hold the Command key", seconds: 3)
            return
        }
        commandContext = CommandContext(selection: focused?.selected)
        await startRecording()
        guard recordingState == .recording else {
            commandContext = nil
            return
        }
        notchCapsuleWindow?.setModeName("Command")
        floatingWindow?.setModeName("Command")
        Self.logger.notice("command mode recording selection=\(focused?.selected?.count ?? -1, privacy: .public)")
    }

    /// Command key up: a quick tap is dropped; otherwise the instruction is processed.
    @MainActor
    private func stopCommand() async {
        guard commandContext != nil, recordingState == .recording else { return }
        if let start = recordingStartTime, Date().timeIntervalSince(start) < HotkeyGestureClassifier.minimumRecording {
            discardRecording()
            return
        }
        await stopRecording()
    }

    /// Applies the spoken instruction to the selection and pastes the result over it.
    /// Returns true when the recording was handed to AudioArchive.
    @MainActor
    private func runCommand(instruction: String, command: CommandContext, audioURL: URL, transcribeTime: TimeInterval) async -> Bool {
        setProcessingStatus("Editing…")
        var selection = command.selection
        if selection == nil {
            await Self.waitForModifierKeysReleased()
            selection = await outputService.copySelection(from: sourceApp)
        }
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishCommand(error: "⚠︎ No text was selected")
            return false
        }
        let editStart = Date()
        do {
            let edited = try await llmService.applyCommand(instruction, to: selection)
            lastTranscription = edited
            setProcessingStatus("Pasting…")
            let details = DictationDetails(
                rawText: selection,
                cleanedText: edited,
                modeName: "Command · \(instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))",
                record: recordDuration ?? 0,
                transcribe: transcribeTime,
                cleanup: Date().timeIntervalSince(editStart),
                sendKey: nil,
                isCommand: true
            )
            return performPaste(details: details, audioURL: audioURL)
        } catch {
            Self.logger.notice("command failed: \(error.localizedDescription, privacy: .public)")
            finishCommand(error: "⚠︎ Couldn't apply that edit")
            return false
        }
    }

    @MainActor
    private func finishCommand(error message: String) {
        if settings.soundEffectsEnabled {
            NSSound(named: "Basso")?.play()
        }
        recordingState = .idle
        processingStatus = ""
        hotkeyManager.setRecordingState(false)
        showErrorBrieflyThenHide(message, seconds: 3)
    }

    // MARK: - Tips and Long Recordings (N7)

    /// The tip's text if tips are on and it hasn't been shown yet; marks it shown.
    @MainActor
    private func takeTip(_ id: String, mode: String? = nil) -> String? {
        guard settings.tipsEnabled, !settings.shownTips.contains(id) else { return nil }
        let text: String
        switch id {
        case "backtrack": text = "💡 “Scratch that” drops a sentence; “3 pm, actually 4 pm” keeps the fix"
        case "formatting": text = "💡 Say “new line”, “bullet point”, or “one…, two…” to format as you speak"
        case "modes":
            let key = settings.modeCycleKey.map { "Tap \($0.displayName)" } ?? "Turn on the mode key"
            text = "💡 Used the \(mode ?? "App") mode. \(key) while recording to switch"
        case "pasteLast": text = "💡 Pasted your last transcript again; your clipboard was restored"
        case "words500": text = "💡 500 words dictated! Double-tap your shortcut for hands-free"
        default: return nil
        }
        settings.shownTips.insert(id)
        return text
    }

    /// Warns a minute before the limit, then stops and transcribes (nothing is lost).
    @MainActor
    private func scheduleRecordingLimit() {
        recordingLimitTask?.cancel()
        let started = recordingStartTime
        recordingLimitTask = Task { @MainActor in
            let warnAfter = Self.maxRecordingDuration - Self.recordingWarningLead
            try? await Task.sleep(nanoseconds: UInt64(warnAfter * 1_000_000_000))
            guard !Task.isCancelled, recordingState == .recording, recordingStartTime == started else { return }
            Self.logger.notice("recording limit: one minute left")
            if settings.soundEffectsEnabled { NSSound(named: "Ping")?.play() }
            notchCapsuleWindow?.setModeName("⏱ Stops in 1 min")
            floatingWindow?.setModeName("⏱ Stops in 1 min")
            try? await Task.sleep(nanoseconds: UInt64(Self.recordingWarningLead * 1_000_000_000))
            guard !Task.isCancelled, recordingState == .recording, recordingStartTime == started else { return }
            Self.logger.notice("recording limit reached; stopping and transcribing")
            hotkeyManager.setRecordingState(false)
            await stopRecording()
        }
    }

    /// L10: English text for a Translate-to-English mode, plus the language cleanup should use.
    /// Whisper Large v3 Turbo translates poorly (tested: it drops sentences, leaves words
    /// untranslated, or returns nothing), so with Apple Intelligence the speech is transcribed
    /// as spoken and the on-device model translates it; Whisper's translate task is the
    /// fallback, and the only option without Apple Intelligence.
    @MainActor
    private func transcribeToEnglish(_ url: URL, duration: TimeInterval, engineID: SpeechEngineID) async throws -> (text: String, language: String?) {
        let transcript = try await transcribeAudio(url, duration: duration, translate: !LLMService.foundationModelsAvailable, engineID: engineID)
        if LLMService.isEnglish(transcript) { return (transcript, "en") }
        if LLMService.foundationModelsAvailable {
            setProcessingStatus("Translating…")
            if let translated = await llmService.translateToEnglish(transcript) {
                return (translated, "en")
            }
            try Task.checkCancellation()
            setProcessingStatus("Translating…")
            let whisper = try await transcribeAudio(url, duration: duration, translate: true, engineID: .whisper)
            if LLMService.isEnglish(whisper), !whisper.isEmpty { return (whisper, "en") }
        }
        Self.logger.notice("translate to English failed; pasting as spoken")
        pendingNotice = "⚠︎ Couldn't translate — pasted as spoken"
        return (transcript, transcriptionManager.lastLanguage)
    }

    /// Short recordings go to the model in one call; long ones (and imports) in 60 s chunks,
    /// so no single call hits the per-transcription timeout.
    @MainActor
    private func transcribeAudio(_ url: URL, duration: TimeInterval, translate: Bool = false, engineID: SpeechEngineID) async throws -> String {
        guard duration > Self.chunkedTranscriptionThreshold else {
            return try await transcriptionManager.transcribe(audioURL: url, translate: translate, engineID: engineID)
        }
        Self.logger.notice("long recording (\(Int(duration), privacy: .public)s): transcribing in chunks")
        return try await FileTranscriber.transcribe(url, progress: { [weak self] fraction in
            guard let self, self.recordingState == .processing else { return }
            self.setProcessingStatus("Transcribing… \(Int(fraction * 100))%")
        }, transcribeChunk: { [weak self] chunk in
            guard let self else { throw CancellationError() }
            return try await self.transcriptionManager.transcribe(audioURL: chunk, translate: translate, engineID: engineID)
        }).text
    }

    // MARK: - Links and Shortcuts (N15)

    /// sotto://record/start|stop|toggle, sotto://mode/<name>, sotto://paste-last,
    /// sotto://copy-last, sotto://settings. Local actions only; nothing is fetched.
    @MainActor
    func handleURL(_ url: URL) {
        let action = url.host?.lowercased() ?? ""
        let rest = url.pathComponents.filter { $0 != "/" }
        Self.logger.notice("link action=\(action, privacy: .public) \(rest.first ?? "", privacy: .public)")
        switch action {
        case "record":
            switch rest.first?.lowercased() {
            case "start": startDictationFromAutomation()
            case "stop": stopDictationFromAutomation()
            default: toggleRecording()
            }
        case "mode":
            selectMode(named: rest.joined(separator: "/"))
        case "paste-last":
            pasteLastTranscript(fromMenu: false)
        case "copy-last":
            copyLastTranscript()
        case "read-last":
            readLastTranscript()
        case "scratchpad":
            openScratchpad()
        case "agent":
            // sotto://agent/reply: dictate the reply to the agent that's waiting.
            if rest.first?.lowercased() == "reply" { replyToAgent() } else { showNotice("⚠︎ Unknown sotto:// link") }
        case "settings":
            WindowManager.shared.openAppropriateWindow()
        default:
            showNotice("⚠︎ Unknown sotto:// link")
        }
    }

    @MainActor
    func startDictationFromAutomation() {
        guard recordingState == .idle else { return }
        Task { @MainActor in await startRecording() }
    }

    @MainActor
    func stopDictationFromAutomation() {
        guard recordingState == .recording else { return }
        Task { @MainActor in await stopRecording() }
    }

    /// Mode names for Shortcuts' "Switch Mode" picker.
    var modeNames: [String] { recleanChoices.map(\.label) }

    /// While recording: this dictation's mode. Otherwise: the next dictation's.
    @MainActor
    @discardableResult
    func selectMode(named name: String) -> Bool {
        guard let choice = recleanChoices.first(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) else {
            showNotice("⚠︎ No mode named “\(name)”")
            return false
        }
        if recordingState == .recording {
            modeChoice = choice
            modeChosenManually = true
            showModeLabel()
        } else {
            nextModeChoice = choice
            showNotice("✓ Next dictation: \(choice.label)")
        }
        return true
    }

    // MARK: - File Import (N13)

    struct FileImport {
        let fileName: String
        var progress: Double
        var queued: Int
    }

    /// The file being transcribed, for the progress bar in the main window.
    private(set) var fileImport: FileImport?
    @ObservationIgnored private var importQueue: [URL] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?

    /// Queues audio/video files to be transcribed into history (not pasted).
    @MainActor
    func importFiles(_ urls: [URL]) {
        let files = urls.filter(FileTranscriber.canImport)
        guard !files.isEmpty else {
            if !urls.isEmpty { showNotice("⚠︎ Sotto can import audio or video files") }
            return
        }
        importQueue.append(contentsOf: files)
        fileImport?.queued = importQueue.count
        guard importTask == nil else { return }
        importTask = Task { @MainActor in
            while !importQueue.isEmpty, !Task.isCancelled {
                await transcribeFile(importQueue.removeFirst())
            }
            fileImport = nil
            importTask = nil
        }
    }

    @MainActor
    func cancelImport() {
        importQueue.removeAll()
        importTask?.cancel()
    }

    @MainActor
    private func transcribeFile(_ url: URL) async {
        let operation = transcriptionManager.beginOperation()
        defer { transcriptionManager.endOperation(operation) }
        let name = url.lastPathComponent
        fileImport = FileImport(fileName: name, progress: 0, queued: importQueue.count)
        Self.logger.notice("importing a file ext=\(url.pathExtension, privacy: .public)")
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let start = Date()
        do {
            let result = try await FileTranscriber.transcribe(url, progress: { [weak self] fraction in
                self?.fileImport?.progress = fraction
            }, transcribeChunk: { [weak self] chunk in
                guard let self else { throw CancellationError() }
                // A dictation goes first; the model only runs one transcription at a time.
                while self.recordingState != .idle {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                return try await self.transcriptionManager.transcribe(audioURL: chunk, engineID: operation.engineID)
            })
            try Task.checkCancellation()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                showNotice("⚠︎ No speech found in “\(name)”", seconds: 3)
                return
            }
            historyManager.addEntry(TranscriptionEntry(
                text: text,
                duration: result.duration,
                sourceApp: "Imported file",
                windowTitle: name,
                outputMethod: .imported,
                transcriptionMode: .local,
                rawText: text,
                timings: TranscriptionEntry.StageTimings(record: result.duration, transcribe: Date().timeIntervalSince(start), cleanup: nil, paste: 0)
            ))
            showNotice("✓ Transcribed “\(name)” — see Transcripts", seconds: 3)
        } catch is CancellationError {
            Self.logger.notice("import cancelled")
        } catch {
            Self.logger.error("import failed: \(error.localizedDescription, privacy: .public)")
            showNotice("⚠︎ Couldn't transcribe “\(name)”", seconds: 3)
        }
    }

    // MARK: - Re-transcribe / Re-clean from History (N2)

    /// The history entry being re-processed, for the Transcripts view's spinner.
    private(set) var reprocessingEntryID: UUID?

    /// Modes offered by "Re-clean with": Default, Raw, and every enabled mode.
    var recleanChoices: [ModeChoice] {
        let aiAvailable = LLMService.foundationModelsAvailable
        return [.defaults, .raw] + settings.appModes
            .filter { $0.isEnabled && (aiAvailable || !$0.requiresAppleIntelligence) }
            .map(ModeChoice.mode)
    }

    /// Transcribes the entry's kept audio again with the current model, then cleans it with its
    /// mode (or the defaults). Also how failed dictations are retried. Nothing is pasted.
    @MainActor
    func retranscribe(_ entry: TranscriptionEntry) async {
        guard reprocessingEntryID == nil, recordingState == .idle, let audio = entry.existingAudioURL else { return }
        reprocessingEntryID = entry.id
        let operation = transcriptionManager.beginOperation()
        defer { transcriptionManager.endOperation(operation) }
        defer { reprocessingEntryID = nil }
        let start = Date()
        do {
            let choice = entry.modeName.flatMap { name in settings.appModes.first { $0.displayName == name } }
                .map(ModeChoice.mode) ?? .defaults
            // L10: a Translate-to-English mode translates again (its notice is for live dictations).
            let transcript = choice.appMode?.translateToEnglish == true
                ? try await transcribeToEnglish(audio, duration: entry.duration, engineID: operation.engineID).text
                : try await transcribeAudio(audio, duration: entry.duration, engineID: operation.engineID)
            try Task.checkCancellation()
            pendingNotice = nil
            let transcribeTime = Date().timeIntervalSince(start)
            let result = await cleanForHistory(transcript, choice: choice)
            historyManager.replaceResult(
                for: entry.id,
                text: result.text,
                rawText: result.raw,
                cleanedText: result.cleaned,
                modeName: result.modeName,
                timings: TranscriptionEntry.StageTimings(record: entry.duration, transcribe: transcribeTime, cleanup: result.cleanupTime, paste: 0),
                reason: "Re-transcribed"
            )
            Self.logger.notice("re-transcribed history entry chars=\(result.text.count, privacy: .public)")
        } catch {
            Self.logger.error("re-transcribe failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    /// Cleans the entry's raw text again with the chosen mode. Nothing is pasted.
    @MainActor
    func reclean(_ entry: TranscriptionEntry, with choice: ModeChoice) async {
        guard reprocessingEntryID == nil else { return }
        let source = entry.rawText ?? entry.text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        reprocessingEntryID = entry.id
        defer { reprocessingEntryID = nil }
        let result = await cleanForHistory(source, choice: choice)
        historyManager.replaceResult(
            for: entry.id,
            text: result.text,
            rawText: result.raw,
            cleanedText: result.cleaned,
            modeName: result.modeName,
            timings: nil,
            reason: "Re-cleaned (\(choice.label))"
        )
    }

    /// Vocabulary rules, then cleanup with `choice` (unless Raw, AI Enhancement is off, or it's
    /// only snippets). Same steps as a live dictation, minus screen/selection context.
    @MainActor
    private func cleanForHistory(_ transcript: String, choice: ModeChoice) async
        -> (text: String, raw: String, cleaned: String?, modeName: String?, cleanupTime: TimeInterval?) {
        let prepared = DictationTextRules.prepare(transcript, snippets: settings.snippets, voiceCommands: settings.voiceCommandsEnabled)
        let raw = prepared.expand(prepared.text)
        guard settings.enableLLMProcessing, !choice.skipsCleanup, !prepared.isOnlySnippets else {
            return (raw, raw, nil, choice == .defaults ? nil : choice.label, nil)
        }
        let start = Date()
        guard let cleaned = try? await llmService.processText(prepared.text, mode: choice.appMode, protectedTokens: prepared.tokens) else {
            return (raw, raw, nil, nil, nil)
        }
        let text = prepared.expand(cleaned)
        return (text, raw, text, choice.appMode?.displayName, Date().timeIntervalSince(start))
    }

    // MARK: - Mode While Recording (N4)

    private func showModeLabel() {
        notchCapsuleWindow?.setModeName(modeChoice.label)
        floatingWindow?.setModeName(modeChoice.label)
    }

    /// Default → Raw → each enabled mode → back to Default. This dictation only.
    @MainActor
    private func cycleMode() {
        guard recordingState == .recording else { return }
        let aiAvailable = LLMService.foundationModelsAvailable
        let choices: [ModeChoice] = [.defaults, .raw] + settings.appModes
            .filter { $0.isEnabled && (aiAvailable || !$0.requiresAppleIntelligence) }
            .map(ModeChoice.mode)
        let current = choices.firstIndex { choice in
            switch (choice, modeChoice) {
            case (.mode(let a), .mode(let b)): return a.id == b.id
            default: return choice == modeChoice
            }
        } ?? -1
        modeChoice = choices[(current + 1) % choices.count]
        modeChosenManually = true
        Self.logger.notice("mode switched while recording to \(self.modeChoice.label, privacy: .public)")
        showModeLabel()
    }

    // MARK: - Context

    /// Q11: selected text (and whether something was just copied) when recording starts. Only
    /// read when AI Enhancement is on, since only cleanup uses it; never read from password fields.
    @MainActor
    private func captureStartContext() {
        selectionContext = nil
        guard settings.enableLLMProcessing, settings.useSelectionAndClipboardContext else { return }
        let selected = CursorPositionService.focusedText(limit: 0)?.selected?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let selected, !selected.isEmpty {
            selectionContext = String(selected.prefix(1000))
        }
        let recentlyCopied = ClipboardWatcher.shared.textCopied(
            since: Date().addingTimeInterval(-Self.clipboardContextWindow)
        ) != nil
        if selectionContext != nil || recentlyCopied {
            notchCapsuleWindow?.setContextCaptured(true)
        }
        Self.logger.notice("start context selected=\(self.selectionContext?.count ?? 0, privacy: .public) recentlyCopied=\(recentlyCopied, privacy: .public)")
    }

    /// Q10: casing, spacing, and trailing period to suit the text around the cursor. Only when
    /// auto-pasting into the app the dictation was for; unchanged if AX can't read the field.
    @MainActor
    private func fittedToCaret(_ text: String, target: NSRunningApplication?) -> String {
        guard settings.matchCaretFormatting,
              settings.outputMode == .autoPaste,
              let target,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let caret = CursorPositionService.focusedText() else { return text }
        let keepCapitalized = Set(
            settings.vocabularyList + settings.replacements.flatMap { $0.written.split(separator: " ").map(String.init) }
        )
        let fitted = DictationTextRules.adaptToCaret(text, before: caret.before, after: caret.after, keepCapitalized: keepCapitalized)
        if fitted != text {
            Self.logger.notice("fitted to caret before=\(caret.before?.count ?? -1, privacy: .public) after=\(caret.after?.count ?? -1, privacy: .public)")
        }
        return fitted
    }

    // MARK: - Audio Level Updates

    private func startAudioLevelUpdates() {
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let level = self.recordingService.audioLevel
            Task { @MainActor in
                self.audioLevel = level
                // Update whichever UI is active
                self.notchCapsuleWindow?.updateAudioLevel(level)
                self.floatingWindow?.updateAudioLevel(level)
            }
        }
    }

    private func stopAudioLevelUpdates() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        audioLevel = 0
    }

    // MARK: - Cancel Recording (ESC key)

    /// A lone tap of the hotkey, or a recording under 0.4 s: thrown away without a transcript,
    /// an error, or the cancel sound. Never touches a dictation that is already processing.
    @MainActor
    private func discardRecording() {
        guard recordingState == .recording else { return }
        Self.logger.notice("recording discarded (lone tap or too short)")
        cancelRecording(silently: true)
    }

    @MainActor
    func cancelRecording(silently: Bool = false) {
        guard recordingState == .recording || recordingState == .processing else { return }
        dictationFeedback.begin()
        dotTrackingTimer?.invalidate()
        dotTrackingTimer = nil
        stopLivePreview()
        if let operation = dictationOperation {
            transcriptionManager.endOperation(operation)
            dictationOperation = nil
        }
        commandContext = nil
        mediaPauser.resume()
        recordingLimitTask?.cancel()

        let recorded = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let keepForUndo = !silently && recordingState == .recording && recorded >= Self.undoableCancelDuration
        // Undo of a Scratchpad recording still goes into its note.
        if !keepForUndo { scratchpadNoteID = nil }

        // Cancel in-flight stop→transcribe→paste work
        processingTask?.cancel()
        processingTask = nil
        currentPipelineID = nil
        stopStatusPolling()

        // Remove ESC monitor
        removeEscMonitor()

        // Stop audio level updates
        stopAudioLevelUpdates()

        // Stop recording (no tail) without transcribing. A long recording's audio is kept for
        // Undo; everything else is deleted now.
        let url = recordingService.stopRecording()
        recordingService.reset()

        if keepForUndo, let url {
            recordDuration = recorded
            cursorIndicatorWindow?.hide()
            floatingWindow?.hide()
            offerUndo(for: url)
        } else {
            if let url {
                recordingService.cleanup(url: url)
            }
            hideRecordingUI()
        }
        recordingState = .idle
        processingStatus = ""
        hotkeyManager.setRecordingState(false)

        // Play cancel sound
        if settings.soundEffectsEnabled, !silently {
            NSSound(named: "Funk")?.play()
        }
    }

    // MARK: - Undo Cancel

    /// Shows "Cancelled · Undo" in the capsule (whatever the indicator style) for a few seconds.
    @MainActor
    private func offerUndo(for url: URL) {
        dropPendingUndo(hideNotice: false)
        Self.logger.notice("long recording cancelled; offering undo for \(Int(Self.cancelUndoWindow), privacy: .public)s")
        if notchCapsuleWindow == nil {
            notchCapsuleWindow = NotchCapsuleWindow()
        }
        notchCapsuleWindow?.showUndo { [weak self] in
            Task { @MainActor in self?.undoCancel() }
        }
        let expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.cancelUndoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dropPendingUndo(hideNotice: true)
        }
        pendingUndo = (url, expiry)
    }

    /// Deletes the kept audio. Called when the Undo window expires or a new recording starts.
    @MainActor
    private func dropPendingUndo(hideNotice: Bool) {
        guard let pending = pendingUndo else { return }
        pendingUndo = nil
        pending.expiry.cancel()
        recordingService.cleanup(url: pending.url)
        if hideNotice {
            notchCapsuleWindow?.hide()
        }
    }

    /// Transcribes and pastes the cancelled recording as if it had been stopped normally.
    @MainActor
    private func undoCancel() {
        guard recordingState == .idle, let pending = pendingUndo else { return }
        dictationFeedback.begin()
        lastError = nil
        pendingUndo = nil
        pending.expiry.cancel()
        Self.logger.notice("undo cancel: transcribing the kept recording")

        recordingState = .processing
        processingStatus = transcriptionManager.statusMessage
        notchCapsuleWindow?.setProcessing(true, status: processingStatus)
        startStatusPolling()

        let url = pending.url
        Task { @MainActor in
            await self.startPipeline { url }
        }
    }

    private func removeEscMonitor() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
        if let monitor = escLocalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escLocalKeyMonitor = nil
        }
    }
}
