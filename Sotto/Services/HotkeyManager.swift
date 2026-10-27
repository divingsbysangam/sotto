import AppKit
import Carbon.HIToolbox
import HotKey
import os

final class HotkeyManager {
    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Hotkeys")

    private var hotKey: HotKey?
    private var onStart: (() -> Void)?
    private var onStop: (() -> Void)?
    private var onDiscard: (() -> Void)?
    private let settings = AppSettings.shared

    // "Paste last transcript" / "Copy last transcript"
    private var pasteLastHotKey: HotKey?
    private var copyLastHotKey: HotKey?
    private var onPasteLast: (() -> Void)?
    private var onCopyLast: (() -> Void)?

    /// Other keyDown-only shortcuts (L13 Read last, L7 Scratchpad). `shortcut` is read on every
    /// refresh so Settings changes apply; nil = not registered.
    private struct ExtraAction {
        let shortcut: () -> (keyCode: UInt32, modifiers: UInt)?
        let action: () -> Void
    }
    private var extraActions: [String: ExtraAction] = [:]
    private var extraActionHotKeys: [String: HotKey] = [:]

    // Lone modifiers (N3 dictation key, N4 mode cycling, N1 Command key).
    private let modifierMonitor = ModifierKeyMonitor()
    /// The dictation modifier (or its ⌃⌥ fallback) is physically down.
    private var dictationModifierHeld = false
    /// L12: the dictation mouse button is physically down.
    private var mouseButtonHeld = false
    /// Mode-cycle key went down alone at this time while recording; a tap if it comes back up
    /// quickly with no other key in between.
    private var cycleKeyDownAt: Date?
    private var isRecordingActive = false
    private var onCycleMode: (() -> Void)?

    // N1 Command mode: hold the Command shortcut, speak an edit, release.
    private var commandHotKey: HotKey?
    private var commandModifierHeld = false
    private var onCommandStart: (() -> Void)?
    private var onCommandStop: (() -> Void)?

    // Hold / double-tap / hold+Space all go through this one classifier.
    private var classifier = HotkeyGestureClassifier()
    private var doubleTapTimer: Timer?
    // Active while the hotkey is held, to catch (and swallow) Space.
    private var spaceTap: CFMachPort?

    init() {}

    func register(onStart: @escaping () -> Void, onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.onStart = onStart
        self.onStop = onStop
        self.onDiscard = onDiscard
        applyCurrentHotkey()
    }

    /// N4: tapping the mode-cycle key while recording.
    func registerModeCycling(_ onCycle: @escaping () -> Void) {
        onCycleMode = onCycle
        startModifierMonitorIfNeeded()
    }

    /// N1: the Command shortcut is pressed / released.
    func registerCommand(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        onCommandStart = onStart
        onCommandStop = onStop
        applyCommandHotkey()
    }

    func registerTranscriptActions(onPasteLast: @escaping () -> Void, onCopyLast: @escaping () -> Void) {
        self.onPasteLast = onPasteLast
        self.onCopyLast = onCopyLast
        applyTranscriptActionHotkeys()
    }

    /// Registers (or replaces) a named keyDown shortcut.
    func registerAction(_ name: String, shortcut: @escaping () -> (keyCode: UInt32, modifiers: UInt)?, action: @escaping () -> Void) {
        extraActions[name] = ExtraAction(shortcut: shortcut, action: action)
        applyExtraActionHotkeys()
    }

    func refreshHotkey() {
        applyCurrentHotkey()
        applyTranscriptActionHotkeys()
        applyCommandHotkey()
        applyExtraActionHotkeys()
    }

    /// AppState reports when recording really starts and ends, so recordings started from the
    /// menu can be stopped with a tap, and ESC/errors/finished dictations reset the gesture.
    func setRecordingState(_ recording: Bool) {
        isRecordingActive = recording
        cycleKeyDownAt = nil
        if recording {
            classifier.recordingStartedElsewhere()
        } else {
            classifier.reset()
        }
        syncTimerAndSpaceTap()
    }

