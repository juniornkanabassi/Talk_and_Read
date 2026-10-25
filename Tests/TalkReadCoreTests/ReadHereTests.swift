import XCTest
@testable import TalkReadCore

/// Read from here (1.0): the reveal key's state machine, a paragraph's start in plain text, the node join, and the
/// two settings.
final class ReadHereTests: XCTestCase {
    func testGlyphShowsOnceTheKeyIsHeldAloneForTheDelay() {
        var r = RevealState()
        XCTAssertEqual(r.handle(.keyDown, at: 0), [])
        XCTAssertEqual(r.tick(at: RevealState.delay - 0.01), [])
        XCTAssertEqual(r.tick(at: RevealState.delay), [.show])
        XCTAssertTrue(r.isShown)
        XCTAssertEqual(r.tick(at: 2), [], "shows once")
        XCTAssertEqual(r.handle(.keyUp, at: 3), [.hide])
        XCTAssertFalse(r.isShown)
    }

    func testAShortcutBeforeTheDelayNeverShowsTheGlyph() {
        var r = RevealState()
        _ = r.handle(.keyDown, at: 0)
        XCTAssertEqual(r.handle(.otherKey, at: 0.1), [], "⌥D on its way")
        XCTAssertEqual(r.tick(at: 1), [])
        XCTAssertEqual(r.handle(.keyUp, at: 1.2), [])
        _ = r.handle(.keyDown, at: 2)
        XCTAssertEqual(r.tick(at: 2 + RevealState.delay), [.show], "a fresh hold shows again")
    }

    func testAnotherKeyHidesAGlyphOnShowAndAMissedKeyUpHeals() {
        var r = RevealState()
        _ = r.handle(.keyDown, at: 0)
        _ = r.tick(at: 1)
        XCTAssertEqual(r.handle(.otherKey, at: 1.5), [.hide])
        XCTAssertEqual(r.tick(at: 2), [])
        _ = r.handle(.keyUp, at: 2.5)
        _ = r.handle(.keyDown, at: 3)
        _ = r.tick(at: 4)
        XCTAssertEqual(r.handle(.keyDown, at: 5), [.hide], "a second key-down means the key-up was missed")
        XCTAssertEqual(r.tick(at: 5 + RevealState.delay), [.show])
        XCTAssertEqual(r.reset(), [.hide])
        XCTAssertEqual(r.reset(), [])
    }

    func testParagraphStart() {
        let text = "First paragraph.\nSecond one, with more words.\r\n\nThird."
        let ns = text as NSString
        XCTAssertEqual(ReadHere.paragraphStart(text, at: 5), 0)
        let second = ns.range(of: "Second").location
        XCTAssertEqual(ReadHere.paragraphStart(text, at: ns.range(of: "more").location), second)
        XCTAssertEqual(ReadHere.paragraphStart(text, at: second), second, "the first character of a paragraph is its start")
        XCTAssertEqual(ReadHere.paragraphStart(text, at: ns.range(of: "Third").location + 2), ns.range(of: "Third").location)
        XCTAssertEqual(ReadHere.paragraphStart(text, at: 10_000), ns.range(of: "Third").location, "past the end: the last paragraph")
        XCTAssertEqual(ReadHere.paragraphStart("😀 emoji first\nnext", at: 4), 0, "a surrogate pair is no break")
    }

    func testJoinKeepsLinesTogetherAndParagraphsApart() {
        let joined = ReadHere.join([
            ("Talk & Read reads the paragraph ", 100, 140),   // two lines of 20 pt
            ("under the pointer", 120, 140),                  // a link on the second line
            (" to the end.", 120, 140),
            ("A new paragraph after a 16 pt gap.", 156, 176),
            ("   ", 180, 190),                                // whitespace only: dropped
            ("No frame, so a space.", nil, nil),
        ])
        XCTAssertEqual(joined, "Talk & Read reads the paragraph under the pointer to the end.\n\nA new paragraph after a 16 pt gap. No frame, so a space.")
        XCTAssertEqual(ReadHere.join([]), "")
    }

    func testSettings() throws {
        var s = Settings()
        XCTAssertEqual(s.readHereKey, .leftOption)
        XCTAssertEqual(s.readHereShortcut.display, "⌃⇧A")
        XCTAssertFalse(s.readHereHover, "hover mode is opt in")
        try s.set("readHereHover", to: "on")
        XCTAssertTrue(s.readHereHover)
        try s.set("readHereKey", to: "off")
        XCTAssertEqual(s.readHereKey, .off)
        XCTAssertThrowsError(try s.set("readHereKey", to: "rightOption"))
        try s.set("dictationHoldKey", to: "fn")
        XCTAssertThrowsError(try s.set("readHereKey", to: "fn"), "Fn is the dictation key")
        try s.set("dictationHoldKey", to: "rightOption")
        try s.set("readHereKey", to: "fn")
        XCTAssertEqual(s.readHereKey, .fn)
        try s.set("dictationHoldKey", to: "fn")
        XCTAssertEqual(s.readHereKey, .leftOption, "dictation takes Fn; the glyph goes back to left Option")
        s.resetShortcuts()
        XCTAssertEqual(s.readHereKey, .leftOption)
        XCTAssertEqual(s.readHereShortcut, Settings().readHereShortcut)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"speed":2.0}"#.utf8))
        XCTAssertEqual(old.readHereKey, .leftOption, "a file from before 1.0 gets the default")
        XCTAssertEqual(old.action(keyCode: 0, modifiers: Settings.Shortcut.control | Settings.Shortcut.shift), .readHere)
    }
}
