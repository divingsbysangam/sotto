import AppKit
import os

/// One day of keyboard use: how many characters were typed and how long the typing took.
/// That's all that's ever stored: no text, no keys, no app names.
struct TypingDay: Codable, Equatable {
    var chars: Int = 0
    /// Time between keystrokes that were under `TypingStats.burstGap` apart.
    var activeMs: Int = 0
}

/// L15: pure math for the Dashboard's voice-vs-keyboard comparison.
enum TypingStats {
    /// Keystrokes further apart than this start a new burst (the pause isn't typing time).
    static let burstGap: TimeInterval = 2
    /// Below this much measured typing, the Dashboard keeps the 40 WPM estimate.
    static let minimumActiveMinutes: Double = 10
    /// Standard WPM counts 5 characters as a word.
    static let charsPerWord: Double = 5

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds one keystroke at `now` to `day`. `lastKeyAt` is the previous keystroke's time.
    static func record(into day: inout TypingDay, at now: Date, lastKeyAt: Date?) {
        day.chars += 1
        if let lastKeyAt {
            let gap = now.timeIntervalSince(lastKeyAt)
            if gap > 0, gap < burstGap {
                day.activeMs += Int((gap * 1000).rounded())
            }
        }
    }

    struct Summary: Equatable {
        var typedChars: Int
        var activeMinutes: Double
        var dictatedChars: Int
        var dictatedMinutes: Double

        /// nil until there's enough typing to measure.
        var typingWPM: Double? {
            guard activeMinutes >= TypingStats.minimumActiveMinutes else { return nil }
            return Double(typedChars) / TypingStats.charsPerWord / activeMinutes
        }

        /// Same 5-characters-per-word measure, so the two speeds compare fairly.
        var dictationWPM: Double? {
            guard dictatedMinutes > 0 else { return nil }
            return Double(dictatedChars) / TypingStats.charsPerWord / dictatedMinutes
        }

        /// Share of characters that came from dictation (0…1).
        var voiceShare: Double {
            let total = typedChars + dictatedChars
            return total > 0 ? Double(dictatedChars) / Double(total) : 0
        }
    }

    /// Totals for the `days` days up to and including `now`'s day.
    static func summary(
        typing: [String: TypingDay],
        dictations: [(date: Date, chars: Int, duration: TimeInterval)],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Summary {
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        var keys = Set<String>()
        var day = start
        while day <= now {
            keys.insert(dayKey(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let typed = typing.filter { keys.contains($0.key) }.values
        let dictated = dictations.filter { $0.date >= start && $0.date <= now }
        return Summary(
            typedChars: typed.reduce(0) { $0 + $1.chars },
            activeMinutes: Double(typed.reduce(0) { $0 + $1.activeMs }) / 60_000,
            dictatedChars: dictated.reduce(0) { $0 + $1.chars },
            dictatedMinutes: dictated.reduce(0) { $0 + $1.duration } / 60
        )
    }

    /// Keeps the newest `keep` days.
    static func pruned(_ typing: [String: TypingDay], keep: Int = 90) -> [String: TypingDay] {
        guard typing.count > keep else { return typing }
        let kept = typing.keys.sorted().suffix(keep)
        return typing.filter { kept.contains($0.key) }
    }
}

/// L15: counts typed characters per day with a listen-only keyboard tap (needs Input Monitoring).
/// Opt-in. Only two numbers per day are kept; key contents are looked at just to tell a character
/// from a shortcut or arrow key, and never stored.
final class TypingCounterService {
    static let shared = TypingCounterService()

    private static let logger = Logger(subsystem: "com.divingsbysangam.sotto", category: "TypingCounter")
    private static let storageKey = "typingDaily"

    /// Read on the tap thread (to re-enable after a timeout) and written from main: locked.
    private var tap: CFMachPort? {
        get { tapLock.withLock { _tap } }
        set { tapLock.withLock { _tap = newValue } }
    }
    private var _tap: CFMachPort?
    private let tapLock = NSLock()
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    /// Guarded by `lock`: counts not yet written to UserDefaults, and the last keystroke time.
    private var pending: [String: TypingDay] = [:]
    private var lastKeyAt: Date?
    private var flushTimer: Timer?

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt (once); afterwards the user grants it in System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    /// Stored days plus anything still pending.
    var days: [String: TypingDay] {
        var stored = Self.load()
        lock.withLock {
            for (key, day) in pending {
                stored[key, default: TypingDay()].chars += day.chars
                stored[key, default: TypingDay()].activeMs += day.activeMs
            }
        }
        return stored
    }

    /// Starts or stops to match the setting (and permission). Safe to call repeatedly.
    func sync() {
        if AppSettings.shared.countTypingEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard tap == nil else { return }
        guard Self.hasPermission else {
            Self.logger.notice("typing counter waiting for Input Monitoring")
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<TypingCounterService>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Self.logger.error("typing counter tap unavailable")
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
        thread.name = "com.divingsbysangam.sotto.typing-counter"
        thread.qualityOfService = .utility
        thread.start()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.flush() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
        Self.logger.notice("typing counter started")
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            if let runLoop { CFRunLoopStop(runLoop) }
            Self.logger.notice("typing counter stopped")
        }
        tap = nil
        runLoop = nil
        flush()
    }

    /// Deletes every stored count.
    func reset() {
        lock.withLock {
            pending = [:]
            lastKeyAt = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Writes pending counts to UserDefaults.
    func flush() {
        let batch: [String: TypingDay] = lock.withLock {
            defer { pending = [:] }
            return pending
        }
        guard !batch.isEmpty else { return }
        var stored = Self.load()
        for (key, day) in batch {
            stored[key, default: TypingDay()].chars += day.chars
            stored[key, default: TypingDay()].activeMs += day.activeMs
        }
        stored = TypingStats.pruned(stored)
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.storageKey)
    }

    private static func load() -> [String: TypingDay] {
        UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: TypingDay].self, from: $0) } ?? [:]
    }

    /// Runs on the tap thread.
    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard Self.isTypedCharacter(event) else { return }
            let now = Date()
            lock.withLock {
                let key = TypingStats.dayKey(now)
                TypingStats.record(into: &pending[key, default: TypingDay()], at: now, lastKeyAt: lastKeyAt)
                lastKeyAt = now
            }
        default:
            break
        }
    }

    /// A real, printable keystroke: not autorepeat, not a ⌘/⌃ shortcut, not Sotto's own synthetic
    /// events (paste, copy, send key), and producing a visible character (not arrows or Return).
    static func isTypedCharacter(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        guard event.flags.intersection([.maskCommand, .maskControl]).isEmpty else { return false }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return false }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return false }
        return chars.prefix(length).allSatisfy { $0 >= 0x20 && $0 != 0x7F && !(0xF700...0xF8FF).contains($0) }
    }
}
