import XCTest
@testable import TalkReadCore

final class HotkeyStateTests: XCTestCase {
    private let letterA = KeyEvent.otherKeyDown(keyCode: 0, modifiers: 1 << 19)
    private let esc = KeyEvent.otherKeyDown(keyCode: 53, modifiers: 0)

    /// Holds the key from t = 0 and ticks at `tickAt`.
    private func held(tickAt: Double? = nil) -> (HotkeyState, [HotkeyAction]) {
        var s = HotkeyState()
        var out = s.handle(.holdKeyDown, at: 0)
        if let t = tickAt { out += s.tick(at: t) }
        return (s, out)
    }

    func testRecordingStartsAt150msHeldAlone() {
        var s = HotkeyState()
        XCTAssertEqual(s.handle(.holdKeyDown, at: 10), [])
        XCTAssertEqual(s.tick(at: 10.149), [])
        XCTAssertEqual(s.tick(at: 10.150), [.startRecording])
        XCTAssertEqual(s.tick(at: 10.300), [], "starts once")
    }

    func testReleaseAfterRecordingInserts() {
        var (s, out) = held(tickAt: 0.2)
        XCTAssertEqual(out, [.startRecording])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 2), [.stopAndInsert])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 2.1), [], "a stray key-up does nothing")
    }

    func testReleaseBefore150msDoesNothing() {
        var (s, _) = held(tickAt: 0.1)
        XCTAssertEqual(s.handle(.holdKeyUp, at: 0.12), [])
        XCTAssertEqual(s.tick(at: 0.5), [], "no late start after release")
    }

    func testOtherKeyBefore150msNeverRecords() {
        var (s, _) = held()
        XCTAssertEqual(s.handle(letterA, at: 0.05), [])
        XCTAssertEqual(s.tick(at: 0.2), [], "a chord never records")
        XCTAssertEqual(s.tick(at: 5), [])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 6), [], "nothing typed on release")
    }

    func testOtherKeyAfter150msCancelsAndDiscards() {
        var (s, out) = held(tickAt: 0.15)
        XCTAssertEqual(out, [.startRecording])
        XCTAssertEqual(s.handle(letterA, at: 0.4), [.cancelRecording])
        XCTAssertEqual(s.handle(letterA, at: 0.5), [], "cancels once")
        XCTAssertEqual(s.handle(.holdKeyUp, at: 1), [], "nothing inserted on release")
    }

    func testOtherModifierCountsAsAChordKey() {
        var (s, _) = held(tickAt: 0.2)
        XCTAssertEqual(s.handle(.otherKeyDown(keyCode: 56, modifiers: 1 << 17), at: 0.3), [.cancelRecording])
    }

    func testOtherKeyExactlyAtThresholdBeforeTickNeverRecords() {
        // The timer has not fired yet when the key arrives: no recording was started, so nothing to cancel or start.
        var (s, _) = held()
        XCTAssertEqual(s.handle(letterA, at: 0.150), [])
        XCTAssertEqual(s.tick(at: 0.151), [])
    }

    func testEscCancelsWhileRecordingAndIsIgnoredOtherwise() {
        var (s, _) = held(tickAt: 0.2)
        XCTAssertEqual(s.handle(esc, at: 0.5), [.cancelRecording])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 0.6), [])
        var idle = HotkeyState()
        // Toggle and agent recordings are not tracked here; Esc always asks the controller, which ignores it when idle.
        XCTAssertEqual(idle.handle(esc, at: 1), [.cancelRecording])
    }

    func testToggleShortcutPassesThrough() {
        var s = HotkeyState()
        XCTAssertEqual(s.handle(.chord(.toggleRecording), at: 0), [.toggleRecording])
        XCTAssertEqual(s.handle(.chord(.toggleRecording), at: 3), [.toggleRecording])
    }

    func testChordShortcutsPassThroughAndCancelAHoldRecording() {
        var s = HotkeyState()
        for a in [HotkeyAction.read, .pause, .screenshot, .pasteLast] {
            XCTAssertEqual(s.handle(.chord(a), at: 0), [a])
        }
        var (h, _) = held(tickAt: 0.2)
        XCTAssertEqual(h.handle(.chord(.read), at: 0.5), [.cancelRecording, .read])
        var (p, _) = held()
        XCTAssertEqual(p.handle(.chord(.toggleRecording), at: 0.05), [.toggleRecording], "before 150 ms nothing to cancel")
        XCTAssertEqual(p.tick(at: 0.3), [])
    }

    func testMissedKeyUpIsHealedByNextKeyDown() {
        var (s, _) = held(tickAt: 0.2)
        // Key-up lost; the next press resets: the stale recording is discarded and a fresh hold begins.
        XCTAssertEqual(s.handle(.holdKeyDown, at: 5), [.cancelRecording])
        XCTAssertEqual(s.tick(at: 5.1), [])
        XCTAssertEqual(s.tick(at: 5.15), [.startRecording])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 6), [.stopAndInsert])

        var (c, _) = held()
        _ = c.handle(letterA, at: 0.05)           // chorded, key-up lost
        XCTAssertEqual(c.handle(.holdKeyDown, at: 3), [], "nothing was recording")
        XCTAssertEqual(c.tick(at: 3.2), [.startRecording], "chord state cleared")
    }

    func testResetCancelsAHoldRecordingAndForgetsTheKey() {
        // Sol #19: paused (shortcut recorder) or reloaded mid-recording; the release that follows must not be needed.
        var (s, _) = held(tickAt: 0.2)
        XCTAssertEqual(s.reset(), [.cancelRecording])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 1), [], "nothing inserted on the late release")
        XCTAssertEqual(s.reset(), [], "cancels once")
        var (p, _) = held()
        XCTAssertEqual(p.reset(), [], "a pending hold started nothing")
        XCTAssertEqual(p.tick(at: 0.3), [], "and never starts after the reset")
        var idle = HotkeyState()
        XCTAssertEqual(idle.reset(), [], "toggle and agent recordings are left alone")
    }

    func testTickWithoutHoldDoesNothing() {
        var s = HotkeyState()
        XCTAssertEqual(s.tick(at: 100), [])
        XCTAssertEqual(s.handle(.holdKeyUp, at: 100), [])
    }
}
