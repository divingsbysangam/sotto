import SwiftUI
import AppKit
import Carbon.HIToolbox

// Observable class to manage recording state safely
@MainActor
@Observable
class ShortcutRecorder {
    var isRecording = false
    var keyCode: UInt32 = 49
    var modifiers: UInt = 0
    var onShortcutCaptured: ((UInt32, UInt) -> Void)?
    /// When set, a lone press of one of these modifiers is captured as the shortcut (N3).
    var capturableModifiers: [ModifierKey] = []
    var onModifierCaptured: ((ModifierKey) -> Void)?

    private var eventMonitor: Any?
    private var flagsMonitor: Any?
    /// A capturable modifier went down alone; captured if it comes back up with no key between.
    private var pendingModifier: ModifierKey?

    func startRecording() {
        isRecording = true
        pendingModifier = nil

        if !capturableModifiers.isEmpty {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let key = ModifierKey(keyCode: Int(event.keyCode))
                let isDown = key.map { UInt64(event.modifierFlags.rawValue) & $0.deviceFlag != 0 } ?? false
                let alone = key.map {
                    event.modifierFlags.intersection([.command, .option, .shift, .control, .function])
                        .subtracting(NSEvent.ModifierFlags(rawValue: UInt($0.genericFlag.rawValue))).isEmpty
                } ?? false
                Task { @MainActor in
                    guard let key, self.capturableModifiers.contains(key) else {
                        self.pendingModifier = nil
                        return
                    }
                    if isDown {
                        self.pendingModifier = alone ? key : nil
                    } else if self.pendingModifier == key {
                        NSLog("[ShortcutRecorder] Captured lone modifier %@", key.rawValue)
                        self.onModifierCaptured?(key)
                        self.stopRecording()
                    }
                }
                return event
            }
        }

        // Use local event monitor to capture key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            Task { @MainActor in self.pendingModifier = nil }

            let newKeyCode = UInt32(event.keyCode)
            let newModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])

            // Escape cancels recording
            if newKeyCode == UInt32(kVK_Escape) && newModifiers.isEmpty {
                Task { @MainActor in
                    self.stopRecording()
                }
                return nil
            }

            // Require at least one modifier for non-function keys
            // Note: Carbon key codes for F-keys are NOT consecutive, so use a Set
            let functionKeys: Set<Int> = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
            ]
            let isFunctionKey = functionKeys.contains(Int(newKeyCode))
            if !isFunctionKey && newModifiers.isEmpty {
                // Ignore keys without modifiers
                return nil
            }

            Task { @MainActor in
                NSLog("[ShortcutRecorder] Captured: keyCode=%d, modifiers=%lu", newKeyCode, newModifiers.rawValue)
                self.keyCode = newKeyCode
                self.modifiers = newModifiers.rawValue
                self.onShortcutCaptured?(newKeyCode, newModifiers.rawValue)
                self.stopRecording()
            }

            return nil // Consume the event
        }
    }

    func stopRecording() {
        isRecording = false
        pendingModifier = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }
}

struct ShortcutRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt
    var defaultKeyCode = UInt32(kVK_Space)
    var defaultModifiers = NSEvent.ModifierFlags([.command, .shift]).rawValue
    /// Lets a lone modifier (Fn, right ⌥/⌘) be recorded as the shortcut; nil = key combos only.
    var modifierKey: Binding<ModifierKey?>? = nil
    var onShortcutChanged: (() -> Void)?

    @State private var recorder = ShortcutRecorder()

    var body: some View {
        HStack(spacing: 12) {
            // Display current shortcut
            Text(recorder.isRecording
                 ? (modifierKey == nil ? "Press shortcut..." : "Press a shortcut or Fn / right ⌥ / right ⌘…")
                 : (modifierKey?.wrappedValue?.displayName ?? shortcutDisplayName))
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .frame(minWidth: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(recorder.isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(recorder.isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )

            if recorder.isRecording {
                Button("Cancel") {
                    recorder.stopRecording()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Record Shortcut") {
                    recorder.onShortcutCaptured = { newKeyCode, newModifiers in
                        self.keyCode = newKeyCode
                        self.modifiers = newModifiers
                        self.modifierKey?.wrappedValue = nil
                        self.onShortcutChanged?()
                    }
                    recorder.capturableModifiers = modifierKey == nil ? [] : ModifierKey.dictationChoices
                    recorder.onModifierCaptured = { key in
                        self.modifierKey?.wrappedValue = key
                        self.onShortcutChanged?()
                    }
                    recorder.startRecording()
                }
                .buttonStyle(.bordered)
            }

            Button {
                keyCode = defaultKeyCode
                modifiers = defaultModifiers
                modifierKey?.wrappedValue = nil
                onShortcutChanged?()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default (\(AppSettings.shortcutDisplayName(keyCode: defaultKeyCode, modifiers: defaultModifiers)))")
        }
        .onDisappear {
            recorder.stopRecording()
        }
    }

    private var shortcutDisplayName: String {
        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(keyName(for: keyCode))

        return parts.joined(separator: " ")
    }

    private func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        default:
            // Try to get the character from the key code
            if let char = characterForKeyCode(keyCode) {
                return char.uppercased()
            }
            return "Key \(keyCode)"
        }
    }

    private func characterForKeyCode(_ keyCode: UInt32) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let error = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard error == noErr, length > 0 else {
            return nil
        }

        return String(utf16CodeUnits: chars, count: length)
    }
}

// MARK: - Helper to get key name from AppSettings
extension AppSettings {
    var hotkeyDisplayName: String {
        if let key = hotkeyModifierKey { return key.displayName }
        return Self.shortcutDisplayName(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    var pasteLastDisplayName: String {
        Self.shortcutDisplayName(keyCode: pasteLastKeyCode, modifiers: pasteLastModifiers)
    }

    var copyLastDisplayName: String {
        Self.shortcutDisplayName(keyCode: copyLastKeyCode, modifiers: copyLastModifiers)
    }

    var scratchpadDisplayName: String {
        Self.shortcutDisplayName(keyCode: scratchpadKeyCode, modifiers: scratchpadModifiers)
    }

    var readLastDisplayName: String {
        Self.shortcutDisplayName(keyCode: readLastKeyCode, modifiers: readLastModifiers)
    }

    static func shortcutDisplayName(keyCode: UInt32, modifiers: UInt) -> String {
        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(keyNameForCode(keyCode))

        return parts.joined(separator: " ")
    }

    private static func keyNameForCode(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            // Try to get character
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return "Key"
            }

            let dataRef = unsafeBitCast(layoutData, to: CFData.self)
            let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)

            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0

            let error = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            if error == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return "Key"
        }
    }
}
