import Foundation

/// The single classifier for the recording hotkey. Recording starts on key-down; how the press
/// plays out decides how it ends:
/// - Hold for at least 0.6 s: push-to-talk, and release stops.
/// - Tap (under 0.6 s): a second key-down within 1 s locks hands-free (same recording);
///   otherwise the recording is discarded.
/// - Space while holding: locks hands-free.
/// - Hands-free: a tap stops.
/// - L12 mouse button: a click (`keyUp(lockingHandsFreeOnTap: true)`) locks hands-free at once
///   instead of waiting for a second tap, so click = toggle and hold = push-to-talk.
/// Any recording shorter than 0.4 s is discarded, never transcribed. ESC is handled by AppState.
///
/// Pure state, no timers or side effects: HotkeyManager feeds it events and runs the double-tap
/// timer while `state == .awaitingSecondTap`.
struct HotkeyGestureClassifier {
    enum Action: Equatable {
        case start
        case stop
        /// Throw the recording away: no transcript, no error.
        case discard
        /// Keep recording after the key is released; the next tap stops.
        case lockHandsFree
    }

    enum State: Equatable {
        case idle
        case holding(pressedAt: Date)
        case awaitingSecondTap
        case handsFree(keyIsDown: Bool)
    }

    static let handsFreeThreshold: TimeInterval = 0.6
    static let doubleTapWindow: TimeInterval = 1.0
    static let minimumRecording: TimeInterval = 0.4

    private(set) var state: State = .idle
    private var recordingStartedAt: Date?

    /// The hotkey is physically down, so Space can still lock hands-free.
    var isKeyDown: Bool {
        switch state {
        case .holding, .handsFree(keyIsDown: true): return true
        default: return false
        }
    }

    mutating func keyDown(at now: Date = Date()) -> Action? {
        switch state {
        case .idle:
            state = .holding(pressedAt: now)
            recordingStartedAt = now
            return .start
        case .holding, .handsFree(keyIsDown: true):
            return nil
        case .awaitingSecondTap:
            state = .handsFree(keyIsDown: true)
            return .lockHandsFree
        case .handsFree(keyIsDown: false):
            return finish(at: now)
        }
    }

    mutating func keyUp(at now: Date = Date(), lockingHandsFreeOnTap: Bool = false) -> Action? {
        switch state {
        case .holding(let pressedAt):
            if now.timeIntervalSince(pressedAt) >= Self.handsFreeThreshold {
                return finish(at: now)
            }
            if lockingHandsFreeOnTap {
                state = .handsFree(keyIsDown: false)
                return .lockHandsFree
            }
            state = .awaitingSecondTap
            return nil
        case .handsFree(keyIsDown: true):
            state = .handsFree(keyIsDown: false)
            return nil
        default:
            // Includes the release of the tap that stopped hands-free.
            return nil
        }
    }

    mutating func spacePressed() -> Action? {
        guard case .holding = state else { return nil }
        state = .handsFree(keyIsDown: true)
        return .lockHandsFree
    }

    /// The key turned out to be part of a chord (a lone-modifier key used with another key):
    /// drop the recording it started, unless hands-free is already locked.
    mutating func interrupted() -> Action? {
        guard case .holding = state else { return nil }
        reset()
        return .discard
    }

    /// A lone tap: nothing followed it within the double-tap window.
    mutating func doubleTapWindowExpired() -> Action? {
        guard state == .awaitingSecondTap else { return nil }
        reset()
        return .discard
    }

    /// Recording was started without the hotkey (menu bar), so a tap stops it.
    mutating func recordingStartedElsewhere(at now: Date = Date()) {
        guard state == .idle else { return }
        state = .handsFree(keyIsDown: false)
        recordingStartedAt = now
    }

    /// Recording ended outside the classifier (ESC, error, finished processing).
    mutating func reset() {
        state = .idle
        recordingStartedAt = nil
    }

    private mutating func finish(at now: Date) -> Action {
        let tooShort = recordingStartedAt.map { now.timeIntervalSince($0) < Self.minimumRecording } ?? false
        reset()
        return tooShort ? .discard : .stop
    }
}
