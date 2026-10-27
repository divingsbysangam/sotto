import AppKit
import os

/// L2: after a paste, watches the stretch of text around it for up to 30 s. If the user fixes a
/// word by hand (and then pauses or moves on), it offers the fix for Vocabulary or Replacements.
/// Opt-in. Reads only ~40 characters either side of the paste, from the same field in the same
/// app; that text stays in memory for the watch and is never stored or logged.
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "CorrectionWatcher")
    static let watchDuration: TimeInterval = 30
    static let settleDelay: TimeInterval = 3
    private static let contextChars = 40
    static let maxPastedChars = 1000

    /// Called on the main thread with the fix to offer.
    var onSuggestion: ((DictationTextRules.Correction) -> Void)?

    private struct Watch {
        let pid: pid_t
        let element: AXUIElement
        let location: Int
        let length: Int
        let initialCount: Int
        let initialText: String
        let startedAt: Date
        var latestText: String
        var lastEditAt: Date?
    }

    private var watch: Watch?
    private var timer: Timer?

    /// Starts watching the focused field of `target`, whose caret is just after `pasted`.
    @MainActor
    func start(pasted: String, target: NSRunningApplication?) {
        stop()
        let settings = AppSettings.shared
        guard settings.learnFromCorrections, let target,
              pasted.count <= Self.maxPastedChars, pasted.split(whereSeparator: \.isWhitespace).count >= 3,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              let focused = CursorPositionService.focusedTextElement() else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused.element, &pid) == .success, pid == target.processIdentifier else { return }

        // AX ranges are UTF-16 offsets, like NSString.
        let pastedLength = (pasted as NSString).length
        let caretEnd = focused.caret.location + focused.caret.length
        let pasteStart = caretEnd - pastedLength
        guard pasteStart >= 0 else { return }
        let location = max(0, pasteStart - Self.contextChars)
        let end = min(focused.count, caretEnd + Self.contextChars)
        guard end > location,
              let text = CursorPositionService.string(in: focused.element, range: CFRange(location: location, length: end - location)),
              text.contains(pasted.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Self.logger.notice("not watching: pasted text not found at the caret")
            return
        }
        watch = Watch(pid: pid, element: focused.element, location: location, length: end - location,
                      initialCount: focused.count, initialText: text, startedAt: Date(), latestText: text)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Self.logger.notice("watching for corrections chars=\(pasted.count, privacy: .public)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }

    private func poll() {
        guard var current = watch else { return stop() }
        let now = Date()
        // Moved on to another app or field: judge what was edited so far.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.pid,
              let focused = CursorPositionService.focusedTextElement(), CFEqual(focused.element, current.element) else {
            return finish(current)
        }
        let delta = focused.count - current.initialCount
        let length = current.length + delta
        if length > 0, let text = CursorPositionService.string(in: current.element, range: CFRange(location: current.location, length: length)),
           text != current.latestText {
            current.latestText = text
            current.lastEditAt = now
            watch = current
        }
        if let lastEdit = current.lastEditAt, now.timeIntervalSince(lastEdit) >= Self.settleDelay {
            return finish(current)
        }
        if now.timeIntervalSince(current.startedAt) >= Self.watchDuration {
            finish(current)
        }
    }

    private func finish(_ watch: Watch) {
        stop()
        guard watch.lastEditAt != nil,
              let correction = DictationTextRules.correctionCandidate(before: watch.initialText, after: watch.latestText) else { return }
        let settings = AppSettings.shared
        let known = Set(settings.vocabularyList.map { $0.lowercased() })
        let replaced = Set(settings.replacements.map { $0.spoken.lowercased() })
        guard !known.contains(correction.corrected.lowercased()),
              !replaced.contains(correction.original.lowercased()),
              !settings.ignoredCorrections.contains(Self.key(correction)) else { return }
        Self.logger.notice("correction found single=\(correction.isSingleWord, privacy: .public)")
        onSuggestion?(correction)
    }

    static func key(_ correction: DictationTextRules.Correction) -> String {
        correction.original.lowercased() + "→" + correction.corrected
    }
}