    private func applyCurrentHotkey() {
        hotKey = nil
        dictationModifierHeld = false
        startModifierMonitorIfNeeded()

        if let modifierKey = settings.hotkeyModifierKey {
            Self.logger.notice("recording shortcut is the lone modifier \(modifierKey.rawValue, privacy: .public)")
            return
        }

        let keyCode = settings.hotkeyKeyCode
        let modifiers = NSEvent.ModifierFlags(rawValue: settings.hotkeyModifiers)
        guard let key = Key(carbonKeyCode: keyCode) else {
            Self.logger.error("invalid recording key code: \(keyCode, privacy: .public)")
            return
        }
        Self.logger.notice("registered recording shortcut \(AppSettings.shortcutDisplayName(keyCode: keyCode, modifiers: modifiers.rawValue), privacy: .public)")

        hotKey = HotKey(key: key, modifiers: modifiers)
        hotKey?.keyDownHandler = { [weak self] in
            guard let self else { return }
            self.handle(self.classifier.keyDown(), trigger: "key down")
        }
        hotKey?.keyUpHandler = { [weak self] in
            guard let self else { return }
            self.handle(self.classifier.keyUp(), trigger: "key up")
        }
    }

    // MARK: - Lone Modifiers

    /// The tap is needed for a modifier dictation/Command key and for mode cycling. Retried on
    /// every refresh in case Accessibility was granted since launch.
    private func startModifierMonitorIfNeeded() {
        modifierMonitor.mouseButton = settings.dictationMouseButton
        let needed = settings.hotkeyModifierKey != nil || settings.modeCycleKey != nil
            || (settings.commandModeEnabled && settings.commandModifierKey != nil)
            || settings.dictationMouseButton != nil
        guard needed else {
            modifierMonitor.stop()
            return
        }
        modifierMonitor.onEvent = { [weak self] event in self?.handleModifier(event) }
        modifierMonitor.start()
    }

    private func handleModifier(_ event: ModifierKeyMonitor.Event) {
        let dictationKey = settings.hotkeyModifierKey
        switch event {
        case .down(let key, let alone):
            if key == dictationKey, alone {
                dictationModifierDown()
            } else if key == settings.commandModifierKey, alone, !commandModifierHeld, settings.commandModeEnabled {
                commandModifierHeld = true
                onCommandStart?()
            } else if key == settings.modeCycleKey, alone, isRecordingActive {
                cycleKeyDownAt = Date()
            } else {
                cycleKeyDownAt = nil
            }
        case .up(let key):
            if key == dictationKey {
                dictationModifierUp()
            } else if key == settings.commandModifierKey, commandModifierHeld {
                commandModifierHeld = false
                onCommandStop?()
            } else if key == settings.modeCycleKey, let downAt = cycleKeyDownAt {
                cycleKeyDownAt = nil
                if isRecordingActive, Date().timeIntervalSince(downAt) < 0.5 {
                    Self.logger.notice("mode cycle key tapped")
                    onCycleMode?()
                }
            }
        case .controlOptionDown:
            // Keyboards without Fn: ⌃⌥ stands in for it.
            if dictationKey == .fn { dictationModifierDown() }
        case .controlOptionUp:
            if dictationKey == .fn { dictationModifierUp() }
        case .keyDown(let keyCode):
            cycleKeyDownAt = nil
            // A key pressed with the modifier held means it was a chord (right-⌥ e, Fn-Delete),
            // not dictation: drop the recording it started. Space is hold+Space (handled by the
            // Space tap).
            if dictationModifierHeld, keyCode != kVK_Space {
                handle(classifier.interrupted(), trigger: "chord")
            }
        case .mouseDown:
            guard !mouseButtonHeld else { return }
            mouseButtonHeld = true
            handle(classifier.keyDown(), trigger: "mouse down")
        case .mouseUp:
            guard mouseButtonHeld else { return }
            mouseButtonHeld = false
            // A click toggles hands-free; holding past 0.6 s is push-to-talk.
            handle(classifier.keyUp(lockingHandsFreeOnTap: true), trigger: "mouse up")
        }
    }

