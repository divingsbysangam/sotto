import AppKit
import Carbon.HIToolbox
import ApplicationServices

final class OutputService {
    private let settings: AppSettings
    private let pasteboard: NSPasteboard

    init(settings: AppSettings = .shared, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.pasteboard = pasteboard
    }

    enum Outcome: Equatable {
        case copied
        case pasted
        /// Auto-paste is on but Accessibility isn't granted, so the text was only copied.
        case copiedMissingAccessibility
        /// The frontmost app is no longer the one the text was meant for, so the text was only copied.
        case copiedAppChanged
        case copiedPasteFailed
        case failed
        case cancelled
    }

    /// Auto-paste sends Cmd-V, which needs Accessibility permission.
    var needsAccessibilityToPaste: Bool {
        settings.outputMode == .autoPaste && !AXIsProcessTrusted()
    }

    /// `target` is the app the text is meant for: Cmd-V is only sent while it's still frontmost,
    /// otherwise the text is left on the clipboard. `nil` pastes into whatever is frontmost.
    @discardableResult
    @MainActor
    func output(text: String, target: NSRunningApplication? = nil, shouldProceed: () -> Bool = { true }) async -> Outcome {
        guard shouldProceed() else { return .cancelled }
        NSLog("[OutputService] Output mode: %@, text length: %d", settings.outputMode.rawValue, text.count)

        switch settings.outputMode {
        case .clipboard:
            guard copyToClipboard(text) else { return .failed }
            NSLog("[OutputService] Copied to clipboard")
            return .copied
        case .autoPaste:
            return await autoPaste(text, target: target, shouldProceed: shouldProceed)
        }
    }

    /// Pastes into the frontmost app and then restores the user's clipboard, whatever the
    /// Output Mode setting. Used by "Paste last transcript".
    @MainActor
    func pasteRestoringClipboard(_ text: String, shouldProceed: () -> Bool = { true }) async -> Outcome {
        await autoPaste(text, shouldProceed: shouldProceed)
    }

    /// Change counts of Sotto's own pasteboard writes, so ClipboardWatcher can tell them from
    /// the user's copies. Main thread only.
    private static var ownChangeCounts: [Int] = []

    static func isOwnWrite(changeCount: Int) -> Bool {
        ownChangeCounts.contains(changeCount)
    }

