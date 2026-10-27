import AppKit
import Carbon.HIToolbox
import os

/// Reports presses of lone modifier keys (Fn, right ⌥/⌘/⇧/⌃) and of ⌃⌥ together, plus
/// "another key was pressed" so a modifier used in a shortcut or accent (right-⌥ e) isn't
/// mistaken for a lone press. The event tap runs on its own thread and passes every event on
/// unchanged at once, so typing can't be slowed by the main thread. Needs Accessibility.
final class ModifierKeyMonitor {
    enum Event {
        /// `alone`: no other modifier was held at the time (so it isn't part of a chord).
        case down(ModifierKey, alone: Bool)
        case up(ModifierKey)
        /// ⌃ and ⌥ held together with no other modifier: the fallback for keyboards without Fn.
        case controlOptionDown
        case controlOptionUp
        /// A non-modifier key went down (Space included, so callers can tell it apart).
        case keyDown(keyCode: Int)
        /// L12: the bound mouse button (`mouseButton`) went down / up. It isn't passed on.
        case mouseDown
        case mouseUp
    }

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "Hotkeys")

    /// Called on the main thread.
    var onEvent: ((Event) -> Void)?

    /// Read on the tap thread (to re-enable after a timeout) and written from main: locked.
    private var tap: CFMachPort? {
        get { tapLock.withLock { _tap } }
        set { tapLock.withLock { _tap = newValue } }
    }
    private var _tap: CFMachPort?
    private let tapLock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var controlOptionDown = false

    /// L12: the "other" mouse button (2 = middle, 3 = back, 4 = forward) that dictates. Read on the
    /// tap thread, which swallows its clicks so they don't also reach the app under the pointer.
    var mouseButton: Int? {
        get { mouseButtonLock.withLock { _mouseButton } }
        set { mouseButtonLock.withLock { _mouseButton = newValue } }
    }
    private var _mouseButton: Int?
    private let mouseButtonLock = NSLock()

    var isRunning: Bool { tap != nil }

    /// Safe to call repeatedly; retries if Accessibility was granted since the last attempt.
    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue) | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active (not listen-only): works with Accessibility alone, where a listen-only
            // keyboard tap would also need Input Monitoring. Events are always passed on unchanged.
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon,
                   Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event) {
                    return nil  // the bound mouse button: consumed
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Self.logger.error("modifier key tap unavailable (Accessibility or Input Monitoring not granted)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.divingsbysangam.sotto.modifier-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        Self.logger.notice("modifier key tap started")
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        self.thread = nil
        self.runLoop = nil
        controlOptionDown = false
    }

    /// Runs on the tap thread. Returns true to swallow the event (only the bound mouse button).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .otherMouseDown, .otherMouseUp:
            guard let button = mouseButton,
                  Int(event.getIntegerValueField(.mouseEventButtonNumber)) == button else { return false }
            deliver(type == .otherMouseDown ? .mouseDown : .mouseUp)
            return true
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                deliver(.keyDown(keyCode: keyCode))
            }
        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if let key = ModifierKey(keyCode: keyCode) {
                if flags.rawValue & key.deviceFlag != 0 {
                    let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
                    deliver(.down(key, alone: flags.intersection(all).subtracting(key.genericFlag).isEmpty))
                } else {
                    deliver(.up(key))
                }
            }
            // ⌃⌥ alone (either side), for keyboards without Fn.
            let others: CGEventFlags = [.maskCommand, .maskShift, .maskSecondaryFn]
            let bothDown = flags.contains(.maskControl) && flags.contains(.maskAlternate) && flags.intersection(others).isEmpty
            if bothDown != controlOptionDown {
                controlOptionDown = bothDown
                deliver(bothDown ? .controlOptionDown : .controlOptionUp)
            }
        default:
            break
        }
        return false
    }

    private func deliver(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
