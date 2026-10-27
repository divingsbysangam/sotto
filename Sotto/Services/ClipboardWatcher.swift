import AppKit

/// Notices when the user copies text, so text copied just before or during a dictation can
/// be given to cleanup as context. The pasteboard has no timestamps, so this polls
/// `changeCount` (cheap). Sotto's own writes and items marked concealed/transient (password
/// managers, nspasteboard.org) are ignored.
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastUserCopy: Date?
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Text the user copied at or after `since`, capped at `limit` characters.
    func textCopied(since: Date, limit: Int = 1000) -> String? {
        poll()
        guard let lastUserCopy, lastUserCopy >= since, !isPrivate(NSPasteboard.general) else { return nil }
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !OutputService.isOwnWrite(changeCount: count), !isPrivate(pasteboard) else { return }
        lastUserCopy = Date()
    }

    private func isPrivate(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(Self.concealedType) || types.contains(Self.transientType)
    }
}