    private static func noteOwnWrite(_ pasteboard: NSPasteboard) {
        ownChangeCounts.append(pasteboard.changeCount)
        if ownChangeCounts.count > 16 {
            ownChangeCounts.removeFirst()
        }
    }

    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        Self.noteOwnWrite(pasteboard)
        NSLog("[OutputService] Clipboard set success: %@", success ? "true" : "false")
        return success
    }

    // nspasteboard.org markers: clipboard managers skip items carrying these types.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // Long enough for the target app to read the pasteboard after Cmd-V.
    private static let restoreDelayNanoseconds: UInt64 = 400_000_000

    @MainActor
    private func autoPaste(_ text: String, target: NSRunningApplication? = nil, shouldProceed: () -> Bool = { true }) async -> Outcome {
        guard shouldProceed() else { return .cancelled }

        // Check accessibility permissions first
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        )

        // No modal alert: the caller shows a brief capsule notice, and Settings shows a banner.
        if !trusted {
            NSLog("[OutputService] Missing Accessibility permissions; copied to clipboard instead")
            return copyToClipboard(text) ? .copiedMissingAccessibility : .failed
        }

        if let target, !Self.isFrontmost(target) {
            NSLog("[OutputService] Frontmost app changed; copied to clipboard instead of pasting")
            return copyToClipboard(text) ? .copiedAppChanged : .failed
        }

        let snapshot = snapshotItems(of: pasteboard)
        guard writeTransient(text, to: pasteboard) else {
            restore(snapshot, to: pasteboard, ifChangeCountIs: pasteboard.changeCount)
            return .failed
        }
        let pastedChangeCount = pasteboard.changeCount

        // Small delay to ensure the target app is ready to receive input
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard shouldProceed(), !Task.isCancelled else {
            restore(snapshot, to: pasteboard, ifChangeCountIs: pastedChangeCount)
            return .cancelled
        }

        // The user may have switched apps during the delay. Replace the transient item with a
        // plain copy (so their own Cmd-V and clipboard managers see it) and skip the restore.
        if let target, !Self.isFrontmost(target) {
            NSLog("[OutputService] Frontmost app changed before Cmd-V; copied to clipboard instead of pasting")
            return copyToClipboard(text) ? .copiedAppChanged : .failed
        }

        guard simulatePasteViaAppleScript() else {
            return copyToClipboard(text) ? .copiedPasteFailed : .failed
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.restoreDelayNanoseconds)
            self.restore(snapshot, to: pasteboard, ifChangeCountIs: pastedChangeCount)
        }
        return .pasted
    }

    /// N1 fallback when Accessibility can't read the selection: ⌘C in the target app, read the
    /// text, then put the user's clipboard back. Nil if nothing was copied.
    @MainActor
    func copySelection(from target: NSRunningApplication?) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        if let target, !Self.isFrontmost(target) { return nil }
        let snapshot = snapshotItems(of: pasteboard)
        let before = pasteboard.changeCount
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        for _ in 0..<10 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        Self.noteOwnWrite(pasteboard)  // our ⌘C, not the user's copy
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !snapshot.isEmpty { pasteboard.writeObjects(snapshot) }
        Self.noteOwnWrite(pasteboard)
        return text
    }

    /// App Mode "Send after paste": presses Return or ⌘Return once the pasted text has landed,
    /// only if `target` is still frontmost. Returns whether the key was sent.
    @MainActor
    func pressSendKey(_ key: AppMode.SendKey, target: NSRunningApplication?) async -> Bool {
        // Let the app insert the pasted text first.
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let target, !Self.isFrontmost(target) {
            NSLog("[OutputService] Frontmost app changed; not sending %@", key.rawValue)
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = key == .commandReturn ? .maskCommand : []
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        NSLog("[OutputService] Sent %@ after paste", key.rawValue)
        return true
    }

    /// Same process (PID) and same app (bundle ID) as the frontmost application.
    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier == app.processIdentifier
            && front.bundleIdentifier == app.bundleIdentifier
    }

    /// Deep-copies every item and type so the snapshot survives `clearContents()`.
    @MainActor
    private func snapshotItems(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    @MainActor
    private func writeTransient(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        Self.noteOwnWrite(pasteboard)
        pasteboard.setData(Data(), forType: Self.transientType)
        pasteboard.setData(Data(), forType: Self.concealedType)
        NSLog("[OutputService] Transient clipboard set success: %@", success ? "true" : "false")
        return success
    }

    @MainActor
    private func restore(_ snapshot: [NSPasteboardItem], to pasteboard: NSPasteboard, ifChangeCountIs expected: Int) {
        guard pasteboard.changeCount == expected else {
            NSLog("[OutputService] Clipboard changed during paste; skipping restore")
            return
        }
        pasteboard.clearContents()
        if !snapshot.isEmpty {
            pasteboard.writeObjects(snapshot)
        }
        Self.noteOwnWrite(pasteboard)
        NSLog("[OutputService] Restored %d clipboard item(s)", snapshot.count)
    }

    private func simulatePasteViaAppleScript() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                NSLog("[OutputService] AppleScript paste error: %@", error)
                NSLog("[OutputService] Falling back to CGEvent method...")
                // Fallback to CGEvent method
                return simulatePasteViaCGEvent()
            } else {
                NSLog("[OutputService] AppleScript executed successfully, result: %@", result.stringValue ?? "nil")
                return true
            }
        } else {
            NSLog("[OutputService] Failed to create AppleScript")
            return simulatePasteViaCGEvent()
        }
    }

    private func simulatePasteViaCGEvent() -> Bool {
        NSLog("[OutputService] Using CGEvent method for paste...")

        // Create Cmd+V key event
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down for 'V' with Cmd modifier
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand

        // Key up for 'V' with Cmd modifier
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand

        // Post the events
        if keyDown != nil && keyUp != nil {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            NSLog("[OutputService] CGEvent paste posted successfully")
            return true
        } else {
            NSLog("[OutputService] Failed to create CGEvent - check Accessibility permissions")
            return false
        }
    }

    // Alternative: AppleScript-based paste (more reliable but slower)
    func autoPasteViaAppleScript(_ text: String) {
        copyToClipboard(text)

        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }
}
