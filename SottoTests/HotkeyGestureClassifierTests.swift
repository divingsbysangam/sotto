import XCTest
@testable import Sotto

/// The classifier is pure state: every test passes explicit timestamps, so nothing here sleeps.
final class HotkeyGestureClassifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Hold (push-to-talk)

    func testKeyDownStartsRecording() {
        var c = HotkeyGestureClassifier()
        XCTAssertEqual(c.keyDown(at: at(0)), .start)
        XCTAssertEqual(c.state, .holding(pressedAt: at(0)))
        XCTAssertTrue(c.isKeyDown)
    }

    func testHoldPastThresholdStopsOnRelease() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertEqual(c.keyUp(at: at(2)), .stop)
        XCTAssertEqual(c.state, .idle)
    }

    // Timing tests stay clear of the exact boundary: `Date` arithmetic isn't exact to the last bit.
    func testHoldJustOverThresholdCountsAsHold() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertEqual(c.keyUp(at: at(HotkeyGestureClassifier.handsFreeThreshold + 0.05)), .stop)
    }

    func testHoldJustUnderThresholdIsATap() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertNil(c.keyUp(at: at(HotkeyGestureClassifier.handsFreeThreshold - 0.05)))
        XCTAssertEqual(c.state, .awaitingSecondTap)
    }

    func testKeyRepeatWhileHoldingIsIgnored() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertNil(c.keyDown(at: at(0.1)))
        XCTAssertNil(c.keyDown(at: at(0.2)))
        XCTAssertEqual(c.keyUp(at: at(1)), .stop)
    }

    // MARK: Double-tap (hands-free)

    func testDoubleTapLocksHandsFreeAndNextTapStops() {
        var c = HotkeyGestureClassifier()
        XCTAssertEqual(c.keyDown(at: at(0)), .start)
        XCTAssertNil(c.keyUp(at: at(0.1)))
        XCTAssertEqual(c.keyDown(at: at(0.3)), .lockHandsFree)
        XCTAssertNil(c.keyUp(at: at(0.35)))
        XCTAssertEqual(c.state, .handsFree(keyIsDown: false))
        // The tap that ends the recording, more than the minimum after it began.
        XCTAssertEqual(c.keyDown(at: at(5)), .stop)
        XCTAssertNil(c.keyUp(at: at(5.05)), "releasing the stopping tap does nothing")
        XCTAssertEqual(c.state, .idle)
    }

    func testLoneTapIsDiscardedWhenTheWindowExpires() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertNil(c.keyUp(at: at(0.1)))
        XCTAssertEqual(c.doubleTapWindowExpired(), .discard)
        XCTAssertEqual(c.state, .idle)
    }

    func testWindowExpiryOutsideAwaitingSecondTapDoesNothing() {
        var c = HotkeyGestureClassifier()
        XCTAssertNil(c.doubleTapWindowExpired())
        _ = c.keyDown(at: at(0))
        XCTAssertNil(c.doubleTapWindowExpired(), "still holding")
    }

    func testStoppingHandsFreeTooSoonDiscardsTheRecording() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        _ = c.keyUp(at: at(0.05))
        _ = c.keyDown(at: at(0.1))   // lock
        _ = c.keyUp(at: at(0.12))
        XCTAssertEqual(c.keyDown(at: at(HotkeyGestureClassifier.minimumRecording - 0.1)), .discard)
    }

    func testStoppingHandsFreeAfterTheMinimumKeepsTheRecording() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        _ = c.keyUp(at: at(0.05))
        _ = c.keyDown(at: at(0.1))
        _ = c.keyUp(at: at(0.12))
        XCTAssertEqual(c.keyDown(at: at(HotkeyGestureClassifier.minimumRecording + 0.1)), .stop)
    }

    // MARK: Hold + Space

    func testSpaceWhileHoldingLocksHandsFree() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertEqual(c.spacePressed(), .lockHandsFree)
        XCTAssertTrue(c.isKeyDown, "the key is still physically down")
        XCTAssertNil(c.keyUp(at: at(2)), "releasing after the lock keeps recording")
        XCTAssertEqual(c.state, .handsFree(keyIsDown: false))
        XCTAssertEqual(c.keyDown(at: at(6)), .stop)
    }

    func testSpaceWhenNotHoldingIsIgnored() {
        var c = HotkeyGestureClassifier()
        XCTAssertNil(c.spacePressed())
        _ = c.keyDown(at: at(0))
        _ = c.keyUp(at: at(0.1))
        XCTAssertNil(c.spacePressed(), "awaiting a second tap, key is up")
    }

    // MARK: Mouse button (click = toggle)

    func testClickLocksHandsFreeImmediately() {
        var c = HotkeyGestureClassifier()
        XCTAssertEqual(c.keyDown(at: at(0)), .start)
        XCTAssertEqual(c.keyUp(at: at(0.1), lockingHandsFreeOnTap: true), .lockHandsFree)
        XCTAssertEqual(c.state, .handsFree(keyIsDown: false))
        XCTAssertEqual(c.keyDown(at: at(3)), .stop)
    }

    func testLongMouseHoldIsStillPushToTalk() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertEqual(c.keyUp(at: at(1.5), lockingHandsFreeOnTap: true), .stop)
    }

    // MARK: Interruptions

    func testChordWhileHoldingDiscardsTheRecording() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        XCTAssertEqual(c.interrupted(), .discard)
        XCTAssertEqual(c.state, .idle)
    }

    func testChordAfterHandsFreeLockedIsIgnored() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        _ = c.spacePressed()
        XCTAssertNil(c.interrupted())
        XCTAssertEqual(c.state, .handsFree(keyIsDown: true))
    }

    func testRecordingStartedFromTheMenuIsStoppedByATap() {
        var c = HotkeyGestureClassifier()
        c.recordingStartedElsewhere(at: at(0))
        XCTAssertEqual(c.state, .handsFree(keyIsDown: false))
        XCTAssertEqual(c.keyDown(at: at(4)), .stop)
    }

    func testRecordingStartedElsewhereDoesNotOverrideAnActiveGesture() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        c.recordingStartedElsewhere(at: at(1))
        XCTAssertEqual(c.state, .holding(pressedAt: at(0)))
    }

    func testResetReturnsToIdleSoTheNextPressStartsAgain() {
        var c = HotkeyGestureClassifier()
        _ = c.keyDown(at: at(0))
        _ = c.spacePressed()
        c.reset()
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.isKeyDown)
        XCTAssertEqual(c.keyDown(at: at(10)), .start)
    }

    func testReleaseWhileIdleDoesNothing() {
        var c = HotkeyGestureClassifier()
        XCTAssertNil(c.keyUp(at: at(0)))
        XCTAssertEqual(c.state, .idle)
    }
}