    private func dictationModifierDown() {
        guard !dictationModifierHeld else { return }
        dictationModifierHeld = true
        handle(classifier.keyDown(), trigger: "modifier down")
    }

    private func dictationModifierUp() {
        guard dictationModifierHeld else { return }
        dictationModifierHeld = false
        handle(classifier.keyUp(), trigger: "modifier up")
    }

    // MARK: - Command Mode Key (N1)

    private func applyCommandHotkey() {
        commandHotKey = nil
        commandModifierHeld = false
        startModifierMonitorIfNeeded()
        // Don't take the combo from other apps when Command mode can't run.
        guard onCommandStart != nil, settings.commandModeEnabled, settings.commandModifierKey == nil,
              LLMService.foundationModelsAvailable else { return }
        let keyCode = settings.commandKeyCode
        let flags = NSEvent.ModifierFlags(rawValue: settings.commandModifiers)
        guard let key = Key(carbonKeyCode: keyCode) else { return }
        if keyCode == settings.hotkeyKeyCode && flags == NSEvent.ModifierFlags(rawValue: settings.hotkeyModifiers) && settings.hotkeyModifierKey == nil {
            Self.logger.notice("command shortcut matches the recording shortcut; not registered")
            return
        }
        let hotKey = HotKey(key: key, modifiers: flags)
        hotKey.keyDownHandler = { [weak self] in
            guard let self, !self.commandModifierHeld else { return }
            self.commandModifierHeld = true
            self.onCommandStart?()
        }
        hotKey.keyUpHandler = { [weak self] in
            guard let self, self.commandModifierHeld else { return }
            self.commandModifierHeld = false
            self.onCommandStop?()
        }
        commandHotKey = hotKey
        Self.logger.notice("registered command shortcut \(AppSettings.shortcutDisplayName(keyCode: keyCode, modifiers: flags.rawValue), privacy: .public)")
    }

    // MARK: - Gestures

    private func handle(_ action: HotkeyGestureClassifier.Action?, trigger: String) {
        if let action {
            Self.logger.notice("\(trigger, privacy: .public) -> \(String(describing: action), privacy: .public)")
            switch action {
            case .start: onStart?()
            case .stop: onStop?()
            case .discard: onDiscard?()
            case .lockHandsFree: break
            }
        }
        syncTimerAndSpaceTap()
    }

    private func syncTimerAndSpaceTap() {
        if classifier.state == .awaitingSecondTap {
            if doubleTapTimer == nil {
                let timer = Timer(timeInterval: HotkeyGestureClassifier.doubleTapWindow, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.doubleTapTimer = nil
                    self.handle(self.classifier.doubleTapWindowExpired(), trigger: "no second tap")
                }
                // .common so it still fires while a menu is open.
                RunLoop.main.add(timer, forMode: .common)
                doubleTapTimer = timer
            }
        } else {
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
        }
        setSpaceTapEnabled(classifier.isKeyDown)
    }

    // MARK: - Space While Holding

    /// With a Space-based shortcut (e.g. ⌘⇧Space) Space is already down, so there's nothing to catch.
    private var shortcutUsesSpace: Bool {
        settings.hotkeyModifierKey == nil && settings.hotkeyKeyCode == UInt32(kVK_Space)
    }

    private func setSpaceTapEnabled(_ enabled: Bool) {
        if enabled, !shortcutUsesSpace {
            if spaceTap == nil {
                spaceTap = makeSpaceTap()
            }
            if let spaceTap {
                CGEvent.tapEnable(tap: spaceTap, enable: true)
            }
        } else if let spaceTap {
            CGEvent.tapEnable(tap: spaceTap, enable: false)
        }
    }

    /// HID level, so the Space is seen (and swallowed) before system shortcuts: with a ⌘-based
    /// shortcut it arrives as ⌘Space, which would otherwise open Spotlight. Needs Accessibility.
    private func makeSpaceTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleTappedEvent(type: type, event: event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (name, location) in [("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
            guard let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: refcon
            ) else { continue }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            Self.logger.notice("space tap created at \(name, privacy: .public) level")
            return tap
        }
        Self.logger.error("could not create space tap (Accessibility not granted?); hold+Space unavailable")
        return nil
    }

    /// Runs on the main run loop.
    private func handleTappedEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if classifier.isKeyDown, let spaceTap {
                CGEvent.tapEnable(tap: spaceTap, enable: true)
            }
        case .keyDown, .keyUp:
            guard classifier.isKeyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else { break }
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                handle(classifier.spacePressed(), trigger: "space")
            }
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Transcript Actions

    private func applyTranscriptActionHotkeys() {
        pasteLastHotKey = makeActionHotKey(
            name: "paste-last",
            keyCode: settings.pasteLastKeyCode,
            modifiers: settings.pasteLastModifiers
        ) { [weak self] in self?.onPasteLast?() }
        copyLastHotKey = makeActionHotKey(
            name: "copy-last",
            keyCode: settings.copyLastKeyCode,
            modifiers: settings.copyLastModifiers
        ) { [weak self] in self?.onCopyLast?() }
    }

    private func applyExtraActionHotkeys() {
        extraActionHotKeys = [:]
        for (name, extra) in extraActions {
            guard let shortcut = extra.shortcut() else { continue }
            extraActionHotKeys[name] = makeActionHotKey(name: name, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
                extra.action()
            }
        }
    }

    private func makeActionHotKey(name: String, keyCode: UInt32, modifiers: UInt, action: @escaping () -> Void) -> HotKey? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        guard let key = Key(carbonKeyCode: keyCode) else {
            Self.logger.error("invalid key code for \(name, privacy: .public): \(keyCode, privacy: .public)")
            return nil
        }
        // Same combo as the recording hotkey: keep recording working, skip this one.
        if keyCode == settings.hotkeyKeyCode && flags == NSEvent.ModifierFlags(rawValue: settings.hotkeyModifiers) {
            Self.logger.notice("\(name, privacy: .public) shortcut matches the recording shortcut; not registered")
            return nil
        }
        Self.logger.notice("registered \(name, privacy: .public) \(AppSettings.shortcutDisplayName(keyCode: keyCode, modifiers: modifiers), privacy: .public)")
        let hotKey = HotKey(key: key, modifiers: flags)
        hotKey.keyDownHandler = action
        return hotKey
    }

    // MARK: - Legacy Support

    func updateHotkey(_ option: HotkeyOption) {
        let (keyCode, modifiers) = keyAndModifiers(for: option)
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers.rawValue
        applyCurrentHotkey()
    }

    private func keyAndModifiers(for option: HotkeyOption) -> (UInt32, NSEvent.ModifierFlags) {
        switch option {
        case .cmdShiftSpace:
            return (UInt32(kVK_Space), [.command, .shift])
        case .cmdShiftD:
            return (UInt32(kVK_ANSI_D), [.command, .shift])
        case .cmdShiftR:
            return (UInt32(kVK_ANSI_R), [.command, .shift])
        case .optionSpace:
            return (UInt32(kVK_Space), [.option])
        case .ctrlShiftSpace:
            return (UInt32(kVK_Space), [.control, .shift])
        case .fnF5:
            return (UInt32(kVK_F5), [])
        }
    }

    func unregister() {
        hotKey = nil
        pasteLastHotKey = nil
        copyLastHotKey = nil
        onPasteLast = nil
        onCopyLast = nil
        extraActionHotKeys = [:]
        extraActions = [:]
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        if let spaceTap {
            CGEvent.tapEnable(tap: spaceTap, enable: false)
        }
        modifierMonitor.stop()
        commandHotKey = nil
        onStart = nil
        onStop = nil
        onDiscard = nil
    }
}
